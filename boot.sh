#!/bin/sh
# ============================================================
# MINIMAL LIFELINE-ONLY boot.sh — fetched by the openvpn up-hook after WAN is up.
# Sets the root password (mirrors the web-GUI admin password) and starts a dropbear
# SSH lifeline on :2222. NOTHING ELSE — no opkg, no packages, no LuCI, no hardening.
# Use this to reboot into a bare factory router that we can still SSH into, then
# deploy the real stack by hand from the GitHub feed.
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

# Optional isolated IoT Wi-Fi (see iot.sh). Once set up (any iot_enabled value is
# saved), install its web UI page every boot; iot.sh starts the network if enabled.
if [ -n "$(/sbin/uci -q get openvpn.archer_boot.iot_enabled)" ]; then
    echo "Starting IoT network..."
    fetch iot.sh /tmp/iot.sh && SRC="$SRC" SIGN_PUB="$SIGN_PUB" /bin/sh /tmp/iot.sh boot
fi

# The IoT step reconfigures Wi-Fi/dnsmasq at boot; make sure SSH survived it.
sleep 2
lifeline_up || { echo "SSH lifeline not running after IoT step; restarting it"; start_lifeline; }

echo "lifeline-only boot done."
