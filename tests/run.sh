#!/bin/sh
# One-command gate: syntax checks plus the offline tests. Run from anywhere.
set -e
cd "$(dirname "$0")/.."

echo "== build ax10.sh from src/"
sh scripts/build.sh
[ -x ax10.sh ] || { echo "ERROR: the built ax10.sh is not executable" >&2; exit 1; }

echo "== shell syntax"
for f in boot.sh install.sh ax10.sh src/*.sh index.sh \
         scripts/build.sh scripts/signed-hook.sh scripts/ci-install-lua.sh tests/ax10.sh tests/signing.sh tests/run.sh; do
  sh -n "$f"
done

echo "== lua: no local named like a LuCI dispatcher function"
# index() is cached with string.dump, which drops upvalues: a file-level local called
# entry/call/node/alias makes index() call nil and every page of the router's web
# UI, the stock login included, answer 500.
if grep -nE '^[[:space:]]*local[[:space:]]+(function[[:space:]]+)?(entry|call|node|alias|assign)\b' web/ax10.lua; then
  echo "ERROR: web/ax10.lua shadows a LuCI dispatcher function" >&2; exit 1
fi
echo "== lua syntax"
LUAC="$(command -v luac5.1 || command -v luac || true)"
if [ -n "$LUAC" ]; then
  "$LUAC" -p web/ax10.lua
  "$LUAC" -p helpers/doh.lua
  "$LUAC" -p helpers/autorate.lua
  "$LUAC" -p helpers/mdns.lua
  "$LUAC" -p helpers/mqtt.lua
elif [ -n "$CI" ]; then
  echo "ERROR: no luac found in CI" >&2
  exit 1
else
  echo "SKIP: no luac found"
fi

echo "== doh.lua HTTP parser"
LUA_BIN="$(command -v lua5.1 || command -v lua || true)"
if [ -n "$LUA_BIN" ]; then "$LUA_BIN" tests/doh_parse.lua helpers/doh.lua
elif [ -n "$CI" ]; then echo "ERROR: no lua found in CI" >&2; exit 1
else echo "SKIP: no lua found"; fi

echo "== mdns.lua packets"
if [ -n "$LUA_BIN" ]; then "$LUA_BIN" tests/mdns_parse.lua helpers/mdns.lua
elif [ -n "$CI" ]; then echo "ERROR: no lua found in CI" >&2; exit 1
else echo "SKIP: no lua found"; fi

echo "== mqtt.lua packets"
if [ -n "$LUA_BIN" ]; then "$LUA_BIN" tests/mqtt_packets.lua helpers/mqtt.lua
elif [ -n "$CI" ]; then echo "ERROR: no lua found in CI" >&2; exit 1
else echo "SKIP: no lua found"; fi

echo "== alerts: device names made safe for JSON"
sh tests/mq_clean.sh

echo "== dashboard backend: which network a device is on"
if [ -n "$LUA_BIN" ]; then "$LUA_BIN" tests/device_net.lua web/ax10.lua
elif [ -n "$CI" ]; then echo "ERROR: no lua found in CI" >&2; exit 1
else echo "SKIP: no lua found"; fi

echo "== IoT -> home rules: the three parsers agree"
if [ -n "$LUA_BIN" ]; then sh tests/rules_parity.sh "$LUA_BIN"
elif [ -n "$CI" ]; then echo "ERROR: no lua found in CI" >&2; exit 1
else echo "SKIP: no lua found"; fi

echo "== js syntax"
# The dashboard's script, as built (its js/*.js joined in order): one program, so a
# name declared twice across the files shows up here.
node -e '
const src = require("fs").readFileSync(process.argv[1], "utf8");
const code = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]).join("\n");
if (!code) { console.error("no inline script in " + process.argv[1]); process.exit(1); }
new (require("vm").Script)(code, { filename: process.argv[1] });
' build/ax10-files/web/dashboard.html

echo "== tests/ax10.sh"
sh tests/ax10.sh

echo "== tests/signing.sh"
sh tests/signing.sh

echo "all checks passed"
