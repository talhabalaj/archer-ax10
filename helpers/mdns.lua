-- mdns.lua: show IoT devices' AirPlay / Spotify Connect speakers to the home network.
-- Phones find those by mDNS (multicast 224.0.0.251:5353), which never leaves its own
-- network. This repeats, and nothing more:
--   from the IoT network: answers sent BY the listed IoT addresses (or any IoT device,
--     with "all"), cut down to the records about the listed services, plus the address
--     record of a host name the same device's service points to, and only if that
--     address is the device's own. Each packet is rebuilt from just those records.
--   from the home network: the questions about those services or those host names,
--     rebuilt the same way, into the IoT network, so the device answers (and its
--     answer comes back the first way).
-- Every 5 minutes it also asks the IoT network itself, so the speakers stay listed on
-- phones without anyone opening a picker first. Packets go out from the router's own
-- address on each side, as mDNS reflectors do; at most RATE per second each way.
--
-- lua mdns.lua <iot-router-ip> <home-router-ip> "all" | "<iot ip> ..." "<_svc._tcp> ..." <statfile>
-- Started and watched by ax10.sh (mdns_sync).

local MDNS, PORT, RATE, ASK_EVERY = "224.0.0.251", 5353, 40, 300
local HOST_TTL, MAX_HOSTS = 4500, 64

