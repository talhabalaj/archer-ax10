-- The dashboard's backend (web/dashboard), a LuCI controller at /admin/ax10.
-- Installed by `ax10.sh ui` into a bind-mounted copy of luci/controller/admin.
-- Follows the stock controllers' pattern: a dispatch table of form -> operation -> cb,
-- run through luci.model.controller, which handles the (encrypted) request framing.
module("luci.controller.admin.ax10", package.seeall)

local uci  = require "luci.model.uci"
local ctl  = require "luci.model.controller"
local json = require "luci.json"
local http = require "luci.http"
local nixio = require "nixio"

local SEC  = "archer_boot"
-- Through sh: a freshly installed or rebuilt /tmp/ax10.sh may not be executable.
local IOT  = "/bin/sh /tmp/ax10.sh"
-- What to say when an ax10.sh command could not run: almost always it gave up waiting
-- for the run lock (exit 75) because a long change was being applied.
local BUSY = "the router is busy applying an earlier change; try again in a moment"

local function get(k, d)
    local v = uci.cursor():get("openvpn", SEC, "iot_" .. k)
    if v == nil or v == "" then return d end
    return v
end

local function words(s)       -- a space-separated setting, or a UCI list (a table)
    local t = {}
    if type(s) == "table" then for _, w in ipairs(s) do t[#t + 1] = w end; return t end
    for w in (s or ""):gmatch("%S+") do t[#t + 1] = w end
    return t
end

local function has(list, v)
    for _, x in ipairs(list) do if x:lower() == v:lower() then return true end end
    return false
end

-- ax10.sh's run lock (src/10-lock.sh): the kernel's lockf on /tmp/ax10-iot/run.lock,
-- held around every settings write made here, so ax10.sh never saves between our read
-- and our write (or we between its). Only around our own writes: ax10.sh commands
-- called from here take the lock themselves, and would wait for us forever.
-- Closing the file lets the lock go; so does this process ending.
local function locked(fn)
    nixio.fs.mkdir("/tmp/ax10-iot")
    local f = nixio.open("/tmp/ax10-iot/run.lock", "w")
    if not f then return false, "-1" end
    local deadline = os.time() + 30
    while not f:lock("tlock") do
        if os.time() >= deadline then f:close(); return false, "-1" end
        nixio.nanosleep(0, 200000000)
    end
    local ok, a, b = pcall(fn)
    f:close()
    if not ok then error(a, 0) end
    return a, b
end

-- Save options. TP-Link's cursor:commit also writes the config to flash.
local function save(opts)
    local c = uci.cursor()
    if not locked(function()
        for k, v in pairs(opts) do c:set("openvpn", SEC, "iot_" .. k, v) end
        c:commit("openvpn")
        return true
    end) then return false end
    -- Saved; `ax10.sh kick` does the rest (it brings the IoT network up, or takes
    -- it down if it was switched off). "up" lifts a stop made by hand on the router.
    local on = c:get("openvpn", SEC, "iot_enabled") == "1"
    os.execute(IOT .. (on and " kick up" or " kick") .. " >/dev/null 2>&1 &")
    return true
end

------------------------------------------------------------------ device info
-- Custom names: UCI list iot_names, entries "mac=name". Saving a name only
-- writes the config; it does not re-apply the network.
local function names()
    local t = {}
    local v = uci.cursor():get("openvpn", SEC, "iot_names")
    if type(v) == "string" then v = { v } end
    for _, e in ipairs(v or {}) do
        local m, n = e:match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)=(.+)$")
        if m then t[m:lower()] = n end
    end
    return t
end

-- set_names({ [mac] = name or "" }): one read and one save for any number of names
-- ("" clears a name). False if the lock stayed busy and nothing was saved.
local function set_names(changes)
    return locked(function()      -- the list is read and written back under the lock
        local t = names()
        for mac, name in pairs(changes) do
            name = (name or ""):gsub("[\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
            t[mac] = (name ~= "" and #name <= 40) and name or nil
        end
        local list = {}
        for m, n in pairs(t) do list[#list + 1] = m .. "=" .. n end
        local c = uci.cursor()
        if #list > 0 then c:set("openvpn", SEC, "iot_names", list) else c:delete("openvpn", SEC, "iot_names") end
        c:commit("openvpn")
        return true
    end)
end
local function set_name(mac, name) return set_names({ [mac] = name or "" }) end

-- One device's entry in a per-device list (caps, noinet, guest_fast, lan_allow, lan_open),
-- changed by ax10.sh under its run lock, so the watcher and other requests never
-- write a stale copy of the list. Every writer of these lists goes through here.
local function set_entry(key, mac, value)
    return os.execute(IOT .. " entry " .. key .. " " .. mac .. " " .. value .. " >/dev/null 2>&1") == 0
end
-- Apply saved changes without making the request wait for it. `kick`, not `sync`:
-- a burst of changes becomes one worker instead of a queue of them.
local function sync_later() os.execute(IOT .. " kick >/dev/null 2>&1 &") end

local function sh(cmd)
    local f = io.popen(cmd .. " 2>/dev/null"); if not f then return "" end
    local out = f:read("*a") or ""; f:close(); return out
end

-- Where each MAC is connected right now: Wi-Fi network (SSID and band), a wired
-- LAN port, the mesh satellite, or "Online" from the ARP table.
-- One shell run gathers everything (each popen costs two process starts on this
-- CPU); the SSID is only looked up for networks that have clients.
local PROBE = [[
cd /sys/class/net || exit 0
for i in wl[0-9].[0-9]; do
    [ -d "$i" ] || continue
    m="$(/usr/sbin/wl -i $i assoclist)"; [ -n "$m" ] || continue
    echo "W $i $(/usr/sbin/wl -i $i ssid)"; echo "$m"
    for s in $(echo "$m" | awk '{print $2}'); do
        /usr/sbin/wl -i $i sta_info $s 2>/dev/null | awk -v s=$s '
            /tx total bytes:/ {t=$4} /rx data bytes:/ {r=$4} /^smoothed rssi:/ {q=$3}
            /rate of last tx pkt:/ {x=$6} /in network/ {u=$3}
            END {printf "S %s %.0f %.0f %d %d %d\n", s, t, r, q, x, u}'
    done
done
for p in br-lan/brif/*; do [ -f "$p/port_no" ] && echo "P ${p##*/} $(cat $p/port_no)"; done
echo F; brctl showmacs br-lan
echo A; cat /proc/net/arp
]]
local function uptime()
    local f = io.open("/proc/uptime"); if not f then return 0 end
    local v = tonumber((f:read("*l") or ""):match("^(%S+)")) or 0; f:close(); return v
end
-- { {mac, connection_type} } for the mesh satellites' Wi-Fi clients, from TP-Link's
-- /tmp/easymesh_client_list; {} if it is missing or not the JSON we expect.
local function mesh_stations(text)
    if not text then
        local f = io.open("/tmp/easymesh_client_list"); if not f then return {} end
        text = f:read("*a") or ""; f:close()
    end
    local ok, d = pcall(json.decode, text)
    local out = {}
    local list = ok and type(d) == "table" and d.easymesh_client_list
    if type(list) ~= "table" then return out end
    for _, agent in ipairs(list) do
        local grid = type(agent) == "table" and agent.StationGrid
        if type(grid) == "table" then
            for _, o in ipairs(grid) do
                local raw = type(o) == "table" and type(o.mac) == "string" and
                    o.mac:match("^%x%x[%-:]%x%x[%-:]%x%x[%-:]%x%x[%-:]%x%x[%-:]%x%x$")
                if raw then
                    out[#out + 1] = { (raw:lower():gsub("-", ":")), type(o.connection_type) == "string" and o.connection_type or "" }
                end
            end
        end
    end
    return out
end
local function probe()
    local at, atif, st, ports, mode, where, ifn = {}, {}, {}, {}, "", nil, nil
    for line in sh(PROBE):gmatch("[^\n]+") do
        local smac, stx, srx, srssi, srate, sup = line:match("^S (%S+) (%d+) (%d+) (%-?%d+) (%d+) (%d+)$")
        if smac then
            st[smac:lower()] = { down = tonumber(stx), up = tonumber(srx), rssi = tonumber(srssi),
                                 rate = math.floor(tonumber(srate) / 1000), conn = tonumber(sup) }
        end
        local wif, rest = line:match("^W (%S+) (.*)$")
        local pif, pno = line:match("^P (%S+) (%S+)$")
        if wif then
            ifn = wif
            where = (rest:match('"(.*)"') or ifn) .. " (" .. (ifn:match("^wl0") and "5 GHz" or "2.4 GHz") .. ")"
            mode = "W"
        elseif pif then ports[tonumber(pno, 16) or -1] = pif
        elseif line == "F" or line == "A" then mode = line
        elseif smac then -- handled above
        elseif mode == "W" then
            local mac = line:match("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
            if mac then at[mac:lower()] = where; atif[mac:lower()] = ifn end
        elseif mode == "F" then
            local no, mac, islocal = line:match("^%s*(%d+)%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(%a+)")
            if mac and islocal == "no" and not at[mac:lower()] then
                local pn = ports[tonumber(no)] or ""
                if pn:match("^eth") then at[mac:lower()] = "Wired"; atif[mac:lower()] = pn
                elseif pn:match("^wds") then at[mac:lower()] = "Mesh satellite"; atif[mac:lower()] = pn end
            end
        elseif mode == "A" then
            local flags, mac = line:match("^%S+%s+%S+%s+(%S+)%s+(%S+)")
            if flags == "0x2" and mac and not at[mac:lower()] then at[mac:lower()] = "Online" end
        end
    end
    -- The mesh satellite's Wi-Fi clients (TP-Link's EasyMesh list). On a wired
    -- backhaul they come in on a LAN port, which would read as "Wired". Decoded as
    -- JSON: client names are chosen by their owners and may hold any punctuation.
    for _, st_ in ipairs(mesh_stations()) do
        local mac, ct = st_[1], st_[2]
        local w = at[mac]
        if w == nil or w == "Wired" or w == "Online" or w:match("^Mesh satellite") then
            local band = ct:match("^5") and " (5 GHz)" or ct:match("^2") and " (2.4 GHz)" or ""
            at[mac] = "Mesh satellite" .. band
        end
    end
    return at, atif, st
end

-- A page asks for two or three device lists at once; they share one probe through
-- a short-lived cache file ("<unix time> <uptime>" then lines of
-- "mac<TAB>ifname<TAB>down<TAB>up<TAB>rssi<TAB>rate<TAB>conn<TAB>where").
-- Returns mac -> where, mac -> interface ("" when only seen in ARP), mac -> Wi-Fi
-- station stats (bytes down/up since it connected, signal, link Mbps, seconds), and
-- the uptime the probe ran at (for speeds: bytes over time between two calls).
local PRESENCE_CACHE, PRESENCE_TTL = "/tmp/ax10-iot/presence", 3
local function presence()
    local f = io.open(PRESENCE_CACHE)
    if f then
        local head = f:read("*l") or ""
        local stamp, t = head:match("^(%d+) (%S+)$")
        stamp = tonumber(stamp)
        if stamp and os.time() - stamp >= 0 and os.time() - stamp < PRESENCE_TTL then
            local at, atif, st = {}, {}, {}
            for line in f:lines() do
                local mac, ifn, d, u, q, r, c, where = line:match("^(%S+)\t(%S*)\t(%S*)\t(%S*)\t(%S*)\t(%S*)\t(%S*)\t(.+)$")
                if mac then
                    at[mac] = where; atif[mac] = ifn
                    if d ~= "" then st[mac] = { down = tonumber(d), up = tonumber(u), rssi = tonumber(q), rate = tonumber(r), conn = tonumber(c) } end
                end
            end
            f:close(); return at, atif, st, tonumber(t) or 0
        end
        f:close()
    end
    local t0 = uptime()
    local at, atif, st = probe()
    local tmp = PRESENCE_CACHE .. "." .. os.time() .. math.random(1000, 9999)
    f = io.open(tmp, "w")
    if f then
        f:write(os.time(), " ", t0, "\n")
        for mac, where in pairs(at) do
            local x = st[mac] or {}
            f:write(mac, "\t", atif[mac] or "", "\t", x.down or "", "\t", x.up or "", "\t", x.rssi or "", "\t",
                    x.rate or "", "\t", x.conn or "", "\t", where, "\n")
        end
        f:close(); os.rename(tmp, PRESENCE_CACHE)
    end
    return at, atif, st, t0
end

local function valid_ssid(s) return s and #s >= 1 and #s <= 32 end
local function valid_key(s) return s and #s >= 8 and #s <= 63 end

---------------------------------------------------------------- settings form
local function read_settings()
    return {
        enable   = get("enabled", "0") == "1" and "on" or "off",
        ssid     = get("ssid", ""),
        password = get("key", ""),
        hidden   = get("hidden", "0") == "1" and "on" or "off",
        gateway  = get("ip", "192.168.50.1"),
        allow_lan = get("allow_lan", ""),
        lan_mode = get("lan_mode", "all"),
        lock     = get("lock", "0") == "1" and "on" or "off",
        open_left = (function()
            local f = io.open("/tmp/ax10-iot/open_until"); if not f then return 0 end
            local u = tonumber(f:read("*l") or ""); f:close()
            local uf = io.open("/proc/uptime"); local now = uf and tonumber((uf:read("*l") or ""):match("^(%d+)")) or 0
            if uf then uf:close() end
            return (u and u > now) and (u - now) or 0
        end)(),
    }
end

-- IoT -> home rules (iot_allow_lan), as ax10.sh's allow_rule reads them: "tcp:8123",
-- "udp:6001-6010" or "any", then optionally "@<IoT address>" and ">home address".
-- Returns the rules cleaned up, or nil and the first one that isn't a rule.
local function clean_rules(s)
    local function ip_ok(ip)
        local o = { ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
        if #o ~= 4 then return false end
        for _, n in ipairs(o) do if tonumber(n) > 255 or n:match("^0%d") then return false end end   -- 010 would be octal to iptables
        return true
    end
    -- what[@from][>to]: tcp:80, udp:6001-6010 or any; IoT address; home address.
    local out = {}
    for w in tostring(s or ""):gmatch("%S+") do
        local r, to = w:match("^([^>]+)>(.*)$")
        if not r then r = w end
        local what, from = r:match("^([^@]+)@(.*)$")
        if not what then what = r end
        if (from and not ip_ok(from)) or (to and not ip_ok(to)) then return nil, w end
        local rule
        if what == "any" then rule = "any"
        else
            local proto, a, b = what:match("^(%l+):(%d+)[%-:](%d+)$")
            if not proto then proto, a = what:match("^(%l+):(%d+)$") end
            a, b = tonumber(a), tonumber(b)
            if (proto ~= "tcp" and proto ~= "udp") or not a or a < 1 or a > 65535
                or (b and (b < a or b > 65535)) then return nil, w end
            rule = proto .. ":" .. a .. ((b and b ~= a) and ("-" .. b) or "")
        end
        out[#out + 1] = rule .. (from and ("@" .. from) or "") .. (to and (">" .. to) or "")
    end
    return table.concat(out, " ")
end

local function write_settings(form)
    local ssid, key = form.ssid, form.password
    if form.enable == "on" then
        if not valid_ssid(ssid) then return false, "-1" end
        if not valid_key(key) then return false, "-1" end
    end
    local opts = {
        enabled = (form.enable == "on") and "1" or "0",
        hidden  = (form.hidden == "on") and "1" or "0",
    }
    if ssid ~= nil then opts.ssid = ssid end
    if key ~= nil then opts.key = key end
    if form.allow_lan ~= nil then
        local rules, bad = clean_rules(form.allow_lan)
        if not rules then return false, "not a rule: " .. bad .. " (it looks like tcp:8123, udp:6001-6010 or any, then optionally @<IoT address> and >home address)" end
        opts.allow_lan = rules
    end
    if form.lan_mode == "all" or form.lan_mode == "selected" then opts.lan_mode = form.lan_mode end
    if form.lock == "on" or form.lock == "off" then opts.lock = form.lock == "on" and "1" or "0" end
    if not save(opts) then return false, BUSY end
    return read_settings()
end

------------------------------------------------------------ guest speed limit
-- Settings live next to the IoT ones (iot_guest_*); ax10.sh's watcher applies them.
-- A full sync, not just `shape`: it also registers the watcher, which is what applies
-- the guest limit to a guest who joins later.
local function guest_apply() os.execute(IOT .. " kick >/dev/null 2>&1 &") end

local function read_guest_settings()
    return {
        enable = get("guest_limit", "0") == "1" and "on" or "off",
        down   = get("guest_down", "5"),
        up     = get("guest_up", "2"),
    }
end

local function write_guest_settings(form)
    local d, u = tonumber(form.down), tonumber(form.up)
    if form.enable == "on" and (not d or not u or d < 1 or u < 1 or d > 1000 or u > 1000) then
        return false, "-1"
    end
    if not locked(function()
        local c = uci.cursor()
        c:set("openvpn", SEC, "iot_guest_limit", form.enable == "on" and "1" or "0")
        if d then c:set("openvpn", SEC, "iot_guest_down", tostring(math.floor(d))) end
        if u then c:set("openvpn", SEC, "iot_guest_up", tostring(math.floor(u))) end
        c:commit("openvpn")
        return true
    end) then return false, BUSY end
    guest_apply()
    return read_guest_settings()
end


---------------------------------------------------------------- dashboard
-- The dashboard at / (web/dashboard) asks for everything in one call.
local MAC_PAT = "^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$"
local function normmac(m) return ((m or ""):lower():gsub("-", ":")) end

-- The stock Access Control block list (macs stored as "AA-BB-..."), and its state.
local function blocklist()
    local c, out = uci.cursor(), {}
    c:foreach("access_control", "black_list", function(sct)
        if sct.mac then out[normmac(sct.mac)] = true end
    end)
    return out, c:get("access_control", "settings", "enable") or "off",
           c:get("access_control", "settings", "access_mode") or "black"
end

-- TP-Link's per-client traffic counter (ubus tfstats). It misses most accelerated
-- traffic, so it is only used, marked approximate, for devices the Wi-Fi driver can't
-- see (wired, or behind the mesh satellite). rx is what the router received: upload.
local function tfstats()
    local t = {}
    local okj, r = pcall(json.decode, sh("ubus call tfstats get '{\"page\":0,\"pagesize\":210}'"))
    if okj and type(r) == "table" and type(r.tfslist) == "table" then
        for _, e in ipairs(r.tfslist) do
            if e.mac then t[normmac(e.mac)] = { down = tonumber(e.total_tx_byte) or 0, up = tonumber(e.total_rx_byte) or 0 } end
        end
    end
    return t
end

local function guest_ifaces()
    local g = {}
    uci.cursor():foreach("wireless", "wifi-iface", function(sct)
        if sct.guest == "on" and sct.ifname then g[sct.ifname] = true end
    end)
    return g
end

-- Per-device speed caps: iot_caps "mac=down/up ..." (Mbps, 0 = no cap that way).
local function caps()
    local t = {}
    for _, e in ipairs(words(get("caps", ""))) do
        local m, d, u = e:match("^([%x:-]+)=(%d+)/(%d+)$")
        if m then t[normmac(m)] = { down = tonumber(d), up = tonumber(u) } end
    end
    return t
end

-- Every device in the DHCP leases (MACs seen only on the air or in ARP are the mesh
-- satellite's own radios, not clients), plus offline devices that still have a setting
-- (blocked, full speed, allowed to reach IoT, Internet off) so it can be undone.
-- TP-Link's client list (/tmp/client_list.json): mac -> { name, ip, connected }.
local function stock_clients()
    local t = {}
    local f = io.open("/tmp/client_list.json"); if not f then return t end
    local s = f:read("*a") or ""; f:close()
    for obj in s:gmatch("{[^{}]*}") do
        local m = obj:match('"mac":"([^"]+)"')
        if m then
            t[normmac(m)] = { name = obj:match('"name":"([^"]*)"') or "", ip = obj:match('"ip":"([^"]*)"'),
                              on = obj:match('"connect_status":1') ~= nil }
        end
    end
    return t
end

-- [device_net] ------------------------------------------------- which network
-- Which network a device is on, and its address there. What it is connected to now
-- decides, not an address: a lease or a fixed IoT address can be left over from
-- when the device was on the other network (a home server once set up on the IoT
-- Wi-Fi keeps its IoT pin after it moves to the home Wi-Fi with a static address).
--   ip     the address found for it, or nil
--   strong true if ip is live information (a lease, TP-Link's client list), false
--          if it is only a setting (a fixed IoT address)
--   ifn    the Wi-Fi interface or LAN port it is on now, or nil / ""
--   live   its neighbour-table entries: { lan = {ip...}, iot = {ip...}, fresh = {[ip] = true} }
--          (fresh: confirmed reachable just now; other entries can be minutes old)
--   prefix the IoT subnet's first three octets, e.g. "192.168.50"
--   on_iot_if(ifn): is that interface a port of the IoT bridge?
-- Returns the address to show (nil when the known one is from the other network)
-- and whether the device is on the IoT network.
local function device_net(ip, strong, ifn, live, prefix, on_iot_if)
    local function in_iot(a) return a ~= nil and a:sub(1, #prefix + 1) == prefix .. "." end
    live = live or {}
    local fresh = live.fresh or {}
    -- One address from a bridge's entries: the one we already know, else a fresh one.
    local function pick(list, fresh_only)
        if not list then return nil end
        if strong then for _, x in ipairs(list) do if x == ip and (fresh[x] or not fresh_only) then return x end end end
        for _, x in ipairs(list) do if fresh[x] then return x end end
        if not fresh_only then return list[1] end
    end
    local iot
    if ifn and ifn ~= "" then iot = on_iot_if(ifn)
    else
        -- Only the neighbour table: a fresh entry on one side decides; an older one
        -- only when it doesn't contradict live information we have.
        local fl, fi = pick(live.lan, true), pick(live.iot, true)
        if fl and not fi then iot = false
        elseif fi and not fl then iot = true
        elseif not fl and not fi then
            if live.lan and not live.iot and not (strong and in_iot(ip)) then iot = false
            elseif live.iot and not live.lan and not (strong and ip and not in_iot(ip)) then iot = true end
        end
    end
    if iot == nil then return ip, in_iot(ip) end          -- offline or unclear: the address
    local list
    if iot then list = live.iot else list = live.lan end
    local same = ip ~= nil and in_iot(ip) == iot
    -- A fresh entry, else live information on that network, else an older entry.
    local now = pick(list, true)
    if now then return now, iot end
    if strong and same then return ip, iot end
    now = pick(list)
    if now then return now, iot end
    if same then return ip, iot end
    return nil, iot
end

-- Every address found for a device, keeping the best: TP-Link's list of connected
-- clients, then a lease, then a fresh neighbour entry, then an older one, then a
-- fixed IoT address (a setting, not evidence of where it is). Gathered before the
-- device is placed, so a weaker source seen first can't decide.
local RANK = { stock = 4, lease = 3, fresh = 2, arp = 1, pin = 0, none = -1 }
local function offer(cands, mac, ip, host, kind)
    local c = cands[mac]
    if not c then c = { rank = -1 }; cands[mac] = c end
    if host and host ~= "" and host ~= "*" and not c.host then c.host = host end
    if ip and ip ~= "" and ip ~= "0.0.0.0" and RANK[kind] > c.rank then c.ip, c.rank = ip, RANK[kind] end
end
-- [/device_net] ----------------------------------------------------------------

local IOT_BR = "br-iot"
local function devices()
    local at, atif, st, t = presence()
    local tf = tfstats()
    local nm, gif = names(), guest_ifaces()
    local blocked, ac_enable, ac_mode = blocklist()
    local noinet, fast, allow = words(get("noinet", "")), words(get("guest_fast", "")), words(get("lan_allow", ""))
    local open = words(get("lan_open", ""))
    local cp = caps()
    local pins = {}
    for _, e in ipairs(words(get("static", ""))) do
        local m, ip = e:match("^([%x:]+),(%S+)$")
        if m then pins[normmac(m)] = ip end
    end
    local prefix = get("ip", "192.168.50.1"):match("^(%d+%.%d+%.%d+)%.") or "192.168.50"
    -- The neighbour table: each MAC's addresses on the home and the IoT bridge, and
    -- which of them were confirmed reachable just now (REACHABLE, DELAY, PROBE).
    local live = {}
    for line in sh("/usr/sbin/ip -4 neigh show"):gmatch("[^\n]+") do
        local ip, dev, m = line:match("^(%d+%.%d+%.%d+%.%d+) dev (%S+) lladdr (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
        local state = line:match("(%u+)%s*$")
        if ip and (dev == "br-lan" or dev == IOT_BR) and state ~= "FAILED" and state ~= "INCOMPLETE" then
            m = normmac(m)
            local e = live[m] or { lan = nil, iot = nil, fresh = {} }
            live[m] = e
            local side = dev == IOT_BR and "iot" or "lan"
            e[side] = e[side] or {}
            table.insert(e[side], ip)
            if state == "REACHABLE" or state == "DELAY" or state == "PROBE" or state == "PERMANENT" then e.fresh[ip] = true end
        end
    end
    local iot_ports = {}
    local function on_iot_if(ifn)
        if iot_ports[ifn] == nil then
            local f = io.open("/sys/class/net/" .. IOT_BR .. "/brif/" .. ifn .. "/port_no")
            iot_ports[ifn] = f ~= nil
            if f then f:close() end
        end
        return iot_ports[ifn]
    end
    local ok, addr = pcall(http.getenv, "REMOTE_ADDR")
    local me = ((ok and addr) or os.getenv("REMOTE_ADDR") or ""):gsub("^::ffff:", "")
    local rows, seen = {}, {}
    -- Last seen (ax10.sh home_seen, wall-clock seconds) and devices forgotten on the
    -- dashboard (hidden while offline).
    local last, hidden = {}, {}
    local lf = io.open("/tmp/ax10-iot/home_seen")
    if lf then
        for line in lf:lines() do local m, t = line:match("^(%S+) (%d+)"); if m then last[m] = tonumber(t) end end
        lf:close()
    end
    for _, m in ipairs(words(get("hidden_devices", ""))) do hidden[normmac(m)] = true end
    local stock = stock_clients()
    local function add(mac, ip, host, strong)
        mac = normmac(mac)
        if seen[mac] or not mac:match(MAC_PAT) then return end
        -- Forgotten devices stay off the list while offline. Online by any source
        -- counts (the mesh satellite's clients are only in TP-Link's list), and a
        -- blocked device stays, so it can still be unblocked.
        if hidden[mac] and not at[mac] and not (stock[mac] and stock[mac].on) and not blocked[mac] then return end
        seen[mac] = true
        -- "This device": the requester's address is any of the device's, whichever is shown.
        local this = me ~= "" and ip == me
        for _, side in ipairs({ "lan", "iot" }) do
            for _, x in ipairs((live[mac] or {})[side] or {}) do if x == me then this = true end end
        end
        local iot
        ip, iot = device_net(ip, strong ~= false, atif[mac], live[mac], prefix, on_iot_if)
        local net = iot and "iot" or (gif[atif[mac] or ""] and "guest") or "home"
        rows[#rows + 1] = {
            mac = mac:upper(), ip = ip or "", host = (host ~= "*" and host) or "",
            name = nm[mac] or "", where = at[mac] or "", online = at[mac] and true or false,
            net = net, this = this, blocked = blocked[mac] or false,
            internet = not has(noinet, mac), fast = has(fast, mac), allowed = has(allow, mac), reach = has(open, mac),
            cap = cp[mac] or false, pinned = pins[mac] or false, seen = last[mac],
        }
        local r, x = rows[#rows], st[mac]
        if x then r.down, r.up, r.rssi, r.rate, r.conn = x.down, x.up, x.rssi, x.rate, x.conn
        elseif tf[mac] then r.down, r.up, r.approx = tf[mac].down, tf[mac].up, true end
    end
    -- Every device we know of, with each source's address (offer keeps the best):
    -- leases; fixed IoT addresses (also devices without a lease right now); the
    -- neighbour table (devices that kept their address through a router reboot, or
    -- set a static one); TP-Link's client list (satellite clients); and offline
    -- devices that still have a setting.
    local cands = {}
    local function offer_(m, ip, host, kind) offer(cands, normmac(m), ip, host, kind) end
    local f = io.open("/tmp/dhcp.leases")
    if f then
        for line in f:lines() do
            local _, mac, ip, host = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if mac then offer_(mac, ip, host, "lease") end
        end
        f:close()
    end
    for m, ip in pairs(pins) do offer_(m, ip, nil, "pin") end
    for m, e in pairs(live) do
        for _, side in ipairs({ "lan", "iot" }) do
            for _, ip in ipairs(e[side] or {}) do offer_(m, ip, nil, e.fresh[ip] and "fresh" or "arp") end
        end
    end
    for m, c in pairs(stock) do if c.on then offer_(m, c.ip, c.name, "stock") end end
    for _, l in ipairs({ noinet, fast, allow, open }) do for _, m in ipairs(l) do offer_(m, nil, nil, "none") end end
    for m in pairs(blocked) do offer_(m, nil, nil, "none") end
    for m in pairs(cp) do offer_(m, nil, nil, "none") end
    for m, c in pairs(cands) do add(m, c.ip, c.host, c.rank >= RANK.fresh) end
    return { list = rows, t = t, now = os.time(), lan_mode = get("lan_mode", "all"), iot_enabled = get("enabled", "0") == "1",
             guest_limit = get("guest_limit", "0") == "1",
             guest_down = tonumber(get("guest_down", "5")), guest_up = tonumber(get("guest_up", "2")),
             wan_shape = get("wan_shape", "0") == "1",
             block = { enable = ac_enable, mode = ac_mode } }
end

-- Expand an IPv6 address to the zero-padded form conntrack prints.
local function v6full(a)
    local head, tail = a:match("^(.-)::(.*)$")
    local function groups(x) local g = {} for p in (x or ""):gmatch("[^:]+") do g[#g + 1] = p end return g end
    local h, t = groups(head or a), groups(tail)
    if not head then t = {} end
    local out = {}
    for _, p in ipairs(h) do out[#out + 1] = ("%04x"):format(tonumber(p, 16) or 0) end
    for _ = 1, 8 - #h - #t do out[#out + 1] = "0000" end
    for _, p in ipairs(t) do out[#out + 1] = ("%04x"):format(tonumber(p, 16) or 0) end
    return table.concat(out, ":")
end

-- Everything we know about one device: Wi-Fi link details from the driver, its
-- addresses, DHCP lease, open connections, and byte counters for live speed.
local function client(form)
    local mac = normmac(form.mac)
    if not mac:match(MAC_PAT) then return false, "-1" end
    local at, atif, st, t = presence()
    local d = { mac = mac:upper(), t = uptime(), where = at[mac] or "", iface = atif[mac] or "" }
    -- IPv4 and lease
    local f = io.open("/tmp/dhcp.leases")
    if f then
        for line in f:lines() do
            local exp, m, ip, host = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if m and normmac(m) == mac then
                d.ip, d.host = ip, (host ~= "*" and host) or ""
                local e = tonumber(exp)
                if e then d.lease_left = math.floor(e - d.t) end
            end
        end
        f:close()
    end
    if not d.ip then
        for line in sh("cat /proc/net/arp"):gmatch("[^\n]+") do
            local ip, m = line:match("^(%S+)%s+%S+%s+%S+%s+(%S+)")
            if m and normmac(m) == mac then d.ip = ip end
        end
    end
    -- IPv6 addresses
    d.ipv6 = {}
    for line in sh("ip -6 neigh show"):gmatch("[^\n]+") do
        local a, m = line:match("^(%S+) .*lladdr (%S+)")
        if a and normmac(m) == mac and not line:match("FAILED") then d.ipv6[#d.ipv6 + 1] = a end
    end
    -- Open connections (conntrack prints IPv6 zero-padded)
    local keys = {}
    if d.ip then keys[#keys + 1] = "src=" .. d.ip .. " " end
    for _, a in ipairs(d.ipv6) do keys[#keys + 1] = "src=" .. v6full(a) .. " " end
    local n = 0
    local cf = io.open("/proc/net/nf_conntrack")
    if cf then
        for line in cf:lines() do
            for _, k in ipairs(keys) do if line:find(k, 1, true) then n = n + 1; break end end
        end
        cf:close()
    end
    d.connections = n
    -- Wi-Fi link
    local ifn = atif[mac] or ""
    if ifn:match("^wl") then
        local info = sh("/usr/sbin/wl -i " .. ifn .. " sta_info " .. mac:upper())
        local w = { iface = ifn }
        local function num(pat) return tonumber(info:match(pat)) end
        w.chanspec = info:match("chanspec (%S+)")
        w.auth = info:match("auth: (%S+)")
        w.crypto = info:match("crypto: (%S+)")
        w.down, w.up = num("tx total bytes: (%d+)"), num("rx data bytes: (%d+)")
        w.tx_pkts, w.tx_retries = num("tx total pkts sent: (%d+)"), num("tx pkts retries: (%d+)")
        w.rx_pkts, w.rx_retried = num("rx data pkts: (%d+)"), num("rx total pkts retried: (%d+)")
        w.conn, w.idle = num("in network (%d+)"), num("idle (%d+)")
        w.rssi = num("smoothed rssi: (%-?%d+)")
        local a1, a2 = info:match("average rssi of rx data frames: (%-?%d+) (%-?%d+)")
        w.antennas = {}
        for _, v in ipairs({ tonumber(a1), tonumber(a2) }) do if v and v ~= 0 then w.antennas[#w.antennas + 1] = v end end
        w.noise = tonumber(info:match("noise floor: (%-?%d+)"))
        w.tx_rate = math.floor((num("rate of last tx pkt: (%d+)") or 0) / 1000)
        w.rx_rate = math.floor((num("rate of last rx pkt: (%d+)") or 0) / 1000)
        w.tx_nrate = info:match("tx nrate\n([^\n]+)")
        w.rx_nrate = info:match("rx nrate\n([^\n]+)")
        w.width = info:match("link bandwidth = (%d+) MHZ")
        w.streams = info:match("rx=(%d)ss")
        w.standard = info:match("HE_CAP") and "Wi-Fi 6 (802.11ax)" or info:match("VHT_CAP") and "Wi-Fi 5 (802.11ac)"
                     or info:match("N_CAP") and "Wi-Fi 4 (802.11n)" or "Legacy (802.11a/b/g)"
        w.ssid = (sh("/usr/sbin/wl -i " .. ifn .. " ssid"):match('"(.*)"'))
        d.wifi = w
        d.down, d.up = w.down, w.up
    else
        local tf = tfstats()[mac]
        if tf then d.down, d.up, d.approx = tf.down, tf.up, true end
    end
    return d
end

-- A device's current connections from the conntrack table: the device opened them
-- (it is the original source) or accepted them (original destination, e.g. a port
-- forward). Busiest first, at most 150.
local function connections(form)
    local mac = normmac(form.mac)
    if not mac:match(MAC_PAT) then return false, "-1" end
    local mine = {}
    local f = io.open("/tmp/dhcp.leases")
    if f then
        for line in f:lines() do
            local m, ip = line:match("^%S+%s+(%S+)%s+(%S+)")
            if m and normmac(m) == mac then mine[ip] = true end
        end
        f:close()
    end
    for line in sh("cat /proc/net/arp; ip -6 neigh show"):gmatch("[^\n]+") do
        local ip4, m4 = line:match("^(%d+%.%d+%.%d+%.%d+)%s+%S+%s+%S+%s+(%S+)")
        if ip4 and normmac(m4) == mac then mine[ip4] = true end
        local a6, m6 = line:match("^(%S+) .*lladdr (%S+)")
        if a6 and normmac(m6) == mac then mine[v6full(a6)] = true end
    end
    local list, total = {}, 0
    local cf = io.open("/proc/net/nf_conntrack")
    if cf then
        for line in cf:lines() do
            local fam, proto, tmo, rest = line:match("^(%S+)%s+%d+%s+(%S+)%s+%d+%s+(%d+)%s+(.*)$")
            if fam then
                local state = rest:match("^(%u[%u_]+)%s") or ""
                local v, seen = {}, {}
                for k, val in rest:gmatch("(%a+)=(%S+)") do
                    local n = (seen[k] or 0) + 1; seen[k] = n
                    v[k .. n] = val
                end
                local out, inn = mine[v.src1], mine[v.dst1]
                if out or inn then
                    total = total + 1
                    local c = { p = proto, state = state, tmo = tonumber(tmo), fam = fam }
                    local ob, op = tonumber(v.bytes1) or 0, tonumber(v.packets1) or 0
                    local rb, rp = tonumber(v.bytes2) or 0, tonumber(v.packets2) or 0
                    if out then
                        c.dir = "out"; c.rip, c.rport, c.lport = v.dst1, tonumber(v.dport1), tonumber(v.sport1)
                        c.up, c.down, c.upk, c.downk = ob, rb, op, rp
                    else
                        c.dir = "in"; c.rip, c.rport, c.lport = v.src1, tonumber(v.sport1), tonumber(v.dport1)
                        c.up, c.down, c.upk, c.downk = rb, ob, rp, op
                    end
                    if not v.dport1 and v.type1 then c.rport = nil; c.icmp = tonumber(v.type1) end
                    list[#list + 1] = c
                end
            end
        end
        cf:close()
    end
    table.sort(list, function(a, b) return (a.up + a.down) > (b.up + b.down) end)
    while #list > 150 do table.remove(list) end
    return { t = uptime(), total = total, list = list }
end


-- Change one device: any of name, internet (IoT), reach (IoT -> home, any port),
-- allowed (home -> IoT), fast (guest).
local requester_mac
local function write_device(form)
    if form.forget then
        -- form.forget: one MAC or a comma-separated list (at most 64). ax10.sh checks
        -- and saves the whole batch; names (which Lua owns) go only once that worked.
        local list, me = {}, requester_mac()
        for raw in tostring(form.forget):gmatch("[^,]+") do
            local m = normmac(raw)
            if not m:match(MAC_PAT) then return false, "-1" end
            if m == me then return false, "that's the device you're using" end
            list[#list + 1] = m
        end
        if #list == 0 or #list > 64 then return false, "-1" end
        if os.execute(IOT .. " forget-device " .. table.concat(list, ",") .. " >/dev/null 2>&1") ~= 0 then
            return false, "nothing was changed: that would empty the home allow list while the lock is on"
        end
        local clear = {}
        for _, m in ipairs(list) do clear[m] = "" end
        local named = set_names(clear)
        sync_later()
        if not named then return false, "forgotten, but their names are still saved (" .. BUSY .. ")" end
        return { forgot = #list }
    end
    local mac = normmac(form.mac)
    if not mac:match(MAC_PAT) then return false, "-1" end
    if form.name ~= nil and not set_name(mac, form.name) then return false, BUSY end
    local changed = false
    for field, key in pairs({ internet = "noinet", reach = "lan_open", allowed = "lan_allow", fast = "guest_fast" }) do
        local v = form[field]
        if v == "on" or v == "off" then
            -- noinet lists devices WITHOUT internet, so it is the inverse of the switch.
            local on = (v == "on") ~= (key == "noinet")
            if not set_entry(key, mac, on and "on" or "off") then return false, "-1" end
            changed = true
        end
    end
    if form.pin == "off" then
        -- Through ax10.sh, under the lock autopin runs under, so the watcher can't
        -- save a stale pin list over it. iot_forget keeps it from being re-pinned.
        if os.execute(IOT .. " forget " .. mac .. " >/dev/null 2>&1") ~= 0 then return false, "-1" end
        changed = true
    end
    if form.cap ~= nil then                     -- "down/up" in Mbps, or "" to remove
        local d, u = tostring(form.cap):match("^(%d+)/(%d+)$")
        d, u = tonumber(d), tonumber(u)
        local v
        if form.cap == "" or (d == 0 and u == 0) then v = "off"
        elseif d and u and d <= 1000 and u <= 1000 then v = d .. "/" .. u
        else return false, "-1" end
        if not set_entry("caps", mac, v) then return false, "-1" end
        changed = true
    end
    if changed then sync_later() end
    return { mac = mac:upper() }
end

-- Whole-connection shaping: cap all internet traffic a little under the line speed.
local function read_shaping()
    -- What the automatic limit is doing right now (helpers/autorate.lua), in kbit/s.
    local now = {}
    local f = io.open("/tmp/ax10-iot/autorate.stat")
    if f then for k, v in (f:read("*l") or ""):gmatch("([%a_]+)=(%d+)") do now[k] = tonumber(v) end; f:close() end
    local fresh = now.t and math.abs(os.time() - now.t) < 30
    return { enable = get("wan_shape", "0") == "1" and "on" or "off",
             down = get("wan_down", ""), up = get("wan_up", ""),
             prio = get("prio", "0") == "1" and "on" or "off",
             guest_low = get("guest_low", "0") == "1" and "on" or "off",
             auto = get("wan_auto", "0") == "1" and "on" or "off",
             min_down = get("wan_min_down", ""), max_down = get("wan_max_down", ""),
             min_up = get("wan_min_up", ""), max_up = get("wan_max_up", ""),
             now_down = fresh and now.down or 0, now_up = fresh and now.up or 0,
             now_extra = fresh and now.extra or 0, now_usual = fresh and now.usual or 0,
             now_ceil_down = fresh and now.ceil_down or 0, now_ceil_up = fresh and now.ceil_up or 0 }
end
local function write_shaping(form)
    local d, u = tonumber(form.down), tonumber(form.up)
    if form.enable == "on" and (not d or not u or d < 1 or u < 1 or d > 1000 or u > 1000) then return false, "-1" end
    -- The range for the automatic limit: whole Mbps, or empty for "half to three times
    -- the usual speed". Checked before anything is set: a change set and then left
    -- behind by an early return would be saved by the next commit, ours or ax10.sh's.
    local range = {}
    for _, k in ipairs({ "min_down", "max_down", "min_up", "max_up" }) do
        local v = form[k]
        if v ~= nil then
            local nv = tonumber(v)
            if v == "" then range[k] = ""
            elseif nv and nv >= 1 and nv <= 1000 then range[k] = tostring(math.floor(nv))
            else return false, "-1" end
        end
    end
    if not locked(function()
        local c = uci.cursor()
        c:set("openvpn", SEC, "iot_wan_shape", form.enable == "on" and "1" or "0")
        if form.prio == "on" or form.prio == "off" then c:set("openvpn", SEC, "iot_prio", form.prio == "on" and "1" or "0") end
        if form.guest_low == "on" or form.guest_low == "off" then c:set("openvpn", SEC, "iot_guest_low", form.guest_low == "on" and "1" or "0") end
        if d then c:set("openvpn", SEC, "iot_wan_down", tostring(math.floor(d))) end
        if u then c:set("openvpn", SEC, "iot_wan_up", tostring(math.floor(u))) end
        if form.auto == "on" or form.auto == "off" then c:set("openvpn", SEC, "iot_wan_auto", form.auto == "on" and "1" or "0") end
        for k, v in pairs(range) do
            if v == "" then c:delete("openvpn", SEC, "iot_wan_" .. k) else c:set("openvpn", SEC, "iot_wan_" .. k, v) end
        end
        c:commit("openvpn")
        return true
    end) then return false, BUSY end
    guest_apply()
    return read_shaping()
end

-- Router uptime and the Internet connection (PPPoE shows up as "internet").
local function summary()
    local f, up = io.open("/proc/uptime"), 0
    if f then up = tonumber((f:read("*l") or ""):match("^(%d+)")) or 0; f:close() end
    local wan
    for _, i in ipairs({ "internet", "wan" }) do
        local okj, st = pcall(json.decode, sh("ubus call network.interface." .. i .. " status"))
        if okj and type(st) == "table" and st["ipv4-address"] and st["ipv4-address"][1] then wan = st; break end
    end
    wan = wan or {}
    return { uptime = up, wan_up = wan.up and true or false, wan_uptime = wan.uptime or 0,
             wan_ip = (wan["ipv4-address"] and wan["ipv4-address"][1] and wan["ipv4-address"][1].address) or "",
             proto = wan.proto or "" }
end

-- Let new devices join the locked IoT network for a while (seconds; 0 ends it).
local function write_open(form)
    local s = tonumber(form.seconds) or 600
    s = math.max(0, math.min(math.floor(s), 3600))
    -- recorded before we answer (so open-then-close can't land the other way round); applied in the background
    if os.execute(IOT .. (s > 0 and (" open " .. s) or " close") .. " later >/dev/null 2>&1") ~= 0 then return false, BUSY end
    sync_later()
    return { open_left = s }
end

-- Disconnect one device from the home Wi-Fi now. TP-Link's allow list only turns
-- away new joins, so a device taken off it stays connected until it is kicked.
-- Only interfaces carrying the home network's name; guests and IoT are left alone.
local function kick(mac)
    sh([[home="$(/usr/sbin/wl -i wl0.1 ssid)"; cd /sys/class/net || exit 0
for i in wl[0-9] wl[0-9].[0-9]; do
    [ -d "$i" ] && [ "$(/usr/sbin/wl -i $i ssid)" = "$home" ] && /usr/sbin/wl -i $i deauthenticate ]] .. mac .. [[

done]])
end

-- Our home allow list (ax10.sh home_sync). Every change goes through ax10.sh, which
-- edits the list under its run lock, so it never races the 15 s watcher.
local function home_cmd(args) return os.execute(IOT .. " " .. args .. " >/dev/null 2>&1") == 0 end
-- The MAC of the device making this request, from the neighbour tables (IPv4 or
-- IPv6), so the lock can never shut out whoever is turning it on.
requester_mac = function()   -- forward-declared above write_device
    local ok, addr = pcall(http.getenv, "REMOTE_ADDR")
    local ip = ((ok and addr) or os.getenv("REMOTE_ADDR") or ""):gsub("^::ffff:", "")
    if ip == "" then return nil end
    if ip:match("^%d+%.%d+%.%d+%.%d+$") then
        local f = io.open("/proc/net/arp")
        if f then
            for line in f:lines() do
                local a, flags, m = line:match("^(%S+)%s+%S+%s+(%S+)%s+(%S+)")
                if a == ip and flags ~= "0x0" and normmac(m):match(MAC_PAT) then f:close(); return normmac(m) end
            end
            f:close()
        end
        return nil
    end
    local want = v6full(ip)
    for line in sh("ip -6 neigh show"):gmatch("[^\n]+") do
        local a, m = line:match("^(%S+) .*lladdr (%S+)")
        if a and v6full(a) == want and normmac(m):match(MAC_PAT) then return normmac(m) end
    end
    return nil
end
-- Which allow-list entries are the mesh satellite, so the dashboard can fold them
-- into one line. Display only: this never allows anything. Only evidence a device
-- cannot fake counts: TP-Link's list of paired EasyMesh agents (exact MAC), or being
-- connected to a mesh backhaul radio right now (needs the backhaul key from pairing).
-- Not names, and not "a similar MAC": someone joining during an allow-new-devices
-- window could use either to get folded out of sight.
local function mesh_set()
    local t = {}
    local f = io.open("/tmp/easymesh_firmwareinfo_list")
    if f then
        local s = f:read("*a") or ""; f:close()
        for m in s:gmatch('"mac":"([^"]+)"') do t[normmac(m)] = true end
    end
    local _, atif = presence()
    for m, i in pairs(atif or {}) do if i == "wl0.2" or i == "wl1.2" then t[m] = true end end
    return t
end
local function read_home()
    local seen = {}
    local f = io.open("/tmp/ax10-iot/home_seen")
    if f then
        for line in f:lines() do local m, t = line:match("^(%S+) (%d+)"); if m then seen[m] = tonumber(t) end end
        f:close()
    end
    -- A name for every entry, even devices not around: custom name, lease
    -- hostname, or TP-Link's client history.
    local nm, sc, hosts = names(), stock_clients(), {}
    local lf = io.open("/tmp/dhcp.leases")
    if lf then
        for line in lf:lines() do
            local m, h = line:match("^%S+%s+(%S+)%s+%S+%s+(%S+)")
            if m and h ~= "*" then hosts[normmac(m)] = h end
        end
        lf:close()
    end
    local function name_of(m) return nm[m] or hosts[m] or (sc[m] and sc[m].name ~= "" and sc[m].name) or "" end
    local keep, list = words(get("home_keep", ""):lower()), {}
    local mt = mesh_set()
    for _, m in ipairs(words(get("home_allow", ""):lower())) do
        list[#list + 1] = { mac = m, seen = seen[m], keep = has(keep, m), name = name_of(m), mesh = mt[m] or false }
    end
    for _, m in ipairs(keep) do
        if not has(words(get("home_allow", ""):lower()), m) then
            list[#list + 1] = { mac = m, seen = seen[m], keep = true, name = name_of(m), mesh = mt[m] or false }
        end
    end
    local open_left = 0
    local of = io.open("/tmp/ax10-iot/home_open_until")
    if of then
        local u = tonumber(of:read("*l") or ""); of:close()
        local now = uptime()
        if u and u > now then open_left = u - now end
    end
    local df = io.open("/tmp/ax10-iot/home_drop"); local dropped = df and df:read("*l") or ""; if df then df:close() end
    return { lock = get("home_lock", "0") == "1" and "on" or "off", expire = tonumber(get("home_expire", "0")) or 0,
             open_left = open_left, now = os.time(), list = list, dropped = words(dropped),
             mesh_macs = (function() local r = {}; for m in pairs(mt) do r[#r + 1] = m end; return r end)() }
end
local function write_home(form)
    if form.lock == "on" then
        local me = requester_mac()
        if not me then return false, "can't tell which device this is; open the dashboard over Wi-Fi or a cable on the home network" end
        local cur = read_home()
        local listed = false
        for _, x in ipairs(cur.list) do if x.mac == me and x.keep then listed = true end end
        if not listed and not home_cmd("home-allow keep " .. me) then return false, "couldn't add this device" end
        if not home_cmd("home-set lock 1") then return false, "couldn't turn the lock on" end
    elseif form.lock == "off" then
        if not home_cmd("home-set lock 0") then return false, "couldn't turn the lock off" end
    end
    local e = tonumber(form.expire)
    if e and e >= 0 and e <= 365 and not home_cmd("home-set expire " .. math.floor(e)) then return false, "-1" end
    sync_later()
    return read_home()
end
-- Add, remove or mark one entry ("keep" entries never expire).
local function write_home_allow(form)
    local mac = normmac(form.mac)
    if not mac:match(MAC_PAT) then return false, "-1" end
    local op = form.op
    if op ~= "add" and op ~= "remove" and op ~= "keep" and op ~= "unkeep" then return false, "-1" end
    if op == "remove" and mac == requester_mac() then return false, "that's the device you're using" end
    if form.name and form.name ~= "" and #form.name <= 40 then set_name(mac, form.name) end
    if not home_cmd("home-allow " .. op .. " " .. mac) then
        return false, op == "remove" and "that's the last device on the list; turn the lock off instead" or "-1"
    end
    -- Saved. Off the home radios right away; the rest (firewall for satellite and
    -- wired devices, join page) follows in the background.
    if op == "remove" and get("home_lock", "0") == "1" then kick(mac) end
    sync_later()
    return read_home()
end
local function write_home_open(form)
    local s = tonumber(form.seconds) or 600
    s = math.max(0, math.min(math.floor(s), 3600))
    if os.execute(IOT .. (s > 0 and (" home-open " .. s) or " home-close") .. " later >/dev/null 2>&1") ~= 0 then return false, BUSY end
    sync_later()
    return { open_left = s }
end

-- Local names (ax10.sh dns_sync): <name>.<suffix> for the router and the devices.
local function dns_label(v)
    v = tostring(v or ""):lower():gsub("[%s_%.]", "-"):gsub("[^a-z0-9-]", ""):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
    return v:sub(1, 63)
end
local function valid_ip4(ip)
    local a, b, c, d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return false end
    for _, n in ipairs({ a, b, c, d }) do if tonumber(n) > 255 then return false end end
    return true
end
local function read_names()
    local hosts = {}
    for _, e in ipairs(words(get("dns_hosts", ""))) do
        local n, ip = e:match("^([^=]+)=(.+)$")
        if n then hosts[#hosts + 1] = { name = n, ip = ip } end
    end
    -- DNS over HTTPS: on/off, provider, and how the forwarder is doing (helpers/doh.lua).
    local st = {}
    local sf = io.open("/tmp/ax10-iot/doh.stat")
    if sf then for k, v in (sf:read("*l") or ""):gmatch("(%a+)=(%d+)") do st[k] = tonumber(v) end; sf:close() end
    local okf = io.open("/tmp/ax10-iot/doh.ok"); if okf then okf:close() end
    return { enable = get("dns_on", "0") == "1" and "on" or "off", domain = get("dns_domain", "home"),
             router = get("dns_router", "router"), upstream = get("dns_upstream", "1.1.1.1 1.0.0.1"), hosts = hosts,
             doh = get("dns_doh", "0") == "1" and "on" or "off", provider = get("dns_doh_provider", "cloudflare"),
             doh_ok = okf ~= nil, doh_answered = st.answered or 0, doh_failed = st.failed or 0, doh_ms = st.ms or 0 }
end
-- form.hosts: "name=ip name=ip" (the dashboard builds it). Everything is checked
-- here; ax10.sh checks again before anything reaches dnsmasq.
local function write_names(form)
    local domain = dns_label(form.domain)
    if domain == "" or domain == "local" or #domain > 30 then return false, "the suffix needs letters or digits, and can't be \"local\"" end
    local router = {}
    for _, n in ipairs(words(form.router)) do local l = dns_label(n); if l ~= "" then router[#router + 1] = l end end
    if #router == 0 then return false, "the router needs at least one name" end
    local up = {}
    for _, u in ipairs(words(form.upstream)) do
        if not valid_ip4(u) then return false, "DNS servers are IPv4 addresses, like 1.1.1.1" end
        up[#up + 1] = u
    end
    if #up == 0 or #up > 4 then return false, "give one to four DNS servers" end
    local hosts = {}
    for _, e in ipairs(words(form.hosts)) do
        local n, ip = e:match("^([^=]+)=(.+)$")
        local l = dns_label(n)
        if l == "" or not valid_ip4(ip) then return false, "each custom name needs a name and an IPv4 address" end
        hosts[#hosts + 1] = l .. "=" .. ip
    end
    if #hosts > 64 then return false, "at most 64 custom names" end
    local provider = form.provider
    if provider ~= "google" and provider ~= "quad9" then provider = "cloudflare" end
    if not locked(function()
        local c = uci.cursor()
        local function put(k, v) if v == "" then c:delete("openvpn", SEC, "iot_" .. k) else c:set("openvpn", SEC, "iot_" .. k, v) end end
        put("dns_doh", form.doh == "on" and "1" or "0"); put("dns_doh_provider", provider)
        put("dns_on", form.enable == "on" and "1" or "0")
        put("dns_domain", domain); put("dns_router", table.concat(router, " "))
        put("dns_upstream", table.concat(up, " ")); put("dns_hosts", table.concat(hosts, " "))
        c:commit("openvpn")
        return true
    end) then return false, BUSY end
    sync_later()
    return read_names()
end

-- Data used (ax10.sh usage_sync): totals per day and month, devices for this month.
local function read_usage()
    local days, months, devs = {}, {}, {}
    local month = os.date("%Y-%m")
    local f = io.open("/tmp/ax10-iot/usage")
    if not f then
        -- Not counted yet in this boot (the watcher writes this file): show what was saved.
        local function saved(key, kind, out)
            for _, e in ipairs(words(get(key, ""))) do
                local k, d, u = e:match("^([^=]+)=(%d+)/(%d+)$")
                if k then out[#out + 1] = { [kind] = k, down = tonumber(d) * 1048576, up = tonumber(u) * 1048576 } end
            end
        end
        saved("usage_days", "day", days); saved("usage_months", "month", months)
    end
    if f then
        local nm, sc, hosts = names(), stock_clients(), {}
        local lf = io.open("/tmp/dhcp.leases")
        if lf then
            for line in lf:lines() do
                local m, h = line:match("^%S+%s+(%S+)%s+%S+%s+(%S+)")
                if m and h ~= "*" then hosts[normmac(m)] = h end
            end
            lf:close()
        end
        for line in f:lines() do
            local k, d, u = line:match("^(%S+) (%d+) (%d+)")
            d, u = tonumber(d), tonumber(u)
            if k and d and u then
                local day = k:match("^T:(%d%d%d%d%-%d%d%-%d%d)$")
                local mon = k:match("^M:(%d%d%d%d%-%d%d)$")
                local dm, mac = k:match("^D:(%d%d%d%d%-%d%d):(.+)$")
                if day then days[#days + 1] = { day = day, down = d, up = u }
                elseif mon then months[#months + 1] = { month = mon, down = d, up = u }
                elseif dm == month then
                    devs[#devs + 1] = { mac = mac:upper(), down = d, up = u,
                                        name = nm[mac] or hosts[mac] or (sc[mac] and sc[mac].name ~= "" and sc[mac].name) or "" }
                end
            end
        end
        f:close()
    end
    table.sort(days, function(a, b) return a.day < b.day end)
    table.sort(months, function(a, b) return a.month < b.month end)
    table.sort(devs, function(a, b) return (a.down + a.up) > (b.down + b.up) end)
    return { today = os.date("%Y-%m-%d"), month = month, days = days, months = months, devices = devs }
end

-- Router load (ax10.sh load_guard): the processor over the last 24 hours, in 96
-- quarter-hours (busiest reading and busiest throughput in each), the busiest
-- moment, minutes spent nearly full, and the last "nearly full" note from the log.
local function read_load()
    local up = 0
    local uf = io.open("/proc/uptime")
    if uf then up = math.floor(tonumber((uf:read("*l") or ""):match("^([%d.]+)") or 0) or 0); uf:close() end
    local B, SPAN = 96, 900
    local buckets = {}
    for i = 1, B do buckets[i] = { busy = 0, mbps = 0, n = 0 } end
    local out = { buckets = buckets, cores = 3, full_s = 0 }
    local f = io.open("/tmp/ax10-iot/load.log")
    if not f then return out end
    local last, peak, prev
    for line in f:lines() do
        local t, b, q, l, d, u = line:match("^(%d+) (%d+) (%d+) (%S+) (%d+) (%d+)$")
        t, b, d, u = tonumber(t), tonumber(b), tonumber(d), tonumber(u)
        if t and t <= up and up - t < 86400 then
            local r = { t = t, busy = b, net = tonumber(q), load = tonumber(l) or 0, down = d, up = u }
            last = r
            if not peak or b > peak.busy then peak = r end
            if b >= 90 and prev then out.full_s = out.full_s + math.min(t - prev, 60) end
            prev = t
            local k = B - math.floor((up - t) / SPAN)
            if k >= 1 and k <= B then
                local x = buckets[k]
                if b > x.busy then x.busy = b end
                local m = math.floor((d + u) / 100) / 10      -- Mbps, one decimal
                if m > x.mbps then x.mbps = m end
                x.n = x.n + 1
            end
        end
    end
    f:close()
    local function view(r) return { busy = r.busy, net = r.net, load = r.load, down = r.down, up = r.up, ago = up - r.t } end
    if last then out.now = view(last); out.peak = view(peak) end
    local lf = io.open("/tmp/ax10-iot/iot.log")
    if lf then
        for line in lf:lines() do
            local t, text = line:match("^(%d+)s (router processor .*)$")
            if t and tonumber(t) <= up then out.event = { text = text, ago = up - tonumber(t) } end
        end
        lf:close()
    end
    return out
end

-- Reboot from the dashboard: `ax10.sh reboot` saves the usage log first (it is only
-- saved every 4 hours). In the background, so this answers before the router goes;
-- if ax10.sh can't run (it gave up waiting for the run lock), a plain reboot follows.
local function write_reboot()
    os.execute("(" .. IOT .. " reboot || /sbin/reboot) >/dev/null 2>&1 &")
    return { rebooting = true }
end

local dispatch_tbl = {
    reboot = {
        ["write"] = { cb = write_reboot },
    },
    usage = {
        ["read"]  = { cb = read_usage },
    },
    load = {
        ["read"]  = { cb = read_load },
    },
    names = {
        ["read"]  = { cb = read_names },
        ["write"] = { cb = write_names },
    },
    home = {
        ["read"]  = { cb = read_home },
        ["write"] = { cb = write_home },
    },
    home_allow = {
        ["write"] = { cb = write_home_allow },
    },
    home_open = {
        ["write"] = { cb = write_home_open },
    },
    iot_open = {
        ["write"] = { cb = write_open },
    },
    devices = {
        ["read"]  = { cb = devices },
    },
    device = {
        ["write"] = { cb = write_device },
    },
    summary = {
        ["read"]  = { cb = summary },
    },
    client = {
        ["read"]  = { cb = client },
    },
    connections = {
        ["read"]  = { cb = connections },
    },
    shaping = {
        ["read"]  = { cb = read_shaping },
        ["write"] = { cb = write_shaping },
    },
    settings = {
        ["read"]  = { cb = read_settings },
        ["write"] = { cb = write_settings },
    },
    guest_settings = {
        ["read"]  = { cb = read_guest_settings },
        ["write"] = { cb = write_guest_settings },
    },
}

function dispatch(http_form)
    return ctl.dispatch(dispatch_tbl, http_form)
end

function _index()
    return ctl._index(dispatch)
end

function index()
    entry({"admin", "ax10"}, call("_index")).leaf = true
end
