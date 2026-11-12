-- autorate.lua: keeps the whole-connection limit just under what the line can carry
-- right now (started by ax10.sh while iot_wan_auto=1).
--
--   lua autorate.lua <rate script> <state file> <down dev> <up dev> \
--                    <base down> <base up> <min down> <max down> <min up> <max up>     (Mbps)
--
-- The limit only does its job (calls first, guests last, no lag while someone
-- downloads) when it sits a little below the line's real speed: then the queue is
-- here, where the router decides who goes first, not at the ISP. A line whose speed
-- varies has no one right number, so this follows it, the way cake-autorate does:
--
--   every second, ping two servers and compare with their usual delay;
--   delay normal and a direction full to its limit -> raise that limit a little;
--   delay up (the line is full, the ISP is queueing) -> set the busy direction(s)
--     just under what actually got through, and wait a few seconds before raising;
--   the limit was raised but the traffic did not follow, and holds steady below it
--     (the line is full, and this ISP drops instead of queueing, so no delay shows)
--     -> that is the line's ceiling: sit just under it, and don't probe above it
--     again for a minute;
--   a direction idle -> drift back towards its usual ("base") speed.
--
-- The pings leave from the router itself, so they don't pass through our own
-- queues: what they see is the line. Rates are applied by <rate script> (written by
-- ax10.sh shape_sync: `tc class change` on the lanes, nothing is rebuilt).
local nixio = require "nixio"

