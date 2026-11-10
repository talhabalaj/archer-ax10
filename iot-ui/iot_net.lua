-- IoT Network page backend for the stock TP-Link web UI (Archer AX10).
-- Installed by `iot.sh ui` into a bind-mounted copy of luci/controller/admin.
-- Follows the stock controllers' pattern: a dispatch table of form -> operation -> cb,
-- run through luci.model.controller, which handles the (encrypted) request framing.
module("luci.controller.admin.iot_net", package.seeall)

local uci  = require "luci.model.uci"
local ctl  = require "luci.model.controller"
local json = require "luci.json"

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
    local prefix = get("ip", "192.168.50.1"):match("^(%d+%.%d+%.%d+)%.")
    local noinet = words(get("noinet", ""))
    local list, seen = {}, {}
    local f = io.open("/tmp/dhcp.leases")
    if f then
        for line in f:lines() do
            local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if ip and prefix and ip:sub(1, #prefix + 1) == prefix .. "." and not seen[mac] then
                seen[mac] = true
                list[#list + 1] = {
                    key = mac, mac = mac:upper(), ip = ip,
                    name = (name ~= "*" and name) or "Unknown",
                    internet = has(noinet, mac) and "off" or "on",
                }
            end
        end
        f:close()
    end
    return list
end

local function update_client(form)
    local new = form.new and json.decode(form.new) or form
    local mac = new and (new.mac or new.key or form.key)
    if not mac or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return false, "-1" end
    mac = mac:lower()
    local out = {}
    for _, m in ipairs(words(get("noinet", ""))) do
        if m:lower() ~= mac then out[#out + 1] = m end
    end
    if new.internet == "off" then out[#out + 1] = mac end
    save({ noinet = table.concat(out, " ") })
    new.key = new.key or mac
    return new
end

------------------------------------------------- home devices allowed to reach IoT
-- Home-network devices (DHCP leases outside the IoT subnet), plus allowlisted MACs
-- that are currently offline so they can still be removed. With lan_mode
-- "selected", only allowlisted MACs may open connections to IoT devices.
local function homes()
    local prefix = get("ip", "192.168.50.1"):match("^(%d+%.%d+%.%d+)%.")
    local allow = words(get("lan_allow", ""))
    local list, seen = {}, {}
    local f = io.open("/tmp/dhcp.leases")
    if f then
        for line in f:lines() do
            local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if ip and not (prefix and ip:sub(1, #prefix + 1) == prefix .. ".") and not seen[mac:lower()] then
                seen[mac:lower()] = true
                list[#list + 1] = {
                    key = mac:lower(), mac = mac:upper(), ip = ip,
                    name = (name ~= "*" and name) or "Unknown",
                    allowed = has(allow, mac) and "on" or "off",
                }
            end
        end
        f:close()
    end
    for _, m in ipairs(allow) do
        if not seen[m:lower()] then
            list[#list + 1] = { key = m:lower(), mac = m:upper(), ip = "---", name = "Offline device", allowed = "on" }
        end
    end
    return list
end

local function update_home(form)
    local new = form.new and json.decode(form.new) or form
    local mac = new and (new.mac or new.key or form.key)
    if not mac or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then return false, "-1" end
    mac = mac:lower()
    local out = {}
    for _, m in ipairs(words(get("lan_allow", ""))) do
        if m:lower() ~= mac then out[#out + 1] = m:lower() end
    end
    if new.allowed == "on" then out[#out + 1] = mac end
    save({ lan_allow = table.concat(out, " ") })
    new.key = mac
    return new
end

local dispatch_tbl = {
    settings = {
        ["read"]  = { cb = read_settings },
        ["write"] = { cb = write_settings },
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
