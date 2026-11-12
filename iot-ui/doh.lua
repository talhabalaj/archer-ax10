-- doh.lua: a small DNS-over-HTTPS forwarder for the Archer AX10 (started by iot.sh).
--
--   lua doh.lua <port> <server ip> <server name> <ca file> [stat file]
--   lua doh.lua check <port>      exit 0 if the forwarder answers a lookup
--
-- dnsmasq sends its upstream queries to 127.0.0.1:<port> (plain DNS over UDP); each
-- one is POSTed as application/dns-message (RFC 8484) to https://<server ip>/dns-query.
--
-- TLS is done by `openssl s_client` children, not by the router's Lua TLS library:
-- that one (luasec 0.4) cannot check the server's name, and an encrypted connection
-- to whoever answers is not worth much. s_client checks the certificate chain against
-- <ca file> and the name against <server name> (-verify 10, -verify_hostname,
-- -verify_return_error) and gives up if either fails, so nothing is sent to a server
-- that isn't the one asked for. (All three flags are needed; see open().) A few connections are kept open (HTTP/1.1 keep-alive, one request at a
-- time on each); dnsmasq caches answers, so a home needs no more.
local nixio = require "nixio"

local function now() local s, u = nixio.gettimeofday(); return s + u / 1e6 end
local IN = nixio.poll_flags("in")

-- example.com A, and "." NS (keep-alive ping)
local Q_CHECK = "\18\52\1\0\0\1\0\0\0\0\0\0\7example\3com\0\0\1\0\1"
local Q_PING = "\0\0\1\0\0\1\0\0\0\0\0\0\0\0\2\0\1"

if arg[1] == "check" then
    local s = nixio.socket("inet", "dgram")
    s:connect("127.0.0.1", tonumber(arg[2]))
    s:send(Q_CHECK)
    local fds = { { fd = s, events = IN } }
    local n = nixio.poll(fds, 4000)
    local r = n and n > 0 and s:recv(512)
    -- an answer to our question, no error, at least one record
    local ok = r and #r > 12 and r:sub(1, 2) == Q_CHECK:sub(1, 2) and r:byte(4) % 16 == 0 and (r:byte(7) * 256 + r:byte(8)) > 0
    os.exit(ok and 0 or 1)
end

local port, ip, host, ca, statf = tonumber(arg[1]), arg[2], arg[3], arg[4], arg[5]
if not (port and ip and host and ca) then
    io.stderr:write("usage: doh.lua <port> <server ip> <server name> <ca file> [stat file]\n"); os.exit(2)
end

local POOL = 3            -- connections at most
local TIMEOUT = 5         -- seconds for one lookup
local PING = 20           -- keep one idle connection open with a lookup this often
local IDLE = 60           -- close extra idle connections after this

nixio.signal(13, "ign")   -- SIGPIPE: a closed connection is handled where we write
nixio.signal(17, "ign")   -- SIGCHLD: no zombies

local udp = nixio.socket("inet", "dgram")
assert(udp:bind("127.0.0.1", port), "can't listen on 127.0.0.1:" .. port)
udp:setblocking(false)

local conns, queue = {}, {}
local stat = { asked = 0, answered = 0, failed = 0, ms = 0, since = os.time() }

