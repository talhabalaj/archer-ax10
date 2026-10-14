#!/bin/sh
# ax10-opkg installer — gives a bare TP-Link Archer AX10 a working `opkg`.
#
# This ONE script owns the whole opkg install: it fetches the payload, unpacks it
# into tmpfs, sets up the HTTPS-capable wget opkg needs, wires the feed URL, builds
# the loader wrappers, and puts `opkg` on your PATH. It is self-contained, safe to
# re-run, and needs nothing but a shell + `curl` (which the stock firmware has).
#
#   Fresh install (see README):
#     curl -4Lk https://github.com/lee-soft/ax10-opkg/releases/latest/download/install.sh | sh
#
#   boot.sh calls this same script (passing SRC/FEED), so the router's boot path and
#   a hand-run install are byte-for-byte the same logic — no drift.
#
# Everything lives in tmpfs (/tmp/opt) and is rebuilt on each boot; this router has a
# read-only squashfs root with no overlay, so that is by design, not a limitation.
#
# Overridable via the environment:
#   SRC        where opt.tar.gz + busybox-armv7l are fetched from
#   FEED       the opkg `ax10` package feed base (Packages.gz + *.ipk)
#   GET        the download command (default: curl -4 -L -k -fsS)
#   NO_UPDATE  set to 1 to skip the trailing `opkg update`
#   NO_PROFILE set to 1 to skip writing PATH/env into /etc/profile

SRC="${SRC:-https://github.com/talhabalaj/archer-ax10/releases/latest/download}"
FEED="${FEED:-https://github.com/talhabalaj/archer-ax10/releases/latest/download}"
GET="${GET:-curl -4 -L -k -fsS}"

fail() { echo "ax10-opkg: $1" >&2; exit 1; }

# 1) HTTPS-capable busybox. opkg shells out to `wget` for downloads, and the stock
#    busybox 1.19 wget has NO SSL. This busybox 1.31 does (its ssl_client applet —
#    no CA bundle or synced clock required). Idempotent: keep an existing one.
if [ ! -x /tmp/vanilla/busybox ]; then
    mkdir -p /tmp/vanilla/bin
    $GET "$SRC/busybox-armv7l" -o /tmp/vanilla/busybox || fail "could not fetch busybox from $SRC"
    chmod +x /tmp/vanilla/busybox
fi
mkdir -p /tmp/wgetssl
ln -sf /tmp/vanilla/busybox /tmp/wgetssl/wget
ln -sf /tmp/vanilla/busybox /tmp/wgetssl/ssl_client

# 2) Fetch + unpack the opkg tree into tmpfs at /tmp/opt.
$GET "$SRC/opt.tar.gz" -o /tmp/opt.tgz || fail "could not fetch opt.tar.gz from $SRC"
rm -rf /tmp/opt
/bin/gzip -dc /tmp/opt.tgz | /bin/tar xf - -C /tmp || fail "could not unpack opt.tar.gz"
rm -f /tmp/opt.tgz
mkdir -p /tmp/opt/tmp /tmp/opt/var/lock /tmp/opt/var/opkg-lists /tmp/opt/var/run
[ -x /tmp/opt/bin/opkg-bin ] || fail "payload missing opkg-bin"

# 3) Point the `ax10` feed at $FEED. The payload ships a generic default; this is the
#    file opkg actually reads (/tmp/opt/etc/opkg.conf — via the `opkg` wrapper's -f).
CONF=/tmp/opt/etc/opkg.conf
if grep -q '^src/gz ax10 ' "$CONF" 2>/dev/null; then
    sed -i "s#^src/gz ax10 .*#src/gz ax10 $FEED#" "$CONF"
else
    echo "src/gz ax10 $FEED" >> "$CONF"
fi

# 4) Loader wrappers for the Entware glibc-2.27 binaries (they hardcode /opt paths).
[ -x /tmp/opt/opt-genwrappers.sh ] && /tmp/opt/opt-genwrappers.sh 2>/dev/null

# 5) Make `opkg` reachable and set the runtime env — this shell AND future logins.
#    /root is on the RO squashfs; tmpfs-mount it so TUI tools can write ~/.config.
ln -sf /tmp/opt/opkg /tmp/vanilla/bin/opkg 2>/dev/null
grep -q ' /root ' /proc/mounts 2>/dev/null || {
    cp -a /root /tmp/.root-seed 2>/dev/null
    mount -t tmpfs tmpfs /root 2>/dev/null && cp -a /tmp/.root-seed/. /root/ 2>/dev/null
    rm -rf /tmp/.root-seed
}

export PATH="/tmp/opt/wrappers:/tmp/wgetssl:/tmp/vanilla/bin:$PATH"
export TERMINFO=/tmp/opt/share/terminfo LOCPATH=/tmp/opt/usr/lib/locale LC_CTYPE=en_US.UTF-8

if [ "$NO_PROFILE" != 1 ] && [ -w /etc/profile ]; then
    for l in \
        'export PATH="/tmp/opt/wrappers:/tmp/wgetssl:/tmp/vanilla/bin:$PATH"' \
        'export TERMINFO=/tmp/opt/share/terminfo' \
        'export LOCPATH=/tmp/opt/usr/lib/locale' \
        'export LC_CTYPE=en_US.UTF-8'; do
        grep -qF "$l" /etc/profile 2>/dev/null || echo "$l" >> /etc/profile
    done
fi

# 6) Prime the package lists so `opkg install <x>` works immediately.
if [ "$NO_UPDATE" != 1 ]; then
    /tmp/opt/opkg update >/dev/null 2>&1 \
        && echo "ax10-opkg: feed lists updated" \
        || echo "ax10-opkg: 'opkg update' failed (check network / FEED=$FEED)" >&2
fi

echo "ax10-opkg: ready. Try:  opkg install htop"
echo "ax10-opkg: (new shells pick up PATH from /etc/profile; in THIS one, opkg is /tmp/opt/opkg)"
