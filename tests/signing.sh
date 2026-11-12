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
  add_list) k="\${2%%=*}"; v="\${2#*=}"; o=\$(grep "^\$k=" "\$db" | head -1 | cut -d= -f2-); grep -v "^\$k=" "\$db" > "\$db.n" || true
            printf '%s=%s\n' "\$k" "\${o:+\$o }\$v" >> "\$db.n"; mv "\$db.n" "\$db" ;;
  revert) exit 1 ;;
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

# 3b. install.sh fetch(): same rules for the binaries install.sh runs as root.
ifuncs="$(awk '/^SIGN_PUB=/{p=1} p{print} p&&/^fetch\(\)/{f=1} f&&/^}$/{exit}' "$ROOT/install.sh")"
[ -n "$ifuncs" ] || fail "install.sh has no SIGN_PUB/fetch block"
run_ifetch() { sh -c "SRC=file://$T/rel; GET='curl -fsS'; $ifuncs
  SIGN_PUB=$1; fetch asset $T/iout" 2>"$T/ierr" >/dev/null; }
rm -f "$T/iout" "$T/iout.sig"
printf 'payload\n' > "$T/rel/asset"; sign "$T/rel/asset"
run_ifetch "$T/run-sign.pub" || fail "install fetch rejected a signed asset"
[ "$(cat "$T/iout")" = payload ] || fail "install fetch did not keep the verified file"
[ ! -e "$T/iout.sig" ] || fail "install fetch left the .sig file behind"
printf 'tampered\n' > "$T/rel/asset"
run_ifetch "$T/run-sign.pub" && fail "install fetch accepted a tampered asset"
[ ! -e "$T/iout" ] || fail "install fetch left a tampered asset on disk"
grep -q "SIGNATURE CHECK FAILED" "$T/ierr" || fail "install fetch did not report the bad signature"
printf 'payload\n' > "$T/rel/asset"; rm -f "$T/rel/asset.sig"
run_ifetch "$T/run-sign.pub" && fail "install fetch accepted an asset with no signature file"
[ ! -e "$T/iout" ] || fail "install fetch kept an unsigned asset although a key is present"
run_ifetch "$T/nokey" || fail "install fetch without a key (old hook) should still work"
grep -q "NOT verified" "$T/ierr" || fail "install fetch did not warn about the unverified download"

# 2b. The hook starts the copy of ax10.sh that `ax10.sh boot` saved (save_copy,
#     src/75-saved-copy.sh) first, only if its signature verifies, and then downloads
#     boot.sh as before.
sh "$ROOT/scripts/build.sh"
cfuncs="$(awk '/^save_copy\(\)/{p=1} p{print} p&&/^}$/{exit}' "$ROOT/ax10.sh")"
[ -n "$cfuncs" ] || fail "ax10.sh has no save_copy"
mkdir -p "$T/conf"; echo "config x" > "$T/conf/network"; grep -v cache_iot "$T/uci.db" > "$T/conf/openvpn" || true
cache() { sh -c "$cfuncs
  save_copy $1 $2" 2>&1; }
export CACHE_UCI="$U" CACHE_CONF="$T/conf" CACHE_COMMIT=/nonexistent
printf '#!/bin/sh\necho "SAVED=$SAVED_COPY ARG=$1" > "%s/offmarker"\n' "$T" > "$T/ax10.sh"
i=0; while [ $i -lt 400 ]; do echo "# padding line $i so the copy needs several chunks $(echo $i | openssl dgst -sha256)" >> "$T/ax10.sh"; i=$((i + 1)); done
sign "$T/ax10.sh"
cache "$T/ax10.sh" "$T/ax10.sh.sig" | grep -q "saved to flash" || fail "save_copy did not save the copy"
[ "$($U get openvpn.archer_boot.cache_iot | wc -w)" -ge 2 ] || fail "save_copy did not split the copy into chunks"
# TP-Link's startup cuts every saved value to 2465 characters: chunks must stay well under.
[ "$($U get openvpn.archer_boot.cache_iot | tr ' ' '\n' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')" -le 1000 ] || fail "save_copy wrote a chunk longer than 1000 characters"
cache "$T/ax10.sh" "$T/ax10.sh.sig" | grep -q "saved" && fail "save_copy wrote flash again for the same release"
head -c 120000 /dev/urandom | openssl base64 > "$T/conf/big"
cp "$T/ax10.sh" "$T/iot2.sh"; echo "# changed" >> "$T/iot2.sh"; sign "$T/iot2.sh"
cache "$T/iot2.sh" "$T/iot2.sh.sig" | grep -q "would fill" || fail "save_copy did not refuse a copy that would fill the settings partition"
rm -f "$T/conf/big"
# A save that fails is reported as failed, leaves nothing staged, and leaves no checksum
# claiming the release is saved (so the next boot tries again).
printf '#!/bin/sh\nexit 1\n' > "$T/bin/failcommit"; chmod +x "$T/bin/failcommit"
out="$(CACHE_COMMIT="$T/bin/failcommit" cache "$T/iot2.sh" "$T/iot2.sh.sig")" && fail "save_copy returned success after a failed save: $out"
echo "$out" | grep -q "not saved" || fail "save_copy did not report the failed save ($out)"
[ "$($U get openvpn.archer_boot.cache_iot_sum)" = "$(md5sum < "$T/iot2.sh" | cut -d' ' -f1)" ] && fail "save_copy left the new checksum after a failed save"
# (the stand-in uci can't tell staged from saved, so its "revert" cleared the good copy
# too; the router's uci revert drops only what was staged. Save the good copy again.)
cache "$T/ax10.sh" "$T/ax10.sh.sig" | grep -q "saved to flash" || fail "save_copy did not save the copy again"
# boot.sh never downloads over the ax10.sh that is running: aside, then ax10.sh boot renames it in.
grep -q 'fetch ax10.sh /tmp/ax10.sh;' "$ROOT/boot.sh" && fail "boot.sh downloads over the running /tmp/ax10.sh"
grep -q 'fetch ax10.sh /tmp/ax10.sh.dl' "$ROOT/boot.sh" || fail "boot.sh does not download ax10.sh aside"
ocmd="$(printf '%s' "$($U get openvpn.archer_boot.boot_cmd)" | sed -e "s#B=https://[^;]*;#B=file://$T/norel;#" -e "s#/sbin/uci#$U#g" \
       -e "s#/usr/bin/openssl#openssl#g" -e "s#/usr/bin/curl#curl#g" -e "s#/bin/gzip#gzip#g" -e "s#/tmp/archer-#$T/run-#g" \
       -e "s#/tmp/iot.sh#$T/run-iot.sh#g" -e 's#sleep 30#exit 4#')"
set +e; sh -c "$ocmd" >/dev/null 2>&1; rc=$?; set -e
[ "$(cat "$T/offmarker" 2>/dev/null)" = "SAVED=1 ARG=boot" ] || fail "the saved copy of ax10.sh did not start first ($(cat "$T/offmarker" 2>/dev/null))"
[ $rc = 4 ] || fail "no internet: the hook did not go on to try the download after the saved copy (rc=$rc)"
# with the release reachable: the saved copy first, then boot.sh
rm -f "$T/offmarker" "$T/marker"; printf 'echo RAN > "%s/marker"\n' "$T" > "$T/rel/boot.sh"; sign "$T/rel/boot.sh"
rcmd="$(printf '%s' "$ocmd" | sed "s#file://$T/norel#file://$T/rel#")"
sh -c "$rcmd" >/dev/null 2>&1 || true
[ -e "$T/offmarker" ] && [ "$(cat "$T/marker" 2>/dev/null)" = RAN ] || fail "with internet: the saved copy and then boot.sh did not both run"
# a copy that doesn't match its signature never runs
rm -f "$T/offmarker"; good="$($U get openvpn.archer_boot.cache_iot_sig)"
$U set "openvpn.archer_boot.cache_iot_sig=$(openssl base64 -A < "$T/iot2.sh.sig")"
set +e; sh -c "$ocmd" >/dev/null 2>&1; set -e
[ ! -e "$T/offmarker" ] || fail "a saved copy with the wrong signature ran"
$U set "openvpn.archer_boot.cache_iot_sig=$good"
$U delete openvpn.archer_boot.cache_iot
set +e; sh -c "$ocmd" >/dev/null 2>&1; rc=$?; set -e
[ ! -e "$T/offmarker" ] && [ $rc = 4 ] || fail "no saved copy: the hook did not go on to the download (rc=$rc)"
# update rewrites the command and keeps the key
$U set "openvpn.archer_boot.boot_cmd=old"
UCI="$U" COMMIT=/nonexistent sh "$ROOT/scripts/signed-hook.sh" update >/dev/null
case "$($U get openvpn.archer_boot.boot_cmd)" in *cache_iot*) ;; *) fail "update did not rewrite the hook command" ;; esac
$U get openvpn.archer_boot.sign_pub | openssl base64 -d -A | cmp -s - "$T/pub.pem" || fail "update changed the key"

