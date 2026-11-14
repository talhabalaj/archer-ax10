-- Tests mqtt.lua's packet building and queue reading. The pure part is cut out of the
-- real file (the rest needs the router's nixio). Run: lua tests/mqtt_packets.lua
local src = assert(io.open(arg[1] or "helpers/mqtt.lua")):read("*a")
local a = assert(src:find("-- [pure]", 1, true))
local b = assert(src:find("-- [/pure]", 1, true))
local M = assert((loadstring or load)(src:sub(a, b - 1) ..
    "\nreturn { remlen = remlen, connect = connect, publish = publish, parse_line = parse_line, DISCONNECT = DISCONNECT }"))()
local fails = 0
local function check(name, cond) if not cond then fails = fails + 1; print("FAIL: " .. name) end end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- Remaining length, from the MQTT 3.1.1 spec's table (2.2.3).
check("remlen 0", hex(M.remlen(0)) == "00")
check("remlen 127", hex(M.remlen(127)) == "7f")
check("remlen 128", hex(M.remlen(128)) == "8001")
check("remlen 16383", hex(M.remlen(16383)) == "ff7f")
check("remlen 16384", hex(M.remlen(16384)) == "808001")
check("remlen 2097152", hex(M.remlen(2097152)) == "80808001")

-- CONNECT: protocol "MQTT" level 4, clean session, user and password flags, keepalive.
local c = M.connect("ax10-router", "ax10", "pw", 30)
check("connect header", c:byte(1) == 0x10 and c:byte(2) == #c - 2)
check("connect protocol", c:sub(3, 9) == "\0\4MQTT\4")
check("connect flags: user, password, clean", c:byte(10) == 0xc2)
check("connect keepalive", c:sub(11, 12) == "\0\30")
check("connect payload", c:sub(13) == "\0\11ax10-router\0\4ax10\0\2pw")
local anon = M.connect("x", nil, "", 30)
check("anonymous: only clean session", anon:byte(10) == 0x02 and anon:sub(13) == "\0\1x")

-- PUBLISH at QoS 0, retained or not; a payload long enough for two length bytes.
local p = M.publish("ax10/internet", "ON", true)
check("publish retained", hex(p) == "3111" .. hex("\0\13ax10/internet") .. hex("ON"))
check("publish not retained", M.publish("t", "x", false):byte(1) == 0x30)
local big = M.publish("ax10/event", string.rep("x", 300), false)
check("publish long payload length", big:sub(2, 3) == M.remlen(2 + 10 + 300) and #big == 3 + 312)
check("disconnect", M.DISCONNECT == "\224\0")

-- Queue lines.
local t, pl, r = M.parse_line("1\tax10/internet\tON")
check("queue line retained", t == "ax10/internet" and pl == "ON" and r == true)
t, pl, r = M.parse_line('0\tax10/event\t{"a":"b\tc"}')
check("payload may hold a tab", t == "ax10/event" and pl == '{"a":"b\tc"}' and r == false)
check("no topic wildcards", M.parse_line("0\tax10/#\tx") == nil and M.parse_line("0\tax10/+/a\tx") == nil)
check("no empty topic", M.parse_line("0\t\tx") == nil)
check("not a queue line", M.parse_line("hello") == nil and M.parse_line("2\tt\tx") == nil)

if fails > 0 then os.exit(1) end
print("mqtt.lua packet tests passed")
