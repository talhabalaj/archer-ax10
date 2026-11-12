#!/bin/sh
# ============================================================
# boot.sh — fetched by the openvpn up-hook after WAN is up (scripts/signed-hook.sh).
# Sets the root password (mirrors the web-GUI admin password), starts a dropbear SSH
# lifeline on :2222, starts our add-ons (ax10.sh: IoT network, home allow list, speed
# limits, names, dashboard) and saves a copy of ax10.sh in flash (the hook starts that
# copy first at the next boot), then installs the packages listed in
# openvpn.archer_boot.boot_pkgs.
# Every download is checked against the release key.
# ============================================================
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
SSH_PORT="${SSH_PORT:-2222}"
LAN_IP="$(/sbin/uci -q get network.lan.ipaddr)"
[ -n "$LAN_IP" ] || { echo 'LAN address unavailable'; exit 1; }
# Keep the SSH host identity stable across tmpfs rebuilds. The private host key
# stays in the router's saved configuration, never in this repository.
HOSTKEY_B64="$(/sbin/uci -q get openvpn.archer_boot.host_key)"
HOSTKEY_ARGS=""
if [ -n "$HOSTKEY_B64" ]; then
    umask 077
    printf '%s' "$HOSTKEY_B64" | /usr/bin/openssl base64 -d -A > /tmp/archer-boot-host.key || exit 1
    HOSTKEY_ARGS="-r /tmp/archer-boot-host.key"
fi
unset HOSTKEY_B64
# SSH is reachable from the LAN bridge, independent of any client's DHCP IP.
/usr/sbin/iptables -C INPUT -p tcp --dport "$SSH_PORT" -j DROP 2>/dev/null || /usr/sbin/iptables -I INPUT 1 -p tcp --dport "$SSH_PORT" -j DROP
/usr/sbin/iptables -C INPUT -i br-lan -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I INPUT 1 -i br-lan -p tcp --dport "$SSH_PORT" -j ACCEPT
# This dummy OpenVPN instance only provides the persisted startup hook.
[ "$(/sbin/uci -q get openvpn.server.enabled)" = off ] && /sbin/fw openvpn_block udp 1194 home 2>/dev/null

SRC="${SRC:-https://github.com/talhabalaj/archer-ax10/releases/latest/download}"
GET="/usr/bin/curl -4 -L -k -fs"

# Signed downloads. The boot hook (openvpn.archer_boot.boot_cmd, in flash) writes
# the release public key here and only runs boot.sh after verifying its signature.
# Everything boot.sh downloads is checked the same way. Without a key (older hook)
# files are used unverified, so switching hooks cannot lock the router out.
SIGN_PUB=/tmp/archer-sign.pub
verify_sig() {   # verify_sig <file> <file.sig>
    [ -s "$SIGN_PUB" ] || return 0
    /usr/bin/openssl dgst -sha256 -verify "$SIGN_PUB" -signature "$2" "$1" >/dev/null 2>&1
}
fetch() {        # fetch <release asset> <local path>
    $GET -m 60 "$SRC/$1" -o "$2" || { echo "$1: download failed"; return 1; }
    [ -s "$SIGN_PUB" ] || return 0
    $GET -m 30 "$SRC/$1.sig" -o "$2.sig" && verify_sig "$2" "$2.sig" ||
        { echo "$1: SIGNATURE CHECK FAILED, not using it"; rm -f "$2"; return 1; }
}

# ----------------------------------------------------------------
# Root password = the router's OWN web-GUI admin password, so :2222 SSH login
# mirrors the TP-Link web UI. The stock squashfs ships NO /etc/shadow (root
# locked), so a password must be set for dropbear to accept a login. TP-Link
# stores the web password AES-encrypted in /etc/config/accountmgnt, so we ask the
# router's own decrypt routine for the plaintext, pipe it into cryptpw (never in
# argv/on disk), and write the hash. Fallback = the well-known default "admin"
# (a crypt hash of "admin", not a secret), reached only if the decrypt/crypt fails.
# ----------------------------------------------------------------
echo "Setting root password (mirroring the web-GUI admin password)..."
_wpw="$(/usr/bin/lua -e 'local ok,a=pcall(require,"luci.model.accountmgnt"); if ok and type(a.get_localPassword)=="function" then local p=a.get_localPassword(); if type(p)=="string" then io.write(p) end end' 2>/dev/null)"
_h=""
[ -n "$_wpw" ] && _h="$(printf '%s' "$_wpw" | /bin/busybox cryptpw -m md5 2>/dev/null)"
[ -z "$_h" ] && [ -n "$_wpw" ] && _h="$(printf '%s\n' "$_wpw" | /usr/bin/openssl passwd -1 -stdin 2>/dev/null)"
if [ -n "$_h" ]; then
    printf 'root:%s:0:0:99999:7:::\n' "$_h" > /etc/shadow
