-- IoT Network page backend for the stock TP-Link web UI (Archer AX10).
-- Installed by `iot.sh ui` into a bind-mounted copy of luci/controller/admin.
-- Follows the stock controllers' pattern: a dispatch table of form -> operation -> cb,
-- run through luci.model.controller, which handles the (encrypted) request framing.
module("luci.controller.admin.iot_net", package.seeall)

local uci  = require "luci.model.uci"
local ctl  = require "luci.model.controller"
local json = require "luci.json"
local http = require "luci.http"

local SEC  = "archer_boot"
local IOT  = "/tmp/iot.sh"

local function get(k, d)
    local v = uci.cursor():get("openvpn", SEC, "iot_" .. k)
    if v == nil or v == "" then return d end
    return v
end

local function words(s)
    local t = {}
    for w in (s or ""):gmatch("%S+") do t[#t + 1] = w end
    return t
end

local function has(list, v)
    for _, x in ipairs(list) do if x:lower() == v:lower() then return true end end
    return false
end

-- Save options. TP-Link's cursor:commit also writes the config to flash.
local function save(opts)
    local c = uci.cursor()
    for k, v in pairs(opts) do c:set("openvpn", SEC, "iot_" .. k, v) end
    c:commit("openvpn")
    local on = c:get("openvpn", SEC, "iot_enabled") == "1"
    os.execute(IOT .. (on and " start" or " stop") .. " >/dev/null 2>&1 &")
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

local function set_name(mac, name)
    local t = names()
    name = (name or ""):gsub("[\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    t[mac] = (name ~= "" and #name <= 40) and name or nil
    local list = {}
    for m, n in pairs(t) do list[#list + 1] = m .. "=" .. n end
    local c = uci.cursor()
    if #list > 0 then c:set("openvpn", SEC, "iot_names", list) else c:delete("openvpn", SEC, "iot_names") end
    c:commit("openvpn")
end

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

-- Rows for one side (IoT subnet or home), named and sorted: the device viewing
-- the page first, then online devices, then offline; alphabetical within.
local function device_rows(want_iot, extra)
    local prefix = get("ip", "192.168.50.1"):match("^(%d+%.%d+%.%d+)%.")
    local ok, addr = pcall(http.getenv, "REMOTE_ADDR")
    local me = ((ok and addr) or os.getenv("REMOTE_ADDR") or ""):gsub("^::ffff:", "")
    local at, nm = (presence()), names()
    local rows, seen = {}, {}
    local f = io.open("/tmp/dhcp.leases")
    if f then
        for line in f:lines() do
            local _, mac, ip, host = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            local is_iot = (ip and prefix and ip:sub(1, #prefix + 1) == prefix .. ".") or false
            if ip and is_iot == want_iot and not seen[mac:lower()] then
                mac = mac:lower(); seen[mac] = true
                rows[#rows + 1] = { key = mac, mac = mac:upper(), ip = ip,
                                    name = nm[mac] or ((host ~= "*" and host) or "Unknown"),
                                    status = at[mac] or "Offline", this = (ip == me) }
            end
        end
        f:close()
    end
    for _, m in ipairs(extra or {}) do
        m = m:lower()
        if not seen[m] then
            seen[m] = true
            rows[#rows + 1] = { key = m, mac = m:upper(), ip = "---", name = nm[m] or "Unknown",
                                status = at[m] or "Offline", this = false }
        end
    end
    local function rank(r) return r.this and 0 or (r.status ~= "Offline" and 1 or 2) end
    table.sort(rows, function(a, b)
        if rank(a) ~= rank(b) then return rank(a) < rank(b) end
        return a.name:lower() < b.name:lower()
    end)
    for _, r in ipairs(rows) do
        if r.this then r.name = r.name .. " (this device)" end
        r.this = nil
    end
    return rows
end

-- A row update from the page: save a changed name; return the row's mac.
local function apply_rename(new, old)
    local mac = new and (new.mac or new.key)
    if type(mac) ~= "string" or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return nil end
    mac = mac:lower()
    local nn = (new.name or ""):gsub(" %(this device%)$", "")
    local on = ((old and old.name) or ""):gsub(" %(this device%)$", "")
    if new.name and nn ~= on then set_name(mac, (nn ~= "Unknown") and nn or "") end
    return mac
end

local function decode_row(form)
    local new = form.new and json.decode(form.new) or form
    local old = (form.old and form.old ~= "add") and json.decode(form.old) or nil
    return new, old
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
    }
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
    if form.allow_lan ~= nil then opts.allow_lan = form.allow_lan end
    if form.lan_mode == "all" or form.lan_mode == "selected" then opts.lan_mode = form.lan_mode end
    save(opts)
    return read_settings()
end

----------------------------------------------------------------- clients form
local function clients()
    local noinet = words(get("noinet", ""))
    local rows = device_rows(true)
    for _, r in ipairs(rows) do r.internet = has(noinet, r.mac) and "off" or "on" end
    return rows
end

local function update_client(form)
    local new, old = decode_row(form)
    local mac = apply_rename(new, old)
    if not mac then return false, "-1" end
    if not old or new.internet ~= old.internet then
        local out = {}
        for _, m in ipairs(words(get("noinet", ""))) do
            if m:lower() ~= mac then out[#out + 1] = m end
        end
        if new.internet == "off" then out[#out + 1] = mac end
        save({ noinet = table.concat(out, " ") })
    end
    new.key = mac
    return new
end

------------------------------------------------- home devices allowed to reach IoT
-- Home-network devices (DHCP leases outside the IoT subnet), plus allowlisted MACs
-- that are currently offline so they can still be removed. With lan_mode
-- "selected", only allowlisted MACs may open connections to IoT devices.
local function homes()
    local allow = words(get("lan_allow", ""))
    local rows = device_rows(false, allow)
    for _, r in ipairs(rows) do r.allowed = has(allow, r.mac) and "on" or "off" end
    return rows
end

local function update_home(form)
    local new, old = decode_row(form)
    local mac = apply_rename(new, old)
    if not mac then return false, "-1" end
    if not old or new.allowed ~= old.allowed then
        local out = {}
        for _, m in ipairs(words(get("lan_allow", ""))) do
            if m:lower() ~= mac then out[#out + 1] = m:lower() end
        end
        if new.allowed == "on" then out[#out + 1] = mac end
        save({ lan_allow = table.concat(out, " ") })
    end
    new.key = mac
    return new
end

------------------------------------------------------------ guest speed limit
-- Settings live next to the IoT ones (iot_guest_*); iot.sh's watcher applies them.
local function guest_apply() os.execute(IOT .. " shape >/dev/null 2>&1 &") end

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
    local c = uci.cursor()
    c:set("openvpn", SEC, "iot_guest_limit", form.enable == "on" and "1" or "0")
    if d then c:set("openvpn", SEC, "iot_guest_down", tostring(math.floor(d))) end
    if u then c:set("openvpn", SEC, "iot_guest_up", tostring(math.floor(u))) end
    c:commit("openvpn")
    guest_apply()
    return read_guest_settings()
end

-- Devices connected to TP-Link's guest networks, plus full-speed guests that are
-- offline so they can still be downgraded.
local function guests()
    local fast = words(get("guest_fast", ""))
    local ifs = {}
    local c = uci.cursor()
    c:foreach("wireless", "wifi-iface", function(sct)
        if sct.guest == "on" and sct.ifname then ifs[#ifs + 1] = sct.ifname end
    end)
    local on_guest = {}
    for _, i in ipairs(ifs) do
        for mac in sh("/usr/sbin/wl -i " .. i .. " assoclist"):gmatch("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do
            on_guest[mac:lower()] = true
        end
    end
    local rows = {}
    for _, r in ipairs(device_rows(false, fast)) do
        if on_guest[r.key] or has(fast, r.mac) then
            r.fast = has(fast, r.mac) and "on" or "off"
            rows[#rows + 1] = r
        end
    end
    return rows
end

local function update_guest(form)
    local new, old = decode_row(form)
    local mac = apply_rename(new, old)
    if not mac then return false, "-1" end
    if not old or new.fast ~= old.fast then
        local out = {}
        for _, m in ipairs(words(get("guest_fast", ""))) do
            if m:lower() ~= mac then out[#out + 1] = m:lower() end
        end
        if new.fast == "on" then out[#out + 1] = mac end
        local c = uci.cursor()
        c:set("openvpn", SEC, "iot_guest_fast", table.concat(out, " "))
        c:commit("openvpn")
        guest_apply()
    end
    new.key = mac
    return new
end

---------------------------------------------------------------- dashboard
-- The dashboard at / (iot-ui/dash) asks for everything in one call.
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
local function caps_save(t)
    local out = {}
    for m, c in pairs(t) do out[#out + 1] = m .. "=" .. c.down .. "/" .. c.up end
    table.sort(out)
    local c = uci.cursor()
    if #out > 0 then c:set("openvpn", SEC, "iot_caps", table.concat(out, " ")) else c:delete("openvpn", SEC, "iot_caps") end
    c:commit("openvpn")
    guest_apply()
end

-- Every device in the DHCP leases (MACs seen only on the air or in ARP are the mesh
-- satellite's own radios, not clients), plus offline devices that still have a setting
-- (blocked, full speed, allowed to reach IoT, Internet off) so it can be undone.
local function devices()
    local at, atif, st, t = presence()
    local tf = tfstats()
    local nm, gif = names(), guest_ifaces()
    local blocked, ac_enable, ac_mode = blocklist()
    local noinet, fast, allow = words(get("noinet", "")), words(get("guest_fast", "")), words(get("lan_allow", ""))
    local cp = caps()
    local prefix = get("ip", "192.168.50.1"):match("^(%d+%.%d+%.%d+)%.")
    local ok, addr = pcall(http.getenv, "REMOTE_ADDR")
    local me = ((ok and addr) or os.getenv("REMOTE_ADDR") or ""):gsub("^::ffff:", "")
    local rows, seen = {}, {}
    local function add(mac, ip, host)
        mac = normmac(mac)
        if seen[mac] or not mac:match(MAC_PAT) then return end
        seen[mac] = true
        local iot = (ip and prefix and ip:sub(1, #prefix + 1) == prefix .. ".") or false
        local net = iot and "iot" or (gif[atif[mac] or ""] and "guest") or "home"
        rows[#rows + 1] = {
            mac = mac:upper(), ip = ip or "", host = (host ~= "*" and host) or "",
            name = nm[mac] or "", where = at[mac] or "", online = at[mac] and true or false,
            net = net, this = (ip ~= nil and ip == me), blocked = blocked[mac] or false,
            internet = not has(noinet, mac), fast = has(fast, mac), allowed = has(allow, mac),
            cap = cp[mac] or false,
        }
        local r, x = rows[#rows], st[mac]
        if x then r.down, r.up, r.rssi, r.rate, r.conn = x.down, x.up, x.rssi, x.rate, x.conn
        elseif tf[mac] then r.down, r.up, r.approx = tf[mac].down, tf[mac].up, true end
    end
    local f = io.open("/tmp/dhcp.leases")
    if f then
        for line in f:lines() do
            local _, mac, ip, host = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if mac then add(mac, ip, host) end
        end
        f:close()
    end
    for _, l in ipairs({ noinet, fast, allow }) do for _, m in ipairs(l) do add(m, nil, nil) end end
    for m in pairs(blocked) do add(m, nil, nil) end
    for m in pairs(cp) do add(m, nil, nil) end
    return { list = rows, t = t, lan_mode = get("lan_mode", "all"), iot_enabled = get("enabled", "0") == "1",
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

-- Remove or add one mac in a space-separated list setting.
local function list_with(key, mac, on)
    local out = {}
    for _, m in ipairs(words(get(key, ""))) do
        if normmac(m) ~= mac then out[#out + 1] = normmac(m) end
    end
    if on then out[#out + 1] = mac end
    return table.concat(out, " ")
end

-- Change one device: any of name, internet (IoT), allowed (home -> IoT), fast (guest).
local function write_device(form)
    local mac = normmac(form.mac)
    if not mac:match(MAC_PAT) then return false, "-1" end
    if form.name ~= nil then set_name(mac, form.name) end
    local opts = {}
    if form.internet == "on" or form.internet == "off" then opts.noinet = list_with("noinet", mac, form.internet == "off") end
    if form.allowed == "on" or form.allowed == "off" then opts.lan_allow = list_with("lan_allow", mac, form.allowed == "on") end
    if next(opts) then save(opts) end
    if form.cap ~= nil then                     -- "down/up" in Mbps, or "" to remove
        local t = caps()
        local d, u = tostring(form.cap):match("^(%d+)/(%d+)$")
        d, u = tonumber(d), tonumber(u)
        if form.cap == "" or (d == 0 and u == 0) then t[mac] = nil
        elseif d and u and d <= 1000 and u <= 1000 then t[mac] = { down = d, up = u }
        else return false, "-1" end
        caps_save(t)
    end
    if form.fast == "on" or form.fast == "off" then
        local c = uci.cursor()
        c:set("openvpn", SEC, "iot_guest_fast", list_with("guest_fast", mac, form.fast == "on"))
        c:commit("openvpn")
        guest_apply()
    end
    return { mac = mac:upper() }
end

-- Whole-connection shaping: cap all internet traffic a little under the line speed.
local function read_shaping()
    return { enable = get("wan_shape", "0") == "1" and "on" or "off",
             down = get("wan_down", ""), up = get("wan_up", ""),
             prio = get("prio", "0") == "1" and "on" or "off",
             guest_low = get("guest_low", "0") == "1" and "on" or "off" }
end
local function write_shaping(form)
    local d, u = tonumber(form.down), tonumber(form.up)
    if form.enable == "on" and (not d or not u or d < 1 or u < 1 or d > 1000 or u > 1000) then return false, "-1" end
    local c = uci.cursor()
    c:set("openvpn", SEC, "iot_wan_shape", form.enable == "on" and "1" or "0")
    if form.prio == "on" or form.prio == "off" then c:set("openvpn", SEC, "iot_prio", form.prio == "on" and "1" or "0") end
    if form.guest_low == "on" or form.guest_low == "off" then c:set("openvpn", SEC, "iot_guest_low", form.guest_low == "on" and "1" or "0") end
    if d then c:set("openvpn", SEC, "iot_wan_down", tostring(math.floor(d))) end
    if u then c:set("openvpn", SEC, "iot_wan_up", tostring(math.floor(u))) end
    c:commit("openvpn")
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

local dispatch_tbl = {
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
    guests = {
        ["load"]   = { cb = guests },
        ["read"]   = { cb = guests },
        ["update"] = { cb = update_guest },
    },
    homes = {
        ["load"]   = { cb = homes },
        ["read"]   = { cb = homes },
        ["update"] = { cb = update_home },
    },
    clients = {
        ["load"]   = { cb = clients },
        ["read"]   = { cb = clients },
        ["update"] = { cb = update_client },
    },
}

function dispatch(http_form)
    return ctl.dispatch(dispatch_tbl, http_form)
end

function _index()
    return ctl._index(dispatch)
end

function index()
    entry({"admin", "iot_net"}, call("_index")).leaf = true
end
