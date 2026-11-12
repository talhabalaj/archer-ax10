#!/bin/sh
# One-command gate: syntax checks plus the offline tests. Run from anywhere.
set -e
cd "$(dirname "$0")/.."

echo "== shell syntax"
for f in boot.sh install.sh iot.sh index.sh build-repo.sh deploy-to-pages.sh \
         scripts/signed-hook.sh scripts/ci-install-lua.sh tests/iot.sh tests/signing.sh tests/run.sh; do
  sh -n "$f"
done

echo "== lua: no local named like a LuCI dispatcher function"
# index() is cached with string.dump, which drops upvalues: a file-level local called
# entry/call/node/alias makes index() call nil and every page of the router's web
# UI, the stock login included, answer 500.
if grep -nE '^[[:space:]]*local[[:space:]]+(function[[:space:]]+)?(entry|call|node|alias|assign)\b' iot-ui/iot_net.lua; then
  echo "ERROR: iot_net.lua shadows a LuCI dispatcher function" >&2; exit 1
fi
echo "== lua syntax"
LUAC="$(command -v luac5.1 || command -v luac || true)"
if [ -n "$LUAC" ]; then
  "$LUAC" -p iot-ui/iot_net.lua
  "$LUAC" -p iot-ui/doh.lua
  "$LUAC" -p iot-ui/autorate.lua
elif [ -n "$CI" ]; then
  echo "ERROR: no luac found in CI" >&2
  exit 1
else
  echo "SKIP: no luac found"
fi

echo "== doh.lua HTTP parser"
LUA_BIN="$(command -v lua5.1 || command -v lua || true)"
if [ -n "$LUA_BIN" ]; then "$LUA_BIN" tests/doh_parse.lua iot-ui/doh.lua
elif [ -n "$CI" ]; then echo "ERROR: no lua found in CI" >&2; exit 1
else echo "SKIP: no lua found"; fi

echo "== js syntax"
for f in iot-ui/iotNetwork/script.js iot-ui/guestSpeed/script.js iot-ui/locale.js; do
  node --check "$f"
done
# The dashboard is one HTML file; check its inline script.
node -e '
const src = require("fs").readFileSync(process.argv[1], "utf8");
const code = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]).join("\n");
if (!code) { console.error("no inline script in " + process.argv[1]); process.exit(1); }
new (require("vm").Script)(code, { filename: process.argv[1] });
' iot-ui/dash/index.html

echo "== tests/iot.sh"
sh tests/iot.sh

echo "== tests/signing.sh"
sh tests/signing.sh

echo "all checks passed"
