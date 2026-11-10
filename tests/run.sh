#!/bin/sh
# One-command gate: syntax checks plus the offline tests. Run from anywhere.
set -e
cd "$(dirname "$0")/.."

echo "== shell syntax"
for f in boot.sh install.sh iot.sh index.sh build-repo.sh deploy-to-pages.sh \
         scripts/signed-hook.sh tests/iot.sh tests/signing.sh tests/run.sh; do
  sh -n "$f"
done

echo "== lua syntax"
LUAC="$(command -v luac5.1 || command -v luac || true)"
if [ -n "$LUAC" ]; then
  "$LUAC" -p iot-ui/iot_net.lua
elif [ -n "$CI" ]; then
  echo "ERROR: no luac found in CI" >&2
  exit 1
else
  echo "SKIP: no luac found"
fi

echo "== js syntax"
for f in iot-ui/iotNetwork/script.js iot-ui/guestSpeed/script.js iot-ui/locale.js; do
  node --check "$f"
done

echo "== tests/iot.sh"
sh tests/iot.sh

echo "== tests/signing.sh"
sh tests/signing.sh

echo "all checks passed"
