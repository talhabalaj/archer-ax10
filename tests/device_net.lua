-- Tests web/ax10.lua's device_net: which network a device is on, and its address
-- there. Cut out of the real file (the rest needs LuCI). Run: lua tests/device_net.lua
local src = assert(io.open(arg[1] or "web/ax10.lua")):read("*a")
local a = assert(src:find("-- [device_net]", 1, true))
local b = assert(src:find("-- [/device_net]", 1, true))
local M = assert((loadstring or load)(src:sub(a, b - 1) .. "\nreturn { device_net = device_net, offer = offer, RANK = RANK }"))()
local device_net = M.device_net
local fails = 0
-- live: "lan=ip* lan=ip iot=ip" (a * marks a fresh entry), in table order
local function L(s)
    if not s then return nil end
    local e = { fresh = {} }
    for side, ip, star in s:gmatch("(%a+)=([%d.]+)(%*?)") do
        e[side] = e[side] or {}; table.insert(e[side], ip)
        if star == "*" then e.fresh[ip] = true end
    end
    return e
end
local function check(name, ip, strong, ifn, live, want_ip, want_iot)
    local got_ip, got_iot = device_net(ip, strong, ifn, L(live), "192.168.50", function(i) return i == "wl1.4" end)
    if got_ip ~= want_ip or got_iot ~= want_iot then
        fails = fails + 1
        print(("FAIL: %s: got %s %s, want %s %s"):format(name, tostring(got_ip), tostring(got_iot), tostring(want_ip), tostring(want_iot)))
    end
end
-- A home server with a leftover fixed IoT address, now on the home Wi-Fi with a static one.
check("home Wi-Fi beats an old IoT address", "192.168.50.200", false, "wl0.1", "lan=192.168.0.55*", "192.168.0.55", false)
check("home Wi-Fi, no neighbour entry yet", "192.168.50.200", false, "wl0.1", nil, nil, false)
check("only in the home neighbour table, fresh", "192.168.50.200", false, "", "lan=192.168.0.55*", "192.168.0.55", false)
check("only in the home neighbour table, older entry, pin only", "192.168.50.200", false, "", "lan=192.168.0.55", "192.168.0.55", false)
check("wired on a home port", "192.168.0.9", true, "eth1", nil, "192.168.0.9", false)
-- IoT devices stay IoT.
check("on the IoT Wi-Fi", "192.168.50.137", true, "wl1.4", "iot=192.168.50.137*", "192.168.50.137", true)
check("on the IoT Wi-Fi, no neighbour entry", "192.168.50.137", true, "wl1.4", nil, "192.168.50.137", true)
check("on the IoT Wi-Fi with an old home lease", "192.168.0.30", true, "wl1.4", nil, nil, true)
check("only in the IoT neighbour table, fresh", "192.168.0.30", true, nil, "iot=192.168.50.12*", "192.168.50.12", true)
-- A stale entry doesn't overrule live information (review finding).
check("old IoT entry vs a current home lease", "192.168.0.55", true, "", "iot=192.168.50.200", "192.168.0.55", false)
check("old home entry vs a current IoT lease", "192.168.50.20", true, "", "lan=192.168.0.20", "192.168.50.20", true)
-- Several addresses on one bridge: the known one, else a fresh one, whatever the order.
check("known address among two, first", "192.168.0.55", true, "wl0.1", "lan=192.168.0.55 lan=192.168.0.44", "192.168.0.55", false)
check("known address among two, second", "192.168.0.55", true, "wl0.1", "lan=192.168.0.44 lan=192.168.0.55", "192.168.0.55", false)
check("no known address: the fresh one", "192.168.50.200", false, "wl0.1", "lan=192.168.0.44 lan=192.168.0.55*", "192.168.0.55", false)
check("no known address: the fresh one, other order", "192.168.50.200", false, "wl0.1", "lan=192.168.0.55* lan=192.168.0.44", "192.168.0.55", false)
-- Live information on the device's network beats an older neighbour entry (review).
check("current lease vs a lone stale entry", "192.168.0.55", true, "wl0.1", "lan=192.168.0.44", "192.168.0.55", false)
check("a weak address doesn't pick among stale entries", "192.168.0.44", false, "wl0.1", "lan=192.168.0.44 lan=192.168.0.55*", "192.168.0.55", false)
-- An IoT client never shows a home address (review).
check("IoT Wi-Fi, only a home neighbour entry", "192.168.50.137", true, "wl1.4", "lan=192.168.0.30*", "192.168.50.137", true)
check("home Wi-Fi, only an IoT neighbour entry", "192.168.0.55", true, "wl0.1", "iot=192.168.50.200*", "192.168.0.55", false)
-- Offline, or no telling: the address decides, as before.
check("offline with a fixed IoT address", "192.168.50.10", false, nil, nil, "192.168.50.10", true)
check("offline home device", "192.168.0.9", true, "", nil, "192.168.0.9", false)
check("in both neighbour tables, not associated", "192.168.50.20", true, nil, "lan=192.168.0.20* iot=192.168.50.20*", "192.168.50.20", true)
check("no address at all", nil, true, nil, nil, nil, false)
-- offer: the best source wins whatever order they come in.
local function best(list)
    local c = {}
    for _, o in ipairs(list) do M.offer(c, "m", o[1], o[3], o[2]) end
    return c.m and c.m.ip, c.m and c.m.rank >= M.RANK.fresh, c.m and c.m.host
end
local function ocheck(name, list, want_ip, want_strong, want_host)
    local ip, strong, host = best(list)
    if ip ~= want_ip or strong ~= want_strong or host ~= want_host then
        fails = fails + 1
        print(("FAIL: offer %s: got %s %s %s"):format(name, tostring(ip), tostring(strong), tostring(host)))
    end
end
ocheck("TP-Link's list beats an old IoT pin", { { "192.168.50.200", "pin" }, { "192.168.0.55", "stock", "tiny" } }, "192.168.0.55", true, "tiny")
ocheck("and in the other order", { { "192.168.0.55", "stock", "tiny" }, { "192.168.50.200", "pin" } }, "192.168.0.55", true, "tiny")
ocheck("a lease beats a stale entry", { { "192.168.0.44", "arp" }, { "192.168.0.55", "lease", "box" } }, "192.168.0.55", true, "box")
ocheck("a fresh entry beats a stale one", { { "192.168.0.44", "arp" }, { "192.168.0.55", "fresh" } }, "192.168.0.55", true, nil)
ocheck("a pin alone is weak", { { "192.168.50.10", "pin" } }, "192.168.50.10", false, nil)
ocheck("0.0.0.0 is no address", { { "0.0.0.0", "stock", "x" }, { "192.168.0.9", "arp" } }, "192.168.0.9", false, "x")
ocheck("a setting alone has no address", { { nil, "none" } }, nil, false, nil)
if fails > 0 then os.exit(1) end
print("device_net tests passed")