# 3c. boot_pkgs(): installs only packages whose file matches the SHA-256 in the
#     signed index, from the local file.
pfuncs="$(awk '/^SIGN_PUB=/{p=1} p{print} p&&/^fetch\(\)/{f=1} f&&/^}$/{exit}' "$ROOT/boot.sh")
$(awk '/^boot_pkgs\(\)/{p=1} p{print} p&&/^}$/{exit}' "$ROOT/boot.sh")"
mkdir -p "$T/prel"; printf 'good package\n' > "$T/prel/good_1_all.ipk"; printf 'bad package\n' > "$T/prel/bad_1_all.ipk"
{ printf 'Package: ax10-good\nFilename: good_1_all.ipk\nSHA256sum: %s\n\n' "$(openssl dgst -sha256 "$T/prel/good_1_all.ipk" | awk '{print $NF}')"
  printf 'Package: ax10-bad\nFilename: bad_1_all.ipk\nSHA256sum: %s\n\n' "$(printf 'what the index promised\n' | openssl dgst -sha256 | awk '{print $NF}')"; } > "$T/prel/Packages"
sign "$T/prel/Packages"
printf '#!/bin/sh\necho "$*" >> "%s/opkg.log"\n' "$T" > "$T/bin/opkg"; chmod +x "$T/bin/opkg"
out="$(sh -c "SRC=file://$T/prel; GET='curl -fs'; $pfuncs
  SIGN_PUB=$T/run-sign.pub; PKG_OPKG=$T/bin/opkg; PKG_DIR=$T/pkgs
  boot_pkgs 'ax10-good ax10-bad ax10-missing'" 2>&1)" || true
