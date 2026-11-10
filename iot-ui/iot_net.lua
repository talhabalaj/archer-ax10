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
local function presence()
    local at = {}
    for ifn in sh("ls /sys/class/net"):gmatch("%S+") do
        if ifn:match("^wl%d%.%d$") then
            local ssid = sh("/usr/sbin/wl -i " .. ifn .. " ssid"):match('"(.*)"') or ifn
            local band = ifn:match("^wl0") and "5 GHz" or "2.4 GHz"
            for mac in sh("/usr/sbin/wl -i " .. ifn .. " assoclist"):gmatch("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)") do
                at[mac:lower()] = ssid .. " (" .. band .. ")"
            end
        end
    end
    local ports = {}
    for path in sh("ls -d /sys/class/net/br-lan/brif/*"):gmatch("%S+") do
        local n = tonumber(sh("cat " .. path .. "/port_no"), 16)
        if n then ports[n] = path:match("([^/]+)$") end
    end
    for no, mac, islocal in sh("brctl showmacs br-lan"):gmatch("\n%s*(%d+)%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(%a+)") do
        mac = mac:lower()
        local ifn = ports[tonumber(no)] or ""
        if islocal == "no" and not at[mac] then
            if ifn:match("^eth") then at[mac] = "Wired"
            elseif ifn:match("^wds") then at[mac] = "Mesh satellite" end
        end
    end
    for _, flags, mac in sh("cat /proc/net/arp"):gmatch("\n(%S+)%s+%S+%s+(%S+)%s+(%S+)") do
        if flags == "0x2" and not at[mac:lower()] then at[mac:lower()] = "Online" end
    end
    return at
end

-- Rows for one side (IoT subnet or home), named and sorted: the device viewing
-- the page first, then online devices, then offline; alphabetical within.
local function device_rows(want_iot, extra)
    local prefix = get("ip", "192.168.50.1"):match("^(%d+%.%d+%.%d+)%.")
    local ok, addr = pcall(http.getenv, "REMOTE_ADDR")
    local me = ((ok and addr) or os.getenv("REMOTE_ADDR") or ""):gsub("^::ffff:", "")
    local at, nm = presence(), names()
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
local function guest_apply() os.execute(IOT .. " guest >/dev/null 2>&1 &") end

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

local dispatch_tbl = {
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
