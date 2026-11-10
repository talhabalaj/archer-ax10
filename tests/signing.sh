#!/bin/sh
# Offline test of the signed boot chain: scripts/signed-hook.sh (the flash hook)
# and boot.sh's fetch()/verify_sig(), against a throwaway key and a fake release.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
mkdir -p "$T/rel" "$T/bin"

openssl ecparam -genkey -name prime256v1 -noout -out "$T/key.pem" 2>/dev/null
openssl ec -in "$T/key.pem" -pubout -out "$T/pub.pem" 2>/dev/null
sign() { openssl dgst -sha256 -sign "$T/key.pem" -out "$1.sig" "$1"; }

# uci stub backed by a flat file (key=value per line).
cat > "$T/bin/uci" <<EOF
#!/bin/sh
db="$T/uci.db"; touch "\$db"
[ "\$1" = -q ] && shift
case "\$1" in
  get) v=\$(grep "^\$2=" "\$db" | head -1 | cut -d= -f2-); [ -n "\$v" ] && printf '%s\n' "\$v" || exit 1 ;;
  set) k="\${2%%=*}"; v="\${2#*=}"; grep -v "^\$k=" "\$db" > "\$db.n" || true; printf '%s=%s\n' "\$k" "\$v" >> "\$db.n"; mv "\$db.n" "\$db" ;;
  delete) grep -v "^\$2=" "\$db" > "\$db.n" || true; mv "\$db.n" "\$db" ;;
  commit) : ;;
esac
EOF
chmod +x "$T/bin/uci"
echo 'openvpn.archer_boot.up="old unsigned hook"' > "$T/uci.db"

# 1. install saves key, boot_cmd and a short up line; keeps the old hook.
UCI="$T/bin/uci" COMMIT=/nonexistent sh "$ROOT/scripts/signed-hook.sh" install "$T/pub.pem" >/dev/null
U="$T/bin/uci"
up="$($U get openvpn.archer_boot.up)"
[ ${#up} -lt 200 ] || fail "up line too long for OpenVPN (${#up} chars)"
case "$up" in *boot_cmd*) ;; *) fail "up does not run boot_cmd: $up" ;; esac
[ "$($U get openvpn.archer_boot.up_unsigned)" = '"old unsigned hook"' ] || fail "old hook not kept"
$U get openvpn.archer_boot.sign_pub | openssl base64 -d -A | cmp -s - "$T/pub.pem" || fail "key not saved intact"

# 2. boot_cmd against a fake release: runs a correctly signed boot.sh ...
cmd="$($U get openvpn.archer_boot.boot_cmd)"
cmd="$(printf '%s' "$cmd" | sed -e "s#B=https://[^;]*;#B=file://$T/rel;#" -e "s#/sbin/uci#$U#g" \
       -e "s#/usr/bin/openssl#openssl#g" -e "s#/usr/bin/curl#curl#g" -e "s#/tmp/archer-#$T/run-#g" \
       -e "s#sleep 30#exit 3#")"
printf 'echo RAN > "%s/marker"\n' "$T" > "$T/rel/boot.sh"; sign "$T/rel/boot.sh"
sh -c "$cmd" >/dev/null 2>&1 || true
[ "$(cat "$T/marker" 2>/dev/null)" = RAN ] || fail "signed boot.sh did not run"

# ... and refuses a tampered one (signature from the original).
rm -f "$T/marker"; printf 'echo EVIL > "%s/marker"\n' "$T" > "$T/rel/boot.sh"
set +e; sh -c "$cmd" >/dev/null 2>&1; rc=$?; set -e
[ ! -e "$T/marker" ] || fail "tampered boot.sh ran"
[ $rc = 3 ] || fail "tampered boot.sh did not enter the retry path (rc=$rc)"

# 3. boot.sh fetch(): accepts signed assets, rejects tampered, and allows
#    unverified downloads only when no key is present (old hook).
funcs="$(awk '/^SIGN_PUB=/{p=1} p{print} p&&/^fetch\(\)/{f=1} f&&/^}$/{exit}' "$ROOT/boot.sh")"
printf 'payload\n' > "$T/rel/asset"; sign "$T/rel/asset"
openssl ec -pubin -in "$T/pub.pem" -out "$T/run-sign.pub" 2>/dev/null || cp "$T/pub.pem" "$T/run-sign.pub"
run_fetch() { sh -c "SRC=file://$T/rel; GET='curl -fs'; $funcs
  SIGN_PUB=$1; fetch asset $T/out" >/dev/null 2>&1; }
run_fetch "$T/run-sign.pub" || fail "fetch rejected a signed asset"
printf 'tampered\n' > "$T/rel/asset"
run_fetch "$T/run-sign.pub" && fail "fetch accepted a tampered asset"
[ ! -e "$T/out" ] || fail "tampered asset left on disk"
run_fetch "$T/nokey" || fail "fetch without a key (old hook) should still work"

# 4. revert restores the previous hook.
UCI="$T/bin/uci" COMMIT=/nonexistent sh "$ROOT/scripts/signed-hook.sh" revert >/dev/null
[ "$($U get openvpn.archer_boot.up)" = '"old unsigned hook"' ] || fail "revert did not restore the old hook"
$U get openvpn.archer_boot.sign_pub >/dev/null 2>&1 && fail "revert left the key"

echo "signing tests passed"
