#!/bin/sh
# signed-hook.sh — switch the router's boot hook to signed releases (run ON the router).
#
#   sh signed-hook.sh install <signing.pub.pem>   save key + verifying hook to flash
#   sh signed-hook.sh update                      rewrite only the hook command (key kept)
#   sh signed-hook.sh show                        print the current hook settings
#   sh signed-hook.sh revert                      restore the previous (unsigned) hook
#
# Old hook: curl -k boot.sh from the main branch and run it.
# New hook: the OpenVPN `up` line only runs openvpn.archer_boot.boot_cmd (OpenVPN
# limits config lines to ~256 chars, so the logic lives in its own option). That
# command writes the public key from openvpn.archer_boot.sign_pub, downloads
# boot.sh + boot.sh.sig from the latest release, and runs boot.sh only if the
# signature verifies, retrying every 30 s otherwise. A bad release therefore
# never runs; publishing a correctly signed release fixes it without SSH.
# boot.sh then verifies everything it downloads with the same key.
# Before any of that, the hook starts the copy of ax10.sh that boot.sh saved in flash
# (save_copy in ax10.sh), if it verifies with the same key: the home allow list and the IoT
# network are up within seconds of boot, with or without internet. The release is
# then the update: boot.sh runs in full as soon as it downloads, saves the new
# ax10.sh if it changed and restarts on it.
#
# Keep the private key (~/.ssh/archer-ax10-release-signing.pem and the
# RELEASE_SIGNING_KEY Actions secret): without it no new release can be signed,
# and the router would keep running nothing new until the hook is reverted.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
UCI="${UCI:-/sbin/uci}"
COMMIT="${COMMIT:-/sbin/uci_commit_flash}"
S=openvpn.archer_boot
REL=https://github.com/talhabalaj/archer-ax10/releases/latest/download

BOOT_CMD="B=$REL; K=/tmp/archer-sign.pub; F=/tmp/archer-boot.sh; \
/sbin/uci -q get $S.sign_pub | /usr/bin/openssl base64 -d -A > \$K; \
[ -s \$K ] || { echo 'no signing key saved; refusing to run'; exit 1; }; \
O=/tmp/archer-saved-iot.sh; /sbin/uci -q get $S.cache_iot | tr -d ' \\n' | /usr/bin/openssl base64 -d -A | /bin/gzip -dc > \$O 2>/dev/null; \
/sbin/uci -q get $S.cache_iot_sig | /usr/bin/openssl base64 -d -A > \$O.sig; \
if [ -s \$O ] && /usr/bin/openssl dgst -sha256 -verify \$K -signature \$O.sig \$O; then echo 'starting the copy of iot.sh saved in flash'; \
cp \$O /tmp/iot.sh; SAVED_COPY=1 /bin/sh /tmp/iot.sh boot; else echo 'no usable copy of iot.sh in flash'; fi; rm -f \$O \$O.sig; \
until /usr/bin/curl -4Lkfs -m 60 \$B/boot.sh -o \$F && /usr/bin/curl -4Lkfs -m 30 \$B/boot.sh.sig -o \$F.sig && \
/usr/bin/openssl dgst -sha256 -verify \$K -signature \$F.sig \$F; do echo 'boot.sh download or signature check failed; retrying in 30s'; sleep 30; done; \
SRC=\$B /bin/sh \$F"
UP="\"/bin/sh -c '/sbin/uci -q get $S.boot_cmd | /bin/sh >/tmp/archer-boot.log 2>&1 &'\""

save() { if [ -x "$COMMIT" ]; then "$COMMIT" openvpn; else $UCI commit openvpn; fi; }

case "$1" in
    install)
        [ -s "$2" ] || { echo "usage: $0 install <signing.pub.pem>" >&2; exit 1; }
        openssl pkey -pubin -in "$2" -noout 2>/dev/null || openssl ec -pubin -in "$2" -noout 2>/dev/null ||
            { echo "$2 is not a public key" >&2; exit 1; }
        pub="$(openssl base64 -A -in "$2")"
        # Self-test before touching flash: the saved key must round-trip.
        printf '%s' "$pub" | openssl base64 -d -A | cmp -s - "$2" || { echo "key encoding failed" >&2; exit 1; }
        [ -n "$($UCI -q get $S.up_unsigned)" ] || $UCI set "$S.up_unsigned=$($UCI -q get $S.up)"
        $UCI set "$S.sign_pub=$pub"
        $UCI set "$S.boot_cmd=$BOOT_CMD"
        $UCI set "$S.up=$UP"
        save && echo "signed boot hook saved to flash; previous hook kept in $S.up_unsigned" ;;
    update)
        [ -n "$($UCI -q get $S.sign_pub)" ] || { echo "no signing key saved; use install" >&2; exit 1; }
        $UCI set "$S.boot_cmd=$BOOT_CMD"
        $UCI set "$S.up=$UP"
        save && echo "boot hook command updated in flash (key unchanged)" ;;
    show)
        echo "up=$($UCI -q get $S.up)"
        echo "boot_cmd=$($UCI -q get $S.boot_cmd)"
        echo "sign_pub=$($UCI -q get $S.sign_pub | cut -c1-40)..."
        echo "up_unsigned=$($UCI -q get $S.up_unsigned)" ;;
    revert)
        old="$($UCI -q get $S.up_unsigned)"; [ -n "$old" ] || { echo "no saved previous hook" >&2; exit 1; }
        $UCI set "$S.up=$old"; $UCI -q delete "$S.boot_cmd"; $UCI -q delete "$S.sign_pub"
        save && echo "previous hook restored" ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
