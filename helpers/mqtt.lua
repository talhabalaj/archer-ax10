-- mqtt.lua: send queued messages to an MQTT broker, then disconnect.
-- MQTT 3.1.1, QoS 0, one connection per run: the router has a handful of alerts a
-- day, so it doesn't stay connected. The user name and password come in the
-- environment (MQTT_USER, MQTT_PASS), not on the command line.
--
-- lua mqtt.lua <host> <port> <client id> <queue file>
-- Queue lines: "<retain 0|1><TAB><topic><TAB><payload>". Exit 0 once every line was
-- sent; otherwise non-zero, with the reason on stderr, and the caller keeps the queue.
-- Started by ax10.sh (alerts_flush).

local TIMEOUT = 4

-- [pure] ------------------------------------------------------------ packets
local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function str(s) return u16(#s) .. s end
-- MQTT's "remaining length": 7 bits a byte, low first, high bit = more follows.
local function remlen(n)
    local out = {}
    repeat
        local d = n % 128
        n = math.floor(n / 128)
        if n > 0 then d = d + 128 end
        out[#out + 1] = string.char(d)
    until n == 0
    return table.concat(out)
end
local function packet(first, body) return string.char(first) .. remlen(#body) .. body end
local function connect(id, user, pass, keepalive)
    local flags = 2                                    -- clean session
    if user and user ~= "" then flags = flags + 128 end
    if pass and pass ~= "" then flags = flags + 64 end
    local body = str("MQTT") .. string.char(4, flags) .. u16(keepalive or 30) .. str(id)
    if user and user ~= "" then body = body .. str(user) end
    if pass and pass ~= "" then body = body .. str(pass) end
    return packet(0x10, body)
end
local function publish(topic, payload, retain) return packet(0x30 + (retain and 1 or 0), str(topic) .. payload) end
local DISCONNECT = "\224\0"
-- A queue line: topic, payload, retain; nil if it isn't one (a topic to publish to
-- may not hold the wildcards + and #, or be empty).
local function parse_line(l)
    local r, t, p = l:match("^([01])\t([^\t]+)\t(.*)$")
    if r and not t:find("[#+%z]") and #t < 65536 and #p < 200000 then return t, p, r == "1" end
end
local REFUSED = { "unacceptable protocol version", "client id rejected", "server unavailable",
                  "bad user name or password", "not authorized" }
-- [/pure] ---------------------------------------------------------------------

local host, port, id, qfile = arg[1], tonumber(arg[2] or ""), arg[3], arg[4]
if not (host and port and id and qfile) then
    io.stderr:write("usage: mqtt.lua <host> <port> <client id> <queue file>\n"); os.exit(2)
end
local msgs = {}
for l in io.lines(qfile) do
    local t, p, r = parse_line(l)
    if t then msgs[#msgs + 1] = publish(t, p, r) end
end
if #msgs == 0 then os.exit(0) end

local nixio = require "nixio"
local function die(why) io.stderr:write(why .. "\n"); os.exit(1) end
local s = nixio.socket("inet", "stream") or die("no socket")
-- Connect without blocking, so a broker that is down costs TIMEOUT seconds, not the
-- kernel's minutes of retries.
s:setblocking(false)
local ok, code = s:connect(host, port)
if not ok and code ~= 115 then die("can't connect to " .. host .. ":" .. port .. " (" .. tostring(code) .. ")") end
if not ok then
    local fds = { { fd = s, events = nixio.poll_flags("out") } }
    local n = nixio.poll(fds, TIMEOUT * 1000)      -- 0 (a true value in Lua) on timeout
    if not n or n < 1 then die("no answer from " .. host .. ":" .. port) end
    local err = s:getopt("socket", "error")
    if err ~= 0 then die("can't connect to " .. host .. ":" .. port .. " (" .. tostring(err) .. ")") end
end
s:setblocking(true)
s:setopt("socket", "rcvtimeo", TIMEOUT)
s:setopt("socket", "sndtimeo", TIMEOUT)
local function send(data)
    local i = 1
    while i <= #data do
        local n = s:send(data:sub(i))
        if not n or n <= 0 then die("connection lost while sending") end
        i = i + n
    end
end

send(connect(id, os.getenv("MQTT_USER"), os.getenv("MQTT_PASS"), 30))
-- CONNACK is 4 bytes, which TCP may deliver in pieces; each read waits TIMEOUT at most.
local ack = ""
while #ack < 4 do
    local part = s:recv(4 - #ack)
    if not part or part == "" then break end
    ack = ack .. part
end
if #ack < 4 or ack:byte(1) ~= 0x20 or ack:byte(2) ~= 2 then die("the broker didn't accept the connection") end
if ack:byte(4) ~= 0 then die("the broker refused: " .. (REFUSED[ack:byte(4)] or ("code " .. ack:byte(4)))) end
for _, m in ipairs(msgs) do send(m) end
send(DISCONNECT)
s:close()