-- [pure] ---------------------------------------------- packet reading and decisions
-- A DNS name at byte i (1-based): its labels as sent, and where the bytes after it start.
local function name_at(p, i)
    local labels, after, hops = {}, nil, 0
    while true do
        local len = p:byte(i)
        if not len then return nil end
        if len == 0 then i = i + 1; break end
        if len >= 192 then
            local b2 = p:byte(i + 1); if not b2 then return nil end
            after = after or i + 2
            i = (len - 192) * 256 + b2 + 1
            hops = hops + 1; if hops > 32 then return nil end
        elseif len >= 64 then return nil
        else
            if i + len > #p then return nil end
            labels[#labels + 1] = p:sub(i + 1, i + len)
            i = i + 1 + len
            if #labels > 64 then return nil end
        end
    end
    return labels, after or i
end
local function key(labels) return table.concat(labels, "."):lower() end
local function enc(labels)
    local t = {}
    for j, l in ipairs(labels) do t[j] = string.char(#l) .. l end
    return table.concat(t) .. "\0"
end
local function u16s(n) return string.char(math.floor(n / 256), n % 256) end

-- { qr, qs = { {labels, tail} }, an, ns, ar = { {labels, type, cls, ttl, rd, target, pre, post} } }
-- or nil. tail: qtype + qclass bytes; cls and ttl stay as sent (bytes). For PTR, SRV
-- and NSEC the name inside the data is read (target) so it can be written again
-- without compression; pre is what comes before it (SRV), post what follows (NSEC).
local function parse(p)
    if #p < 12 then return nil end
    local function u16(i) local a, b = p:byte(i, i + 1); return a * 256 + b end
    local m = { qr = p:byte(3) >= 128, qs = {}, an = {}, ns = {}, ar = {} }
    local i = 13
    for _ = 1, u16(5) do
        local l; l, i = name_at(p, i)
        if not l or i + 3 > #p then return nil end
        m.qs[#m.qs + 1] = { labels = l, tail = p:sub(i, i + 3) }; i = i + 4
    end
    for _, sec in ipairs({ { "an", u16(7) }, { "ns", u16(9) }, { "ar", u16(11) } }) do
        for _ = 1, sec[2] do
            local l; l, i = name_at(p, i)
            if not l or i + 9 > #p then return nil end
            local t, len, rd = u16(i), u16(i + 8), i + 10
            if rd + len - 1 > #p then return nil end
            local r = { labels = l, type = t, cls = p:sub(i + 2, i + 3), ttl = p:sub(i + 4, i + 7), rd = p:sub(rd, rd + len - 1) }
            if t == 12 then r.target, r.pre, r.post = name_at(p, rd), "", ""
            elseif t == 33 and len > 6 then r.target, r.pre, r.post = name_at(p, rd + 6), p:sub(rd, rd + 5), ""
            elseif t == 47 then
                local nl, e = name_at(p, rd)
                if nl and e <= rd + len then r.target, r.pre, r.post = nl, "", p:sub(e, rd + len - 1) end
            end
            if (t == 12 or t == 33 or t == 47) and not r.target then return nil end
            local list = m[sec[1]]
            list[#list + 1] = r
            i = rd + len
        end
    end
    return m
end

-- Does the name end with one of the services (the service, an instance, a subtype)?
-- svcs: label lists in lower case, e.g. { "_airplay", "_tcp", "local" }.
local function is_svc(labels, svcs)
    for _, s in ipairs(svcs) do
        local n, k = #labels, #s
        if n >= k then
            local ok = true
            for j = 1, k do if labels[n - k + j]:lower() ~= s[j] then ok = false; break end end
            if ok then return true end
        end
    end
    return false
end

local function rr_bytes(r)
    local rd = r.target and (r.pre .. enc(r.target) .. r.post) or r.rd
    return enc(r.labels) .. u16s(r.type) .. r.cls .. r.ttl .. u16s(#rd) .. rd
end
local function ip_bytes(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    return a and string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

-- Forget host names whose time is up; true if there is room for one more.
local function purge(hosts, now)
    local n = 0
    for h, v in pairs(hosts) do if v.untl <= now then hosts[h] = nil else n = n + 1 end end
    return n < MAX_HOSTS
end

-- An answer from IoT device `from`: the packet to send home, or nil. Keeps the records
-- about the services (PTR, SRV, TXT, NSEC), learns the host names their SRV records
-- point to for this device (a name another device holds is not taken over), and keeps
-- that host's A record only if it is this device's own address (no AAAA: the IoT
-- network is IPv4-only). The authority section (used for probing) is dropped.
local function answer_out(m, from, svcs, hosts, now)
    if not m.qr then return nil end
    local mine = ip_bytes(from)
    for _, sec in ipairs({ m.an, m.ar }) do
        for _, r in ipairs(sec) do
            if r.type == 33 and is_svc(r.labels, svcs) and not is_svc(r.target, svcs) then
                local h = key(r.target)
                local v = hosts[h]
                if v and v.ip == from then v.untl = now + HOST_TTL
                elseif (not v or v.untl <= now) and purge(hosts, now) then hosts[h] = { ip = from, untl = now + HOST_TTL } end
            end
        end
    end
    local out = { {}, {} }
    for s, sec in ipairs({ m.an, m.ar }) do
        for _, r in ipairs(sec) do
            local keep
            if is_svc(r.labels, svcs) then
                keep = r.type == 12 or r.type == 33 or r.type == 16 or r.type == 47
            else
                local v = hosts[key(r.labels)]
                keep = v and v.ip == from and v.untl > now and
                    ((r.type == 1 and r.rd == mine) or r.type == 47)
            end
            if keep then out[s][#out[s] + 1] = rr_bytes(r) end
        end
    end
    if #out[1] + #out[2] == 0 then return nil end
    return "\0\0\132\0\0\0" .. u16s(#out[1]) .. "\0\0" .. u16s(#out[2]) .. table.concat(out[1]) .. table.concat(out[2])
end

-- A question from home: the packet to send to the IoT network, or nil. Keeps only the
-- questions about the services or learned host names (no known answers).
local function question_out(m, svcs, hosts, now)
    if m.qr then return nil end
    local qs = {}
    for _, q in ipairs(m.qs) do
        local v = hosts[key(q.labels)]
        if is_svc(q.labels, svcs) or (v and v.untl > now) then qs[#qs + 1] = enc(q.labels) .. q.tail end
    end
    if #qs == 0 then return nil end
    return "\0\0\0\0" .. u16s(#qs) .. "\0\0\0\0\0\0" .. table.concat(qs)
end

-- A question (PTR, class IN) for each service.
local function question(svcs)
    local qs = {}
    for _, s in ipairs(svcs) do qs[#qs + 1] = enc(s) .. "\0\12\0\1" end
    return "\0\0\0\0" .. u16s(#qs) .. "\0\0\0\0\0\0" .. table.concat(qs)
end

local function svc_labels(s)
    local l = {}
    for x in (s:lower() .. ".local"):gmatch("[^.]+") do l[#l + 1] = x end
    return l
end
-- [/pure] ---------------------------------------------------------------------------

local IOT_IP, LAN_IP, devs, svcs, STAT = arg[1], arg[2], {}, {}, arg[5]
for a in (arg[3] or ""):gmatch("%S+") do devs[a] = true end
for s in (arg[4] or ""):gmatch("%S+") do svcs[#svcs + 1] = svc_labels(s) end
assert(IOT_IP and LAN_IP and next(devs) and #svcs > 0, "usage: mdns.lua <iot-ip> <home-ip> \"all\"|\"<ips>\" \"<services>\" [statfile]")
local IOT_NET = IOT_IP:match("^(%d+%.%d+%.%d+%.)")
local LAN_NET = LAN_IP:match("^(%d+%.%d+%.%d+%.)")

local nixio = require "nixio"
local s = assert(nixio.socket("inet", "dgram"))
s:setopt("socket", "reuseaddr", 1)
assert(s:bind("0.0.0.0", PORT))
assert(s:setopt("ip", "add_membership", MDNS, IOT_IP))
assert(s:setopt("ip", "add_membership", MDNS, LAN_IP))
s:setopt("ip", "multicast_ttl", 255)
s:setopt("ip", "multicast_loop", 0)

local hosts, sent = {}, { lan = 0, iot = 0 }
local bucket = { lan = { n = RATE, t = 0 }, iot = { n = RATE, t = 0 } }
local function send(side, p)
    local b, now = bucket[side], os.time()
    if now ~= b.t then b.n, b.t = RATE, now end
    if b.n <= 0 then return end
    b.n = b.n - 1
    -- nixio takes (group, interface address) here, like add_membership, and the kernel
    -- reads the second. Given only the interface, it would fall back to the routing
    -- table: the internet connection.
    s:setopt("ip", "multicast_if", MDNS, side == "lan" and LAN_IP or IOT_IP)
    if s:sendto(p, MDNS, PORT) then sent[side] = sent[side] + 1 end
end

local function write_stat(now)
    if not STAT then return end
    local f = io.open(STAT .. ".tmp", "w"); if not f then return end
    local hs = {}
    for h, v in pairs(hosts) do if v.untl > now then hs[#hs + 1] = (h:gsub("[^a-z0-9.-]", "")) end end
    f:write(string.format("to_home %d\nto_iot %d\nhosts %s\n", sent.lan, sent.iot, table.concat(hs, " ")))
    f:close(); os.rename(STAT .. ".tmp", STAT)
end

local ASK = question(svcs)
local last_ask, last_stat = 0, 0
local fds = { { fd = s, events = nixio.poll_flags("in") } }
while true do
    local now = os.time()
    if now - last_ask >= ASK_EVERY then last_ask = now; send("iot", ASK) end
    if now - last_stat >= 60 then last_stat = now; purge(hosts, now); write_stat(now) end
    if nixio.poll(fds, 5000) then
        local p, from, port = s:recvfrom(9000)
        if p and from and port == PORT and from ~= IOT_IP and from ~= LAN_IP then
            local m = parse(p)
            if m then
                if from:sub(1, #IOT_NET) == IOT_NET then
                    local out = (devs.all or devs[from]) and answer_out(m, from, svcs, hosts, now)
                    if out then send("lan", out) end
                elseif from:sub(1, #LAN_NET) == LAN_NET then
                    local out = question_out(m, svcs, hosts, now)
                    if out then send("iot", out) end
                end
            end
        end
    end
end