grep -q "/good_1_all.ipk" "$T/opkg.log" || fail "boot_pkgs did not install a package that matches the index ($out)"
grep -q "bad_1_all" "$T/opkg.log" && fail "boot_pkgs installed a package whose checksum does not match"
echo "$out" | grep -q "CHECKSUM MISMATCH" || fail "boot_pkgs did not report the mismatch"
echo "$out" | grep -q "ax10-missing: not in the feed" || fail "boot_pkgs did not report a package missing from the feed"
[ ! -e "$T/pkgs" ] || fail "boot_pkgs left its downloads behind"
printf 'Package: ax10-good\n' > "$T/prel/Packages"          # an index whose signature no longer matches
out="$(sh -c "SRC=file://$T/prel; GET='curl -fs'; $pfuncs
  SIGN_PUB=$T/run-sign.pub; PKG_OPKG=$T/bin/opkg; PKG_DIR=$T/pkgs
  boot_pkgs 'ax10-good'" 2>&1)" || true
echo "$out" | grep -q "no signed index" || fail "boot_pkgs used an index with a bad signature ($out)"

# 4. revert restores the previous hook.
UCI="$T/bin/uci" COMMIT=/nonexistent sh "$ROOT/scripts/signed-hook.sh" revert >/dev/null
[ "$($U get openvpn.archer_boot.up)" = '"old unsigned hook"' ] || fail "revert did not restore the old hook"
$U get openvpn.archer_boot.sign_pub >/dev/null 2>&1 && fail "revert left the key"

echo "signing tests passed"