local script, statef, ddev, udev = arg[1], arg[2], arg[3], arg[4]
local n = {}
for i = 5, 10 do n[#n + 1] = tonumber(arg[i]) end
if not (script and statef and ddev and udev and #n == 6) then
    io.stderr:write("usage: autorate.lua <rate script> <state file> <down dev> <up dev> <base d> <base u> <min d> <max d> <min u> <max u>\n")
    os.exit(2)
end

local REFLECTORS = { "1.1.1.1", "8.8.8.8", "9.9.9.9", "1.0.0.1" }
local DELAY_MS = tonumber(os.getenv("AUTORATE_DELAY_MS")) or 15   -- extra delay that means "the line is full"
local UP_STEP = 1.04          -- raise by 4% a second while full and the delay is normal
local HOLD = 5                -- seconds without raising after backing off
local FULL, BUSY, QUIET = 0.90, 0.75, 0.30   -- share of the limit in use: at the limit / busy / idle
local CALM = 0.20             -- both directions below this share: nothing to control
local CALM_TICKS, CALM_EVERY = 10, 10   -- after 10 calm seconds, ping only every 10th second
local UNDER = 0.97            -- sit this far under a ceiling found without delay
local CEIL_FOR = 60           -- seconds before probing above that ceiling again

-- Time since boot, not the wall clock: the router's clock is set by NTP some time
-- after it starts and can jump by hours, which must not stretch a 5-second hold or a
-- one-minute ceiling into most of an hour. (The wall clock is only used to tell how
-- old a saved state file is.)
local function now()
    local f = io.open("/proc/uptime")
    if f then local v = tonumber((f:read("*l") or ""):match("^([%d.]+)")); f:close(); if v then return v end end
    local s, u = nixio.gettimeofday(); return s + u / 1e6
end
local function bytes(dev)
    local f = io.open("/sys/class/net/" .. dev .. "/statistics/tx_bytes"); if not f then return nil end
    local v = tonumber(f:read("*l")); f:close(); return v
end
local function ping(host)
    -- 16 bytes of payload: enough for the timestamp, 88 bytes on the line there and back
    local p = io.popen("ping -c 1 -W 1 -s 16 " .. host .. " 2>/dev/null"); if not p then return nil end
    local out = p:read("*a") or ""; p:close()
    return tonumber(out:match("time=([%d.]+) ms"))
end

-- One direction's state. Rates in kbit/s.
local function dir(dev, base, lo, hi)
    return { dev = dev, base = base * 1000, lo = lo * 1000, hi = hi * 1000, rate = base * 1000, last = bytes(dev), load = 0, got = 0, hold = 0 }
end
local D, U = dir(ddev, n[1], n[3], n[4]), dir(udev, n[2], n[5], n[6])
-- Restarted because the lanes were rebuilt (a guest joined, a cap changed)? Carry on
-- from the rates of a moment ago instead of starting over from the usual speeds.
do
    local f = io.open(statef)
    if f then
        local line = f:read("*l") or ""; f:close()
        local d, u, t = tonumber(line:match("down=(%d+)")), tonumber(line:match("up=(%d+)")), tonumber(line:match(" t=(%d+)"))
        if d and u and t and math.abs(os.time() - t) < 60 then
            if d >= D.lo and d <= D.hi then D.rate = d end
            if u >= U.lo and u <= U.hi then U.rate = u end
            -- and the ceilings found, for what is left of their minute
            for _, x in ipairs({ { D, "down" }, { U, "up" } }) do
                local c, left = tonumber(line:match("ceil_" .. x[2] .. "=(%d+)")), tonumber(line:match("ceil_" .. x[2] .. "_left=(%d+)"))
                if c and left and c > 0 and left > 0 then x[1].ceil = c; x[1].ceil_until = now() + left end
            end
        end
    end
end
local usual = {}              -- reflector -> its usual delay (ms)
local applied = { 0, 0 }

-- The rate classes are ax10.sh's too: its runs rebuild them, under its run lock
-- (src/10-lock.sh, next to our state file). A rate is changed only while holding that
-- lock, so it can never land in the middle of a rebuild, or on the classes of a
-- rebuild that has stopped us (a run stops us while it holds the lock, and then no
-- rate change of ours can be under way). Lock busy: try again next second.
local runlock = nixio.open((statef:match("^(.*)/[^/]*$") or ".") .. "/run.lock", "w")
local function apply()
    local d, u = math.floor(D.rate), math.floor(U.rate)
    -- skip changes under 1%: each one costs a few process starts on this CPU
    if math.abs(d - applied[1]) < applied[1] * 0.01 and math.abs(u - applied[2]) < applied[2] * 0.01 then return end
    if runlock and not runlock:lock("tlock") then return end
    local ok = os.execute("sh " .. script .. " " .. d .. " " .. u .. " >/dev/null 2>&1") == 0
    if runlock then runlock:lock("ulock") end
    if ok then applied = { d, u } end
end
local function save(extra, usual_ms)
    local f = io.open(statef .. ".new", "w"); if not f then return end
    local t = now()
    local function ceil(x) if x.ceil and x.ceil_until > t then return math.floor(x.ceil), math.floor(x.ceil_until - t) end; return 0, 0 end
    local cd, cdl = ceil(D); local cu, cul = ceil(U)
    f:write(string.format("down=%d up=%d load_down=%d load_up=%d extra=%d usual=%d ceil_down=%d ceil_down_left=%d ceil_up=%d ceil_up_left=%d t=%d\n",
        math.floor(D.rate), math.floor(U.rate), math.floor(D.got), math.floor(U.got), math.floor(extra + 0.5), math.floor(usual_ms + 0.5), cd, cdl, cu, cul, os.time()))
    f:close(); os.rename(statef .. ".new", statef)
end

-- Pinging costs data (about 14 MB a day at one round a second), and delay only
-- matters while the line is in use. So when both directions have been calm for a
-- while, ping once every CALM_EVERY seconds: enough to keep the usual delays
-- current. The traffic counters are still read every second, which costs nothing,
-- and the first busy second switches back to pinging every second.
local turn, last, calm, tick = 0, now(), 0, 0
local last_usual = 0
apply()
while true do
    tick = tick + 1
    local measure = calm < CALM_TICKS or tick % CALM_EVERY == 0
    -- two reflectors a round, taking turns; each against its own usual delay
    local extras, usual_ms = {}, last_usual
    for k = 1, (measure and 2 or 0) do
        turn = turn % #REFLECTORS + 1
        local host = REFLECTORS[turn]
        local ms = ping(host)
        if ms then
            local b = usual[host]
            if not b or ms < b then b = ms else b = b + (ms - b) * 0.01 end   -- follows drops at once, rises slowly
            usual[host] = b; usual_ms = b
            extras[#extras + 1] = ms - b
        end
    end
    last_usual = usual_ms
    -- "delayed" needs both to agree; one slow server is that server's business.
    -- A round without pings says nothing about delay: 0, like one answer of two.
    local extra = #extras == 2 and math.min(extras[1], extras[2]) or ((#extras == 1 or not measure) and 0) or nil

    local t = now(); local dt = t - last; last = t
    for _, x in ipairs({ D, U }) do
        local b = bytes(x.dev)
        if b and x.last and b >= x.last and dt > 0.2 and dt < 10 then
            x.got = (b - x.last) * 8 / 1000 / dt          -- kbit/s that went through
            x.load = x.got / x.rate
        else x.load = 0; x.got = 0 end
        x.last = b
        if x.hold > 0 and dt > 0 then x.hold = x.hold - math.min(dt, 10) end
    end
    if D.load < CALM and U.load < CALM then calm = calm + 1 else calm = 0 end
    -- no answer from either server while a direction is full: treat as delayed
    local lost = extra == nil
    if lost then extra = (D.load > BUSY or U.load > BUSY) and DELAY_MS or 0 end

    for _, x in ipairs({ D, U }) do
        if extra >= DELAY_MS and x.load > 0.5 then
            -- the line is full: sit just under what really got through, never
            -- dropping more than a fifth at once, and always at least a little
            local target = math.max(x.got * 0.92, x.rate * 0.8)
            x.rate = math.min(target, x.rate * 0.97); x.hold = HOLD
        elseif extra < DELAY_MS / 2 and x.load > FULL and x.hold <= 0 and not lost then
            x.rate = x.rate * UP_STEP
            if x.ceil and t < x.ceil_until and x.rate > x.ceil then x.rate = x.ceil end
            x.full_t = t; x.flat = 0
        elseif x.load > 0.5 and x.full_t and t - x.full_t < 8 then
            -- It was full a moment ago and now runs below the (raised) limit. If what
            -- gets through holds steady, the line itself is what's limiting it.
            if x.prev and x.prev > 0 and math.abs(x.got - x.prev) < x.prev * 0.06 then x.flat = (x.flat or 0) + 1 else x.flat = 0 end
            if x.flat >= 3 then
                x.ceil = x.got * UNDER; x.ceil_until = t + CEIL_FOR
                x.rate = x.ceil; x.hold = 2; x.flat = 0; x.full_t = nil
            end
        elseif x.load < QUIET then
            -- idle: back towards the usual speed, quickly from below, slowly from above
            if x.rate < x.base then x.rate = x.rate + (x.base - x.rate) * 0.02
            else x.rate = x.rate + (x.base - x.rate) * 0.005 end
        end
        if x.rate < x.lo then x.rate = x.lo elseif x.rate > x.hi then x.rate = x.hi end
        x.prev = x.got
    end
    apply(); save(extra, usual_ms)
    local spent = now() - t
    if spent < 1 then nixio.nanosleep(0, math.min(999999999, math.floor((1 - math.max(spent, 0)) * 1e9))) end
end
