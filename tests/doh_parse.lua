-- Tests doh.lua's HTTP response framing. The function is cut out of the real file,
-- since the rest of it needs the router's nixio. Run: lua tests/doh_parse.lua
local src = assert(io.open(arg[1] or "helpers/doh.lua")):read("*a")
local a = assert(src:find("local function parse(buf)", 1, true))
local b = assert(src:find("-- Read what has arrived", 1, true))
local parse = assert((loadstring or load)(src:sub(a, b - 1) .. "\nreturn parse"))()
local fails = 0
local function check(name, cond) if not cond then fails = fails + 1; print("FAIL: " .. name) end end
local H = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n"

local s, body, rest, close = parse(H .. "Content-Length: 5\r\n\r\nhelloNEXT")
check("content-length body", s == 200 and body == "hello" and rest == "NEXT" and close == false)
check("mixed-case header", select(2, parse("HTTP/1.1 200 OK\r\ncOnTeNt-LeNgTh: 2\r\n\r\nhi")) == "hi")
check("partial headers", parse("HTTP/1.1 200 OK\r\nContent-Le") == nil)
check("partial body", parse(H .. "Content-Length: 9\r\n\r\nhell") == nil)
s, body, rest, close = parse(H .. "Connection: close\r\nContent-Length: 2\r\n\r\nok")
check("connection: close", s == 200 and body == "ok" and close == true)
s, body, rest = parse("HTTP/1.1 100 Continue\r\n\r\n" .. H .. "Content-Length: 3\r\n\r\nabcX")
check("interim 100 skipped", s == 200 and body == "abc" and rest == "X")
check("interim alone waits", parse("HTTP/1.1 100 Continue\r\n\r\n") == nil)
s, body, rest = parse(H .. "Transfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;ext=1\r\nde\r\n0\r\n\r\nTAIL")
check("chunked", s == 200 and body == "abcde" and rest == "TAIL")
check("chunked, last chunk missing", parse(H .. "Transfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n") == nil)
check("chunked, data short", parse(H .. "Transfer-Encoding: chunked\r\n\r\n5\r\nab") == nil)
s, body = parse("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
check("error status", s == 403 and body == "")
check("no framing", parse("HTTP/1.1 200 OK\r\nServer: x\r\n\r\nstuff") == false)
check("not HTTP", parse("garbage\r\n\r\n") == false)
if fails > 0 then os.exit(1) end
print("doh.lua parser tests passed")