local function open()
    local rin, win = nixio.pipe()       -- we write win -> child's stdin
    local rout, wout = nixio.pipe()     -- child's stdout -> we read rout
    local pid = nixio.fork()
    if pid == 0 then
        nixio.dup(rin, nixio.stdin); nixio.dup(wout, nixio.stdout)
        local null = nixio.open("/dev/null", "w"); if null then nixio.dup(null, nixio.stderr) end
        rin:close(); win:close(); rout:close(); wout:close(); udp:close()
        -- "-verify 10" is what makes a failed check fatal: without it this OpenSSL
        -- (1.0.2) stays in SSL_VERIFY_NONE, reports the error and carries on anyway.
        -- "-no_ign_eof": exit when our end of the pipe closes, so no child outlives us.
        nixio.exec("/usr/bin/openssl", "s_client", "-connect", ip .. ":443", "-servername", host,
                   "-verify", "10", "-verify_hostname", host, "-verify_return_error", "-CAfile", ca,
                   "-quiet", "-no_ign_eof")
        os.exit(1)
    end
    rin:close(); wout:close(); rout:setblocking(false)
    local c = { pid = pid, w = win, r = rout, buf = "", used = now() }
    conns[#conns + 1] = c
    return c
end

local function close(c)
    c.dead = true
    c.w:close(); c.r:close()
    nixio.kill(c.pid, 15)
    for i, x in ipairs(conns) do if x == c then table.remove(conns, i); break end end
end

local function send(c, r)
    local req = "POST /dns-query HTTP/1.1\r\nHost: " .. host .. "\r\nContent-Type: application/dns-message\r\n" ..
                "Accept: application/dns-message\r\nContent-Length: " .. #r.q .. "\r\n\r\n" .. r.q
    if c.w:write(req) ~= #req then return false end
    c.req = r; r.sent = now(); c.used = r.sent
    return true
end

-- One whole HTTP/1.1 response from the front of `buf`, if it is all there:
-- returns status, body, rest of buf, close?   (nil while more is to come, false if
-- it can't be a response). Handles Content-Length and chunked bodies, and skips
-- interim 1xx responses.
local function parse(buf)
    while true do
        local he = buf:find("\r\n\r\n", 1, true)
        if not he then return nil end
        local head = buf:sub(1, he + 1):lower()
        local status = tonumber(head:match("^http/%d%.%d (%d+)"))
        if not status then return false end
        local rest = buf:sub(he + 4)
        if status >= 100 and status < 200 then buf = rest            -- interim: the real one follows
        else
            local close = head:find("\r\nconnection:%s*close") ~= nil
            if head:find("\r\ntransfer%-encoding:[^\r]*chunked") then
                local body, pos = {}, 1
                while true do
                    local le = rest:find("\r\n", pos, true)
                    if not le then return nil end
                    local size = tonumber(rest:sub(pos, le - 1):match("^%s*(%x+)"), 16)
                    if not size then return false end
                    if size == 0 then
                        -- trailers (none expected), then the empty line that ends the message
                        local te = rest:find("\r\n\r\n", le, true)
                        if not te then return nil end
                        return status, table.concat(body), rest:sub(te + 4), close
                    end
                    if #rest < le + 1 + size + 2 then return nil end
                    body[#body + 1] = rest:sub(le + 2, le + 1 + size)
                    pos = le + 2 + size + 2
                end
            end
            local len = tonumber(head:match("\r\ncontent%-length:%s*(%d+)"))
            if not len then return false end                          -- would need "read until close": not DoH
            if #rest < len then return nil end
            return status, rest:sub(1, len), rest:sub(len + 1), close
        end
    end
end
-- Read what has arrived; returns "done", status, body once a whole response is in,
-- "eof" when the connection has gone, nil while more is to come. A response that
-- arrived together with the close is still delivered: the buffer is parsed first.
local function feed(c)
    local eof = false
    while true do
        local d = c.r:read(8192)
        if d == "" then eof = true; break end
        if not d then break end
        c.buf = c.buf .. d
    end
    local status, body, rest, close = parse(c.buf)
    if status then
        c.buf = rest
        if close or eof then c.last = true end
        return "done", status, body
    end
    if status == false or eof then return "eof" end
    return nil
end

local function fail(r) if not r.ping then stat.failed = stat.failed + 1 end end

local function finish(c, status, body)
    local r = c.req; c.req = nil
    if not r then return end
    if status == 200 and body and #body >= 12 then
        if not r.ping then
            udp:sendto(r.q:sub(1, 2) .. body:sub(3), r.h, r.p)      -- the asker's own query id
            stat.answered = stat.answered + 1
            stat.ms = stat.ms * 0.9 + (now() - r.t) * 1000 * 0.1     -- running average
        end
    else fail(r) end
end

local last_stat = 0
local function write_stat()
    if not statf or now() - last_stat < 10 then return end
    last_stat = now()
    local f = io.open(statf .. ".new", "w"); if not f then return end
    f:write(string.format("asked=%d answered=%d failed=%d ms=%d since=%d conns=%d\n", stat.asked, stat.answered, stat.failed, math.floor(stat.ms + 0.5), stat.since, #conns))
    f:close(); os.rename(statf .. ".new", statf)
end

while true do
    local fds = { { fd = udp, events = IN } }
    for _, c in ipairs(conns) do fds[#fds + 1] = { fd = c.r, events = IN, c = c } end
    nixio.poll(fds, 1000)
    local t = now()

    -- new questions from dnsmasq
    while true do
        local q, h, p = udp:recvfrom(4096)
        if not q or q == "" then break end
        if #q >= 12 then stat.asked = stat.asked + 1; queue[#queue + 1] = { q = q, h = h, p = p, t = t } end
    end

    -- answers, closed connections, timeouts
    for i = #conns, 1, -1 do
        local c = conns[i]
        local what, status, body = feed(c)
        if what == "done" then
            finish(c, status, body)
            if c.last then close(c) end
        elseif what == "eof" then
            local r = c.req; close(c)
            -- the server closed an idle connection just as we used it: ask again, once
            if r then if not r.again and not r.ping then r.again = true; table.insert(queue, 1, r) else fail(r) end end
        elseif c.req and t - c.req.sent > TIMEOUT then
            fail(c.req); close(c)
        end
    end

    -- hand queued questions to idle connections, opening more up to POOL
    local i = 1
    while i <= #queue do
        local r = queue[i]
        if t - r.t > TIMEOUT then table.remove(queue, i); fail(r)
        else
            local idle
            for _, c in ipairs(conns) do if not c.req and not c.dead then idle = c; break end end
            if not idle and #conns < POOL then idle = open() end
            if not idle then break end
            table.remove(queue, i)
            if not send(idle, r) then
                close(idle)
                if not r.again then r.again = true; table.insert(queue, i, r) else fail(r) end
            end
        end
    end

    -- keep one connection warm, let the others go
    if #conns == 0 then open() end
    for j = #conns, 1, -1 do
        local c = conns[j]
        if not c.req then
            if j > 1 and t - c.used > IDLE then close(c)
            elseif j == 1 and t - c.used > PING then
                if not send(c, { q = Q_PING, ping = true, t = t }) then close(c) end
            end
        end
    end
    write_stat()
end
