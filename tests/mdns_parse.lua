-- Tests mdns.lua's packet reading and what it lets through. The pure part is cut out
-- of the real file, since the rest needs the router's nixio. Run: lua tests/mdns_parse.lua
local src = assert(io.open(arg[1] or "helpers/mdns.lua")):read("*a")
local a = assert(src:find("-- [pure]", 1, true))
local b = assert(src:find("-- [/pure]", 1, true))
local HOST_TTL, MAX_HOSTS = 4500, 64
local chunk = "local HOST_TTL, MAX_HOSTS = " .. HOST_TTL .. ", " .. MAX_HOSTS .. "\n" .. src:sub(a, b - 1) ..
    "\nreturn { parse = parse, key = key, answer_out = answer_out, question_out = question_out, question = question, svc_labels = svc_labels }"
local M = assert((loadstring or load)(chunk))()
local fails = 0
local function check(name, cond) if not cond then fails = fails + 1; print("FAIL: " .. name) end end

-- packet building
local function u16(n) return string.char(math.floor(n / 256), n % 256) end
local function name(n) local t = {}; for l in n:gmatch("[^.]+") do t[#t + 1] = string.char(#l) .. l end; return table.concat(t) .. "\0" end
local function rr(owner, typ, rdata) return owner .. u16(typ) .. u16(1) .. "\0\0\0\120" .. u16(#rdata) .. rdata end
local function msg(flags, qs, an, ar) ar = ar or {}
    return "\0\0" .. u16(flags) .. u16(#qs) .. u16(#an) .. u16(0) .. u16(#ar) .. table.concat(qs) .. table.concat(an) .. table.concat(ar) end
local function q(n, typ) return name(n) .. u16(typ or 12) .. u16(1) end
local function names(m) local t = {}; for _, s in ipairs({ m.an, m.ar }) do for _, r in ipairs(s) do t[#t + 1] = M.key(r.labels) .. "/" .. r.type end end; return table.concat(t, " ") end

local svcs = {}
for _, s in ipairs({ "_airplay._tcp", "_raop._tcp", "_spotify-connect._tcp" }) do svcs[#svcs + 1] = M.svc_labels(s) end
local DOT, CAM, now = "192.168.50.137", "192.168.50.187", 1000
local DOT_B = "\192\168\50\137"

-- an AirPlay announcement: PTR, SRV -> Kitchen-Speaker.local, TXT, A, AAAA
local ann = msg(0x8400, {}, {
    rr(name("_airplay._tcp.local"), 12, name("Kitchen Speaker._airplay._tcp.local")),
    rr(name("Kitchen Speaker._airplay._tcp.local"), 33, u16(0) .. u16(0) .. u16(7000) .. name("Kitchen-Speaker.local")),
    rr(name("Kitchen Speaker._airplay._tcp.local"), 16, "\5a=b c"),
}, {
    rr(name("Kitchen-Speaker.local"), 1, DOT_B),
    rr(name("Kitchen-Speaker.local"), 28, string.rep("\0", 15) .. "\1"),
})
local m = M.parse(ann)
check("announcement parses", m and m.qr and #m.an == 3 and #m.ar == 2)
local hosts = {}
local out = M.answer_out(m, DOT, svcs, hosts, now)
local mo = out and M.parse(out)
check("announcement passes, rebuilt", mo and mo.qr and #mo.an == 3 and #mo.ar == 1)
check("instance name keeps case and spaces", mo and mo.an[1].target[1] == "Kitchen Speaker")
check("own A kept, AAAA dropped", mo and mo.ar[1].type == 1 and mo.ar[1].rd == DOT_B)
check("host learned for that device", hosts["kitchen-speaker.local"] and hosts["kitchen-speaker.local"].ip == DOT)

-- later: just the A record of that host, from that device, with its own address
local function a_only(host, addr, from, t) local o = M.answer_out(M.parse(msg(0x8400, {}, { rr(name(host), 1, addr) })), from, svcs, hosts, t or now + 10); return o end
check("A of learned host passes", a_only("kitchen-speaker.local", DOT_B, DOT))
check("A pointing elsewhere blocked", not a_only("kitchen-speaker.local", "\192\168\0\5", DOT))
check("A of that host from another device blocked", not a_only("kitchen-speaker.local", "\192\168\50\187", CAM))
check("A of an unknown host blocked", not a_only("nas.local", DOT_B, DOT))
check("learned host expires", not a_only("kitchen-speaker.local", DOT_B, DOT, now + HOST_TTL + 1))

-- piggyback: a real PTR plus a forged record for a home device; only the PTR goes
local pig = M.answer_out(M.parse(msg(0x8400, {}, {
    rr(name("_airplay._tcp.local"), 12, name("X._airplay._tcp.local")),
    rr(name("nas.local"), 1, "\192\168\0\9"),
    rr(name("_ipp._tcp.local"), 12, name("Printer._ipp._tcp.local")),
})), CAM, svcs, {}, now)
check("forged records stripped", pig and names(M.parse(pig)) == "_airplay._tcp.local/12")

-- a service's SRV can't claim a name another device holds
local h2 = { ["kitchen-speaker.local"] = { ip = DOT, untl = now + 100 } }
M.answer_out(M.parse(msg(0x8400, {}, { rr(name("Y._raop._tcp.local"), 33, u16(0) .. u16(0) .. u16(5000) .. name("kitchen-speaker.local")) })), CAM, svcs, h2, now)
check("host name not taken over", h2["kitchen-speaker.local"].ip == DOT)

-- the host list is capped
local h3, many = {}, {}
for j = 1, 100 do many[#many + 1] = rr(name("S" .. j .. "._raop._tcp.local"), 33, u16(0) .. u16(0) .. u16(5000) .. name("h" .. j .. ".local")) end
M.answer_out(M.parse(msg(0x8400, {}, many)), CAM, svcs, h3, now)
local n3 = 0; for _ in pairs(h3) do n3 = n3 + 1 end
check("host list capped", n3 == MAX_HOSTS)

-- other services of the same device stay home
check("ESPHome answer blocked", not M.answer_out(M.parse(msg(0x8400, {}, { rr(name("_esphomelib._tcp.local"), 12, name("x._esphomelib._tcp.local")) })), DOT, svcs, {}, now))
check("spotify-connect passes", M.answer_out(M.parse(msg(0x8400, {}, { rr(name("_spotify-connect._tcp.local"), 12, name("Dot._spotify-connect._tcp.local")) })), DOT, svcs, {}, now))
check("lookalike service blocked", not M.answer_out(M.parse(msg(0x8400, {}, { rr(name("_airplayx._tcp.local"), 12, name("y._airplayx._tcp.local")) })), DOT, svcs, {}, now))
check("dot inside a label isn't a service", not M.answer_out(M.parse(msg(0x8400, {}, { rr("\15x._airplay._tcp\5local\0", 12, name("y.local")) })), DOT, svcs, {}, now))
check("a question from IoT isn't an answer", not M.answer_out(M.parse(msg(0, { q("_airplay._tcp.local") }, {})), DOT, svcs, {}, now))

-- compression pointers: read, and written out in full
local p2 = "\0\0" .. u16(0x8400) .. u16(0) .. u16(2) .. u16(0) .. u16(0) ..
    name("_raop._tcp.local") .. u16(12) .. u16(1) .. "\0\0\0\120" .. u16(6) .. "\3abc\192\12" ..
    "\192\12" .. u16(12) .. u16(1) .. "\0\0\0\120" .. u16(2) .. "\192\12"
local m2 = M.parse(p2)
check("compressed names parse", m2 and M.key(m2.an[1].target) == "abc._raop._tcp.local" and M.key(m2.an[2].labels) == "_raop._tcp.local")
local o2 = m2 and M.answer_out(m2, DOT, svcs, {}, now)
check("rebuilt without pointers", o2 and not o2:find("\192", 13, true) and M.key(M.parse(o2).an[1].target) == "abc._raop._tcp.local")
check("compression loop rejected", M.parse("\0\0" .. u16(0x8400) .. u16(1) .. u16(0) .. u16(0) .. u16(0) .. "\192\12" .. u16(12) .. u16(1)) == nil)
check("truncated rejected", M.parse(ann:sub(1, #ann - 3)) == nil)
check("garbage rejected", M.parse("abc") == nil)

-- questions from home: only the wanted ones go, without known answers
local qo = M.question_out(M.parse(msg(0, { q("_airplay._tcp.local"), q("_ipp._tcp.local"), q("kitchen-speaker.local", 1) },
    { rr(name("_airplay._tcp.local"), 12, name("Mine._airplay._tcp.local")) })), svcs, hosts, now + 10)
local qm = qo and M.parse(qo)
check("questions filtered", qm and #qm.qs == 2 and #qm.an == 0 and M.key(qm.qs[2].labels) == "kitchen-speaker.local")
check("question for printers blocked", not M.question_out(M.parse(msg(0, { q("_ipp._tcp.local") }, {})), svcs, hosts, now))
check("an answer from home isn't a question", not M.question_out(M.parse(msg(0x8400, { q("_airplay._tcp.local") }, {})), svcs, {}, now))

-- the router's own question
local mq = M.parse(M.question(svcs))
check("own question parses", mq and not mq.qr and #mq.qs == 3 and M.key(mq.qs[3].labels) == "_spotify-connect._tcp.local")

if fails > 0 then os.exit(1) end
print("mdns.lua packet tests passed")
