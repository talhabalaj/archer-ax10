#!/bin/sh
# IoT -> home rules are read in three places: the firewall (allow_rule, src/), the
# dashboard backend when saving (clean_rules, web/ax10.lua) and the dashboard when
# showing them (parseRule, web/dashboard/js/51-iot.js). They must agree on what is a
# rule. Run: sh tests/rules_parity.sh [lua]
set -e
cd "$(dirname "$0")/.."
LUA="${1:-lua}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# rule  expected (1 = a rule, 0 = rejected)
cat > "$T/fixtures" <<'X'
tcp:8123 1
udp:6001-6010 1
tcp:6001:6010 1
tcp:80-80 1
tcp:65535 1
any 1
any@192.168.50.5 1
any>192.168.0.5 1
tcp:8123@192.168.50.137>192.168.0.20 1
udp:5353@192.168.50.1>192.168.0.2 1
tcp:0 0
tcp:65536 0
udp:10-5 0
icmp:1 0
TCP:80 0
tcp: 0
tcp:80- 0
tcp:8a 0
tcp:1-2-3 0
any:80 0
any@ 0
any> 0
tcp:80> 0
@192.168.50.5 0
>192.168.0.5 0
any>192.168.0.999 0
tcp:80@256.1.1.1 0
tcp:80@01.1.1.1 0
tcp:80>192.168.0.020 0
tcp:80@1.2.3 0
tcp:80>192.168.0.5>192.168.0.6 0
tcp:80@192.168.50.5@192.168.50.6 0
tcp:80>192.168.0.5@192.168.50.5 0
X
# shell: allow_rule and valid_ip4 as built
sh scripts/build.sh >/dev/null
for f in valid_ip4 allow_rule; do sed -n "/^$f() {/,/^}/p" ax10.sh; done > "$T/fw.sh"
# lua: clean_rules
awk '/^local function clean_rules/{p=1} /^local function write_settings/{p=0} p' web/ax10.lua > "$T/cr.lua"
echo 'for l in io.lines(arg[1]) do local w = l:match("^(%S+)"); print(clean_rules(w) and 1 or 0) end' >> "$T/cr.lua"
# js: parseRule and what it needs
awk '/^const IP_RE/{p=1} p{print} p&&/^}/{exit}' web/dashboard/js/51-iot.js > "$T/pr.js"
printf '%s\n' 'require("fs").readFileSync(process.argv[2], "utf8").trim().split(/\r?\n/).forEach(l => console.log(parseRule(l.split(" ")[0]) ? 1 : 0));' >> "$T/pr.js"

"$LUA" "$T/cr.lua" "$T/fixtures" > "$T/lua.out"
node "$T/pr.js" "$T/fixtures" > "$T/js.out"
fails=0; n=0
while read -r w want; do
    n=$((n + 1))
    sh_r=$(sh -c ". '$T/fw.sh'; allow_rule '$w'" >/dev/null 2>&1 && echo 1 || echo 0)
    lua_r=$(sed -n "${n}p" "$T/lua.out"); js_r=$(sed -n "${n}p" "$T/js.out")
    if [ "$sh_r$lua_r$js_r" != "$want$want$want" ]; then
        echo "FAIL: $w  want $want  firewall $sh_r  backend $lua_r  dashboard $js_r"; fails=$((fails + 1))
    fi
done < "$T/fixtures"
[ "$fails" = 0 ] || exit 1
echo "rule parsers agree on $n fixtures"