else
    echo 'root:$1$Ax10boot$zooYD5Cu6tYQJk9Cd0SIL1:0:0:99999:7:::' > /etc/shadow
fi
unset _wpw _h

# SSH LIFELINE on :2222 — direct fetch + launch, the always-available way in.
fetch dropbear_vanilla /tmp/dropbear_vanilla && chmod +x /tmp/dropbear_vanilla
SSH_PID="/tmp/archer-boot-ssh-$SSH_PORT.pid"
lifeline_up() { p="$(cat "$SSH_PID" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
start_lifeline() {
    echo "Starting dropbear SSH lifeline on :2222..."
    (/tmp/dropbear_vanilla -p "$LAN_IP:$SSH_PORT" -P "$SSH_PID" $HOSTKEY_ARGS -R -E </dev/null >/dev/null 2>&1) &
}
start_lifeline

# Optional isolated IoT Wi-Fi (see ax10.sh). Once set up (any iot_enabled value is
# saved), install its web UI page every boot; ax10.sh starts the network if enabled.
if [ -n "$(/sbin/uci -q get openvpn.archer_boot.iot_enabled)" ]; then
    echo "Starting IoT network..."
    # ax10.sh boot also keeps this ax10.sh as the copy in flash the hook starts first at
    # the next boot (src/75-saved-copy.sh), with its signature from the release.
    # Downloaded aside, never over /tmp/ax10.sh: the saved copy's watcher is already
    # running that file, and would run a half-downloaded or unverified one. `boot`
    # (holding the run lock, after stopping that watcher) renames it into place.
    if fetch ax10.sh /tmp/ax10.sh.dl; then
        SRC="$SRC" SIGN_PUB="$SIGN_PUB" SAVE_COPY_SIG=/tmp/ax10.sh.dl.sig /bin/sh /tmp/ax10.sh.dl boot
    fi
fi

# The IoT step reconfigures Wi-Fi/dnsmasq at boot; make sure SSH survived it.
sleep 2
lifeline_up || { echo "SSH lifeline not running after IoT step; restarting it"; start_lifeline; }

# Packages from our feed at every boot: opkg itself plus openvpn.archer_boot.boot_pkgs
# (e.g. "ax10-busybox"; empty = none). Everything is checked: install.sh and the opkg
# payload by signature, each package by the SHA-256 in the signed package index, and
# then installed from the local file: opkg's own downloads go through a wget that
# does not check certificates, so it is never left to fetch anything.
boot_pkgs() {    # boot_pkgs <packages>
    OPKG="${PKG_OPKG:-/tmp/opt/opkg}"; P="${PKG_DIR:-/tmp/ax10-pkgs}"
    fetch Packages "$P.index" || { echo "packages: no signed index; skipped"; return 0; }
    if [ ! -x "$OPKG" ]; then
        fetch install.sh "$P.install.sh" || { echo "packages: no signed install.sh; skipped"; return 0; }
        SRC="$SRC" FEED="$SRC" SIGN_PUB="$SIGN_PUB" NO_UPDATE=1 /bin/sh "$P.install.sh" > "$P.install.log" 2>&1 ||
            { echo "packages: opkg did not install (see $P.install.log)"; return 0; }
    fi
    mkdir -p "$P"
    for p in $1; do
        f="$(awk -v p="$p" '$1 == "Package:" { c = $2 } c == p && $1 == "Filename:" { print $2; exit }' "$P.index")"
        sha="$(awk -v p="$p" '$1 == "Package:" { c = $2 } c == p && $1 == "SHA256sum:" { print $2; exit }' "$P.index")"
        case "$f" in ""|*/*|.*) echo "$p: not in the feed"; continue ;; esac
        $GET -m 120 "$SRC/$f" -o "$P/$f" || { echo "$p: download failed"; continue; }
        if [ "$(/usr/bin/openssl dgst -sha256 "$P/$f" | awk '{ print $NF }')" != "$sha" ]; then
            echo "$p: CHECKSUM MISMATCH, not installing"; rm -f "$P/$f"; continue
        fi
        "$OPKG" install "$P/$f" >/dev/null 2>&1 && echo "$p installed" || echo "$p: install failed"
    done
    rm -rf "$P" "$P.index" "$P.install.sh"
}
PKGS="$(/sbin/uci -q get openvpn.archer_boot.boot_pkgs)"
[ -n "$PKGS" ] && { echo "Installing packages: $PKGS"; boot_pkgs "$PKGS"; }

echo "boot done."
