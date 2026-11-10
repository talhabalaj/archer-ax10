#!/bin/sh
# ============================================================
# iot.sh — isolated IoT Wi-Fi network for the stock Archer AX10 firmware.
#
# Turns a spare 2.4GHz virtual AP (wl1.4 by default) into its own SSID, puts it in
# its own bridge (br-iot) with its own subnet, serves DHCP through the stock
# dnsmasq, and firewalls it. wl1.4 is TP-Link's EasyMesh/OneMesh onboarding slot:
# its mesh flags (map=3, dwds=1) make the driver hand every client a wds interface
# that TP-Link bridges into br-lan. TP-Link's Wi-Fi script is patched (RAM copy,
# bind-mounted) so its rebuilds give the slot plain-AP flags, and the flags are
# applied now with one short bounce of that radio (`wl down`/`wl up`). TP-Link's
# guest-isolation module (br-filter) also lists the slot in deny_all, which drops
# all forwarded traffic from it; the slot is taken off that list. Side effect:
# OneMesh onboarding of NEW satellites on 2.4GHz will not work while this runs;
# existing satellites use wl1.2/wl0.2.
#
#
#   home LAN  -> IoT        allowed   (apps / inverter-link can reach devices)
#   IoT       -> home LAN   blocked   (except replies, and iot_allow_lan exceptions)
#   IoT       -> router     DHCP, DNS and ping only (no web GUI / SSH)
#   IoT       -> internet   allowed, except MACs listed in iot_noinet
#
# Settings are UCI options on openvpn.archer_boot (next to the SSH host key), the one
# place this router persists. They can be edited from the stock web UI page this
# script installs (Advanced > Wireless > IoT Network) or with `iot.sh set`.
#
#   iot.sh boot       what boot.sh runs: install the web page; start if enabled
#   iot.sh ui         install the IoT Network page into the stock web UI
#   iot.sh ui-remove  remove the page again
#   iot.sh start      apply now and register the watcher with busybox-init (respawn)
#   iot.sh stop       unregister, tear down br-iot, hand the Wi-Fi slot back to TP-Link
#   iot.sh apply      (re)apply everything once
#   iot.sh watch      foreground loop: re-apply whenever TP-Link undoes our state
#   iot.sh status     show what is in place
#   iot.sh guest      apply + show the guest speed limit
#   iot.sh set <key> <value>   save a setting (iot_ prefix optional), e.g.
#                     iot.sh set ssid "wifi iot"      iot.sh set key "<password>"
#                     iot.sh set static "aa:bb:cc:dd:ee:01,192.168.50.10"
#                     iot.sh set noinet "aa:bb:cc:dd:ee:02"
#                     iot.sh set allow_lan "tcp:8899@192.168.50.10"
#                     iot.sh set lan_mode selected; iot.sh set lan_allow "<phone-mac>"
#                     iot.sh set enabled 1
# ============================================================
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Binaries and paths, overridable for tests.
UCI="${UCI:-/sbin/uci}"
WL="${WL:-/usr/sbin/wl}"
HAPD_CLI="${HAPD_CLI:-hostapd_cli -p /var/run/hostapd}"
BRCTL="${BRCTL:-brctl}"
IP="${IP:-ip}"
# -w: wait for the xtables lock; TP-Link's scripts and the watcher can overlap.
IPT="${IPT:-/usr/sbin/iptables -w}"
MOUNT="${MOUNT:-mount}"
UMOUNT="${UMOUNT:-umount}"
NET="${NET:-/sys/class/net}"
RUN="${RUN:-/tmp/ax10-iot}"
INITTAB="${INITTAB:-/etc/inittab}"
SELF="${SELF:-/tmp/iot.sh}"
ARP="${ARP:-/proc/net/arp}"
LEASES="${LEASES:-/tmp/dhcp.leases}"
SYS6="${SYS6:-/proc/sys/net/ipv6/conf}"
# How to make busybox-init re-read inittab; tests set INIT_HUP=true.
INIT_HUP="${INIT_HUP:-kill -HUP 1}"
SRC="${SRC:-https://github.com/talhabalaj/archer-ax10/releases/latest/download}"
SEC=openvpn.archer_boot
BR=br-iot
CH_FWD=AX10_IOT_FWD
CH_IN=AX10_IOT_IN
CH_NAT=AX10_IOT_NAT
CH_IOT6=AX10_IOT6
LOG="$RUN/iot.log"

cfg() { v="$($UCI -q get "$SEC.iot_$1" 2>/dev/null)"; [ -n "$v" ] && echo "$v" || echo "$2"; }
load() {
    VIF="$(cfg vif wl1.4)"
    SSID="$(cfg ssid '')"
    KEY="$(cfg key '')"
    HIDDEN="$(cfg hidden 0)"
    GW="$(cfg ip 192.168.50.1)"
    PREFIX="${GW%.*}"
    START="$(cfg dhcp_start "$PREFIX.100")"
    END="$(cfg dhcp_end "$PREFIX.200")"
    DNS="$(cfg dns '1.1.1.1 8.8.8.8')"
    NOINET="$(cfg noinet '')"
    STATIC="$(cfg static '')"
    ALLOW_LAN="$(cfg allow_lan '')"
    LAN_MODE="$(cfg lan_mode all)"      # all | selected
    LAN_ALLOW="$(cfg lan_allow '')"     # home MACs allowed to reach IoT (mode selected)
}
log() { mkdir -p "$RUN"; echo "$(cut -d. -f1 /proc/uptime 2>/dev/null)s $*" >> "$LOG"; }
trim_log() { [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && tail -n 200 "$LOG" > "$LOG.1" && mv "$LOG.1" "$LOG"; }

# --------------------------------------------------------------------- lock
# One iot.sh at a time may change the router. The watcher, `start` from the web
# page (once per saved switch) and a shell can all overlap; interleaved rebuilds
# would leave iptables rules in the wrong order. mkdir is atomic on every
# filesystem here (no flock in this busybox). The holder's pid is stored so a
# lock left by a killed process (watcher_restart kills the watcher) is taken over.
LOCK="$RUN/lock"
LOCK_WAIT="${LOCK_WAIT:-60}"
lock() {   # lock [seconds to wait, default $LOCK_WAIT]; returns 1 if still held
    w="${1:-$LOCK_WAIT}"; mkdir -p "$RUN"
    while :; do
        if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
        p="$(cat "$LOCK/pid" 2>/dev/null)"
        if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
            # Holder is gone. Remove only if it is still that holder's lock.
            [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$p" ] && rm -rf "$LOCK"
            continue
        fi
        if [ "$w" -le 0 ]; then
            # No pid after the whole wait: the holder died between mkdir and
            # writing its pid. Take the lock over.
            [ -z "$p" ] && { rm -rf "$LOCK"; continue; }
            return 1
        fi
        w=$((w - 1)); sleep 1
    done
}
unlock() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"; return 0; }

bridge_of() { m="$(readlink "$NET/$1/brport/bridge" 2>/dev/null)"; echo "${m##*/}"; }

# ---------------------------------------------------------------- Wi-Fi slot
# hostapd (one process per radio, config /tmp/wl1.1_hapd.conf) runs every 2.4GHz
# BSS; `set` changes this BSS in memory and reload_wpa_psk re-derives its PSK
# without disturbing the other networks. The wl driver needs the SSID and
# broadcast flag too. TP-Link regenerates its own values whenever it restarts
# Wi-Fi, so remember what was applied (plus hostapd's pid) and redo it on change.
# --- mesh flags on the slot
WIFI_SH="${WIFI_SH:-/lib/wifi/tplink_brcm.sh}"
NVRAM="${NVRAM:-/usr/sbin/nvram}"
radio_of() { echo "${1%%.*}"; }                     # wl1.4 -> wl1
vif_flags_ok() {
    [ "$($WL -i "$VIF" dwds 2>/dev/null)" = 0 ] &&
    case "$($WL -i "$VIF" map 2>/dev/null)" in 0x0*|0) true;; *) false;; esac
}
wifi_patch() {
    grep -q " $WIFI_SH " /proc/mounts 2>/dev/null && return 0
    mkdir -p "$OV"
    sed -e 's/nvram set ${CONFIG_WIFI}_map="3"/nvram set ${CONFIG_WIFI}_map="0"/' \
        -e 's/nvram set ${RTORCFG_WIFI}_dwds="1"/nvram set ${RTORCFG_WIFI}_dwds="0"/' \
        "$WIFI_SH" > "$OV/tplink_brcm.sh" || return 1
    grep -q 'CONFIG_WIFI}_map="0"' "$OV/tplink_brcm.sh" &&
        grep -q 'RTORCFG_WIFI}_dwds="0"' "$OV/tplink_brcm.sh" || { log "TP-Link Wi-Fi script not as expected; not patched"; return 1; }
    chmod 755 "$OV/tplink_brcm.sh"
    $MOUNT --bind "$OV/tplink_brcm.sh" "$WIFI_SH" && log "patched $WIFI_SH (plain-AP flags for $VIF)"
}
wifi_unpatch() { grep -q " $WIFI_SH " /proc/mounts 2>/dev/null && $UMOUNT "$WIFI_SH"; }
# Mesh flags can only change while the whole radio is down. Bounce just this radio
# (a few seconds; the other band is untouched) and bring its networks back up.
# hostapd keeps running and clients simply reconnect. At most once per 10 minutes,
# so a failure cannot turn into a bounce loop.
radio_set_flags() {   # radio_set_flags <dwds> <map>
    r="$(radio_of "$VIF")"; up=""
    for p in "$NET"/"$r".*; do
        [ -e "$p" ] || continue; v="${p##*/}"
        [ "$($WL -i "$v" bss 2>/dev/null)" = up ] && up="$up $v"
    done
    $NVRAM set "${VIF}_dwds=$1"; $NVRAM set "${VIF}_map=$2"
    $WL -i "$r" down
    $WL -i "$VIF" dwds "$1"; $WL -i "$VIF" map "$2"
    $WL -i "$r" up
    sleep 2
    for v in $up; do $WL -i "$v" bss up; done
    rm -f "$RUN/vif.sig"
}
radio_rebuild() {
    now="$(cut -d. -f1 /proc/uptime 2>/dev/null)"; now="${now:-0}"; last="$(cat "$RUN/rebuild.at" 2>/dev/null || echo -9999)"
    [ $((now - last)) -ge 600 ] || { log "radio bounce skipped (last one $((now - last))s ago)"; return 1; }
    echo "$now" > "$RUN/rebuild.at"
    log "bouncing $(radio_of "$VIF") to clear mesh flags on $VIF"
    radio_set_flags 0 0
}
# TP-Link's br-filter (guest isolation) drops all forwarded traffic from interfaces
# in deny_all, and lists the OneMesh config slot there. Keep our slot off it.
BRF="${BRF:-/proc/bridge_filter}"
brfilter_sync() {
    [ -f "$BRF/deny_all" ] || return 0
    cur="$(cat "$BRF/deny_all")"; new=""
    for i in $cur; do
        case "$i" in "$VIF"|"wds${VIF#wl}"*) ;; *) new="$new $i";; esac
    done
    [ "$(echo $cur)" = "$(echo $new)" ] && return 0
    echo "$new" > "$BRF/deny_all" && log "removed $VIF from br-filter deny_all"
}
brfilter_restore() { [ -x /etc/init.d/br-filter ] && [ -f "$BRF/deny_all" ] && /etc/init.d/br-filter start >/dev/null 2>&1; }

# Per-client wds interfaces of the slot must never stay in br-lan.
wds_guard() {
    for p in "$NET"/wds"${VIF#wl}".*; do
        [ -e "$p" ] || continue; w="${p##*/}"
        [ "$(bridge_of "$w")" = "$BR" ] && continue
        cur="$(bridge_of "$w")"; [ -n "$cur" ] && $BRCTL delif "$cur" "$w"
        $BRCTL addif $BR "$w" && log "moved $w from ${cur:-none} to $BR"
    done
}

live_ssid() { $WL -i "$VIF" ssid 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p'; }
vif_sig() { echo "$VIF|$SSID|$KEY|$HIDDEN|$(pidof hostapd 2>/dev/null)"; }
vif_sync() {
    [ -d "$NET/$VIF" ] || { log "no interface $VIF"; return 1; }
    [ "$(live_ssid)" = "$SSID" ] && [ "$($WL -i "$VIF" bss 2>/dev/null)" = up ] &&
        [ "$(cat "$RUN/vif.sig" 2>/dev/null)" = "$(vif_sig)" ] && return 0
    hb=0; [ "$HIDDEN" = 1 ] && hb=1
    $HAPD_CLI -i "$VIF" set ssid "$SSID" >/dev/null
    $HAPD_CLI -i "$VIF" set wpa_passphrase "$KEY" >/dev/null
    $HAPD_CLI -i "$VIF" set ignore_broadcast_ssid $hb >/dev/null
    $HAPD_CLI -i "$VIF" reload_wpa_psk >/dev/null
    $WL -i "$VIF" closed $hb
    $WL -i "$VIF" ssid "$SSID" >/dev/null
    $WL -i "$VIF" bss up
    vif_sig > "$RUN/vif.sig"
    log "$VIF broadcasting '$SSID'$([ $hb = 1 ] && echo ' (hidden)')"
}
vif_release() {
    [ -d "$NET/$VIF" ] || return 0
    $WL -i "$VIF" bss down 2>/dev/null
    $HAPD_CLI -i "$VIF" set ignore_broadcast_ssid 1 >/dev/null 2>&1
    $WL -i "$VIF" closed 1 2>/dev/null
    rm -f "$RUN/vif.sig"
}

# ---------------------------------------------------------------------- DHCP
# The stock dnsmasq owns port 67 on 0.0.0.0, so a second DHCP server cannot bind.
# Instead, add the IoT range to /etc/dnsmasq.conf, which TP-Link's generated
# /var/etc/dnsmasq.conf includes via conf-file= and never rewrites. /etc is in RAM,
# so the block disappears on reboot and boot.sh adds it again.
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.conf}"
DNSMASQ_INIT="${DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
MARK_BEGIN="# ax10-iot begin"; MARK_END="# ax10-iot end"
dhcp_block() {
    echo "$MARK_BEGIN"
    echo "dhcp-range=set:iot,$START,$END,255.255.255.0,12h"
    echo "dhcp-option=tag:iot,3,$GW"
    echo "dhcp-option=tag:iot,6,$(echo $DNS | tr ' ' ',')"
    for s in $STATIC; do echo "dhcp-host=${s%%,*},${s#*,}"; done
    echo "$MARK_END"
}
dhcp_strip() { sed "/^$MARK_BEGIN\$/,/^$MARK_END\$/d" "$DNSMASQ_CONF"; }
dnsmasq_restart() {
    if [ -x "$DNSMASQ_INIT" ]; then "$DNSMASQ_INIT" restart >/dev/null 2>&1
    else
        killall dnsmasq 2>/dev/null; sleep 1
        /usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf
    fi
}
# Make the block match the current settings; restart dnsmasq only if it changed.
dhcp_sync() {
    want="$(dhcp_block)"
    have="$(sed -n "/^$MARK_BEGIN\$/,/^$MARK_END\$/p" "$DNSMASQ_CONF" 2>/dev/null)"
    [ "$want" = "$have" ] && return 0
    { dhcp_strip; echo "$want"; } > "$RUN/dnsmasq.conf.new" && cat "$RUN/dnsmasq.conf.new" > "$DNSMASQ_CONF"
    rm -f "$RUN/dnsmasq.conf.new"
    dnsmasq_restart && log "dnsmasq now serves $START-$END on $BR"
}
dhcp_remove() {
    grep -q "^$MARK_BEGIN\$" "$DNSMASQ_CONF" 2>/dev/null || return 0
    dhcp_strip > "$RUN/dnsmasq.conf.new" && cat "$RUN/dnsmasq.conf.new" > "$DNSMASQ_CONF"
    rm -f "$RUN/dnsmasq.conf.new"; dnsmasq_restart
}

# ------------------------------------------------------------------ firewall
# IPv6 on the IoT network: off. Everything below is IPv4, and the IoT subnet is
# IPv4-only by design, so IPv6 must not be a way around it. disable_ipv6 makes
# the kernel ignore IPv6 arriving on the bridge (to the router or forwarded);
# the ip6tables chain is a second layer in case something re-enables it.
v6_off() {
    f="$SYS6/$BR/disable_ipv6"
    [ -f "$f" ] || return 0
    [ "$(cat "$f" 2>/dev/null)" = 1 ] && return 0
    echo 1 > "$f" 2>/dev/null && log "IPv6 disabled on $BR"
}
V6_HOOKS="INPUT:-i FORWARD:-i FORWARD:-o"      # chain:direction for the jumps
v6_firewall() {
    $IPT6 -N $CH_IOT6 2>/dev/null; $IPT6 -F $CH_IOT6
    $IPT6 -A $CH_IOT6 -j DROP
    for h in $V6_HOOKS; do
        $IPT6 -C "${h%%:*}" "${h#*:}" $BR -j $CH_IOT6 2>/dev/null ||
            $IPT6 -I "${h%%:*}" 1 "${h#*:}" $BR -j $CH_IOT6
    done
}
v6_firewall_ok() {
    # No working ip6tables on this box: nothing to check (v6_off still applies).
    $IPT6 -L INPUT -n >/dev/null 2>&1 || return 0
    $IPT6 -C $CH_IOT6 -j DROP 2>/dev/null || return 1
    for h in $V6_HOOKS; do
        $IPT6 -C "${h%%:*}" "${h#*:}" $BR -j $CH_IOT6 2>/dev/null || return 1
    done
}
v6_firewall_remove() {
    for h in $V6_HOOKS; do
        while $IPT6 -D "${h%%:*}" "${h#*:}" $BR -j $CH_IOT6 2>/dev/null; do :; done
    done
    $IPT6 -F $CH_IOT6 2>/dev/null; $IPT6 -X $CH_IOT6 2>/dev/null
}

# Bump when the rules built by firewall() change, so a running router rebuilds.
FW_VER=3
# Our chains exactly as iptables lists them, in order. firewall() saves
# this after a rebuild and firewall_ok() compares, so a missing, extra or
# reordered rule triggers a rebuild. If this iptables has no -S, both sides
# are empty and the -C checks below still apply.
fw_dump() { $IPT -S $CH_FWD 2>/dev/null; $IPT -S $CH_IN 2>/dev/null; $IPT -t nat -S $CH_NAT 2>/dev/null; $IPT6 -S $CH_IOT6 2>/dev/null; }
firewall() {
    # filter: chains are flushed and refilled, jumps added once.
    $IPT -N $CH_FWD 2>/dev/null; $IPT -F $CH_FWD
    # Home -> IoT: every home device, or only allowlisted MACs (mode "selected").
    if [ "$LAN_MODE" = selected ]; then
        for m in $LAN_ALLOW; do $IPT -A $CH_FWD -i br-lan -o $BR -m mac --mac-source "$m" -j ACCEPT; done
    else
        $IPT -A $CH_FWD -i br-lan -o $BR -j ACCEPT
    fi
    $IPT -A $CH_FWD -o $BR -m state --state ESTABLISHED,RELATED -j ACCEPT
    $IPT -A $CH_FWD -o $BR -j DROP
    # Replies from IoT to home devices only. Internet-bound packets, even of an
    # open connection, must reach the no-inet drops below, so that switching a
    # device's Internet off also cuts what it already has open.
    $IPT -A $CH_FWD -i $BR -o br+ -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Narrow IoT -> LAN exceptions: "proto:port" or "proto:port@iot-ip",
    # e.g. tcp:8899@192.168.50.10 for the inverter-link logger callback.
    for a in $ALLOW_LAN; do
        r="${a%%@*}"; src=""; [ "$r" != "$a" ] && src="-s ${a#*@}"
        $IPT -A $CH_FWD -i $BR -o br-lan $src -p "${r%%:*}" --dport "${r#*:}" -j ACCEPT
    done
    $IPT -A $CH_FWD -i $BR -o br+ -j DROP
    for m in $NOINET; do $IPT -A $CH_FWD -i $BR -m mac --mac-source "$m" -j DROP; done
    $IPT -A $CH_FWD -i $BR -j ACCEPT
    for d in "-i $BR" "-o $BR"; do
        $IPT -C FORWARD $d -j $CH_FWD 2>/dev/null || $IPT -I FORWARD 1 $d -j $CH_FWD
    done

    $IPT -N $CH_IN 2>/dev/null; $IPT -F $CH_IN
    $IPT -A $CH_IN -m state --state ESTABLISHED,RELATED -j ACCEPT
    $IPT -A $CH_IN -p udp --dport 67 -j ACCEPT
    $IPT -A $CH_IN -p udp --dport 53 -j ACCEPT
    $IPT -A $CH_IN -p tcp --dport 53 -j ACCEPT
    $IPT -A $CH_IN -p icmp -j ACCEPT
    $IPT -A $CH_IN -j DROP
    $IPT -C INPUT -i $BR -j $CH_IN 2>/dev/null || $IPT -I INPUT 1 -i $BR -j $CH_IN

    # nat: masquerade IoT traffic leaving through any non-bridge (WAN, ppp0, ...).
    $IPT -t nat -N $CH_NAT 2>/dev/null; $IPT -t nat -F $CH_NAT
    $IPT -t nat -A $CH_NAT -s "$PREFIX.0/24" ! -o br+ -j MASQUERADE
    $IPT -t nat -C POSTROUTING -j $CH_NAT 2>/dev/null || $IPT -t nat -I POSTROUTING 1 -j $CH_NAT

    v6_firewall

    # Broadcom flow cache can keep forwarding already-accelerated flows.
    command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
    echo "$FW_VER|$NOINET|$ALLOW_LAN|$LAN_MODE|$LAN_ALLOW" > "$RUN/fw.sig"
    fw_dump > "$RUN/fw.snap"
}
firewall_ok() {
    [ "$(cat "$RUN/fw.sig" 2>/dev/null)" = "$FW_VER|$NOINET|$ALLOW_LAN|$LAN_MODE|$LAN_ALLOW" ] &&
    $IPT -C FORWARD -i $BR -j $CH_FWD 2>/dev/null &&
    $IPT -C FORWARD -o $BR -j $CH_FWD 2>/dev/null &&
    $IPT -C $CH_FWD -i $BR -j ACCEPT 2>/dev/null &&
    $IPT -C INPUT -i $BR -j $CH_IN 2>/dev/null &&
    $IPT -C $CH_IN -j DROP 2>/dev/null &&
    $IPT -t nat -C POSTROUTING -j $CH_NAT 2>/dev/null &&
    $IPT -t nat -C $CH_NAT -s "$PREFIX.0/24" ! -o br+ -j MASQUERADE 2>/dev/null &&
    v6_firewall_ok &&
    [ "$(fw_dump)" = "$(cat "$RUN/fw.snap" 2>/dev/null)" ]
}
firewall_remove() {
    for d in "-i $BR" "-o $BR"; do while $IPT -D FORWARD $d -j $CH_FWD 2>/dev/null; do :; done; done
    while $IPT -D INPUT -i $BR -j $CH_IN 2>/dev/null; do :; done
    while $IPT -t nat -D POSTROUTING -j $CH_NAT 2>/dev/null; do :; done
    $IPT -F $CH_FWD 2>/dev/null; $IPT -X $CH_FWD 2>/dev/null
    $IPT -F $CH_IN 2>/dev/null; $IPT -X $CH_IN 2>/dev/null
    $IPT -t nat -F $CH_NAT 2>/dev/null; $IPT -t nat -X $CH_NAT 2>/dev/null
    v6_firewall_remove
    rm -f "$RUN/fw.sig" "$RUN/fw.snap"
}

# --------------------------------------------------------- guest speed limit
# Optional per-device speed cap for TP-Link's guest networks (iot_guest_limit=1).
# Each guest gets iot_guest_down / iot_guest_up Mbps unless its MAC is listed in
# iot_guest_fast. Limited guests are exempted from Broadcom acceleration
# (BLOGSKIP) so their packets pass through the qdiscs: download is shaped with an
# htb class per guest on the guest Wi-Fi interface, upload by redirecting the
# interface's ingress to ifb0 and shaping there. Full-speed guests keep
# acceleration. Limited guests get no IPv6 (rejected, so they fall back to IPv4
# at once): the caps match IPv4 addresses, and IPv6 would bypass them.
# The main Wi-Fi and wifi-iot are never touched.
TC="${TC:-tc}"
IPT6="${IPT6:-/usr/sbin/ip6tables -w}"
CH_GUEST6=AX10_GUEST6
IFB="${IFB:-ifb0}"
CH_GUEST=AX10_GUEST
guest_load() {
    GL_ON="$(cfg guest_limit 0)"
    GL_DOWN="$(cfg guest_down 5)"
    GL_UP="$(cfg guest_up 2)"
    GL_FAST="$(cfg guest_fast '')"
}
guest_ifs() {   # guest Wi-Fi interfaces from TP-Link's own config (wifi-iface guest=on)
    for sec in $($UCI show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.guest='\{0,1\}on'\{0,1\}$/\1/p"); do
        i="$($UCI -q get "wireless.$sec.ifname")"; [ -d "$NET/$i" ] && echo "$i"
    done
}
guest_macs() {  # every connected guest MAC
    for i in $(guest_ifs); do $WL -i "$i" assoclist 2>/dev/null | awk '{print tolower($2)}'; done
}
guest_list() {  # "mac ip ifname" for every connected guest with a known IP
    for i in $(guest_ifs); do
        for m in $($WL -i "$i" assoclist 2>/dev/null | awk '{print tolower($2)}'); do
            ip="$(awk -v m="$m" 'tolower($4)==m && $3=="0x2" {print $1; exit}' "$ARP" 2>/dev/null)"
            [ -n "$ip" ] || ip="$(awk -v m="$m" 'tolower($2)==m {print $3; exit}' "$LEASES" 2>/dev/null)"
            [ -n "$ip" ] && echo "$m $ip $i"
        done
    done
}
is_fast() { for f in $GL_FAST; do [ "$(echo "$f" | tr A-F a-f)" = "$1" ] && return 0; done; return 1; }
guest_clear() {
    for i in $(guest_ifs); do
        $TC qdisc del dev "$i" root 2>/dev/null; $TC qdisc del dev "$i" ingress 2>/dev/null
    done
    $TC qdisc del dev "$IFB" root 2>/dev/null
    while $IPT -t mangle -D PREROUTING -j $CH_GUEST 2>/dev/null; do :; done
    while $IPT -t mangle -D FORWARD -j $CH_GUEST 2>/dev/null; do :; done
    $IPT -t mangle -F $CH_GUEST 2>/dev/null; $IPT -t mangle -X $CH_GUEST 2>/dev/null
    while $IPT6 -D FORWARD -j $CH_GUEST6 2>/dev/null; do :; done
    $IPT6 -F $CH_GUEST6 2>/dev/null; $IPT6 -X $CH_GUEST6 2>/dev/null
}
guest_sync() {
    guest_load
    if [ "$GL_ON" != 1 ]; then
        [ -f "$RUN/guest.sig" ] && { guest_clear; rm -f "$RUN/guest.sig"; log "guest speed limit off"; }
        return 0
    fi
    list="$(guest_list)"
    slow="$(echo "$list" | while read m ip i; do [ -n "$m" ] && ! is_fast "$m" && echo "$m $ip $i"; done)"
    slow6="$(guest_macs | while read m; do [ -n "$m" ] && ! is_fast "$m" && echo "$m"; done | sort -u | tr '\n' ' ')"
    sig="$GL_DOWN|$GL_UP|$slow|$slow6"
    [ "$(cat "$RUN/guest.sig" 2>/dev/null)" = "$sig" ] && $IPT -t mangle -C PREROUTING -j $CH_GUEST 2>/dev/null &&
        $IPT -t mangle -C FORWARD -j $CH_GUEST 2>/dev/null && $IPT6 -C FORWARD -j $CH_GUEST6 2>/dev/null && return 0
    guest_clear
    lsmod 2>/dev/null | grep -q '^xt_BLOGSKIP' || insmod /lib/modules/iplatform/xt_BLOGSKIP.ko 2>/dev/null
    $IPT -t mangle -N $CH_GUEST 2>/dev/null
    # PREROUTING sees uploads; downloads only carry the guest's address after
    # de-NAT, so the same chain is also hooked into FORWARD.
    $IPT -t mangle -I PREROUTING 1 -j $CH_GUEST
    $IPT -t mangle -I FORWARD 1 -j $CH_GUEST
    # No IPv6 for limited guests; ahead of the stock "accept established" rule.
    $IPT6 -N $CH_GUEST6 2>/dev/null
    $IPT6 -I FORWARD 1 -j $CH_GUEST6
    for m in $slow6; do $IPT6 -A $CH_GUEST6 -m mac --mac-source "$m" -j REJECT --reject-with icmp6-adm-prohibited; done
    $IP link set "$IFB" up 2>/dev/null
    $TC qdisc add dev "$IFB" root handle 1: htb default 1
    $TC class add dev "$IFB" parent 1: classid 1:1 htb rate 1000mbit
    for i in $(guest_ifs); do
        $TC qdisc add dev "$i" root handle 1: htb default 1
        $TC class add dev "$i" parent 1: classid 1:1 htb rate 1000mbit
        $TC qdisc add dev "$i" ingress
    done
    QD=$((GL_DOWN * 2)); [ "$QD" -ge 5 ] || QD=5
    QU=$((GL_UP * 2)); [ "$QU" -ge 5 ] || QU=5
    n=10
    echo "$slow" | while read m ip i; do
        [ -n "$m" ] || continue
        $IPT -t mangle -A $CH_GUEST -s "$ip" -j BLOGSKIP
        $IPT -t mangle -A $CH_GUEST -d "$ip" -j BLOGSKIP
        # Short leaf queues: the default (txqueuelen 1000) adds seconds of delay at
        # a few Mbps, and there is no fq_codel/sfq in this kernel. Size each queue
        # to ~25 ms at the cap (2 full-size packets per Mbps, at least 5).
        $TC class add dev "$i" parent 1: classid 1:$n htb rate "${GL_DOWN}mbit" ceil "${GL_DOWN}mbit"
        $TC qdisc add dev "$i" parent 1:$n handle $n: pfifo limit "$QD"
        $TC filter add dev "$i" parent 1: protocol ip prio 1 u32 match ip dst "$ip/32" flowid 1:$n
        $TC filter add dev "$i" parent ffff: protocol ip prio 1 u32 match ip src "$ip/32" action mirred egress redirect dev "$IFB"
        $TC class add dev "$IFB" parent 1: classid 1:$n htb rate "${GL_UP}mbit" ceil "${GL_UP}mbit"
        $TC qdisc add dev "$IFB" parent 1:$n handle $n: pfifo limit "$QU"
        $TC filter add dev "$IFB" parent 1: protocol ip prio 1 u32 match ip src "$ip/32" flowid 1:$n
        n=$((n + 1))
    done
    command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
    echo "$sig" > "$RUN/guest.sig"
    log "guest speed limit: $(echo "$slow" | grep -c .) guest(s) at ${GL_DOWN}/${GL_UP} Mbps, IPv6 off for $(echo $slow6 | wc -w)"
}

# --------------------------------------------------------------- apply/stop
# One pass. Returns 0 when everything is in place.
apply() {
    load; mkdir -p "$RUN"
    [ -n "$SSID" ] || { log "iot_ssid not set"; return 1; }
    [ ${#KEY} -ge 8 ] || { log "iot_key must be at least 8 characters"; return 1; }

    [ -d "$NET/$BR" ] || { $BRCTL addbr $BR && log "created $BR"; }
    cur="$(bridge_of "$VIF")"
    if [ "$cur" != "$BR" ]; then
        [ -n "$cur" ] && $BRCTL delif "$cur" "$VIF"
        $BRCTL addif $BR "$VIF" && log "moved $VIF from ${cur:-none} to $BR"
        [ -s "$RUN/orig_bridge" ] || echo "${cur:-br-lan}" > "$RUN/orig_bridge"
    fi
    $IP addr show dev $BR 2>/dev/null | grep -q "inet $GW/24" || {
        $IP addr flush dev $BR 2>/dev/null
        $IP addr add "$GW/24" dev $BR && log "address $GW/24 on $BR"
    }
    $IP link set $BR up
    v6_off

    vif_flags_ok || { wifi_patch && radio_rebuild; }
    vif_flags_ok || log "$VIF still has mesh flags (dwds=$($WL -i "$VIF" dwds 2>/dev/null))"
    vif_sync
    wds_guard
    brfilter_sync
    firewall_ok || { firewall; log "firewall (re)applied"; }
    dhcp_sync
}

stop() {
    load
    inittab_del
    dhcp_remove
    firewall_remove
    orig="$(cat "$RUN/orig_bridge" 2>/dev/null)"; orig="${orig:-br-lan}"
    vif_release
    if [ "$(bridge_of "$VIF")" = "$BR" ]; then
        $BRCTL delif $BR "$VIF"
        $BRCTL addif "$orig" "$VIF"
    fi
    for p in "$NET"/wds"${VIF#wl}".*; do
        [ -e "$p" ] || continue; w="${p##*/}"
        [ "$(bridge_of "$w")" = "$BR" ] && { $BRCTL delif $BR "$w"; $BRCTL addif "$orig" "$w"; }
    done
    $IP link set $BR down 2>/dev/null; $BRCTL delbr $BR 2>/dev/null
    rm -f "$RUN/orig_bridge"
    wifi_unpatch
    vif_flags_ok && radio_set_flags 1 3     # give TP-Link its OneMesh config slot back
    brfilter_restore
    log "stopped; $VIF returned to $orig"
}

# busybox-init respawn supervision (same approach as ax10-svc; the stock inittab's
# last line has no trailing newline, so rebuild through grep).
TAG="ax10-iot-watch"
inittab_add() {
    { grep -v "$TAG" "$INITTAB" 2>/dev/null; echo "::respawn:/bin/sh $SELF watch # $TAG"; } > "$INITTAB.new"
    cat "$INITTAB.new" > "$INITTAB"; rm -f "$INITTAB.new"; $INIT_HUP 2>/dev/null
}
# A running watcher keeps the functions it loaded at start; after iot.sh is
# replaced on disk, kill it so init respawns it with the new code.
watcher_restart() {
    for d in /proc/[0-9]*; do
        [ "${d#/proc/}" = "$$" ] && continue
        case "$( { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null)" in *"$SELF watch"*) kill "${d#/proc/}" 2>/dev/null;; esac
    done
}
inittab_del() {
    grep -q "$TAG" "$INITTAB" 2>/dev/null || return 0
    grep -v "$TAG" "$INITTAB" > "$INITTAB.new"; cat "$INITTAB.new" > "$INITTAB"; rm -f "$INITTAB.new"
    $INIT_HUP 2>/dev/null
    for d in /proc/[0-9]*; do
        [ "${d#/proc/}" = "$$" ] && continue
        case "$( { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null)" in *"$SELF watch"*) kill "${d#/proc/}" 2>/dev/null;; esac
    done
}

# ------------------------------------------------------------- stock web UI
# The UI lives on the read-only squashfs. Copy the few directories we touch into
# RAM, add our files, and bind-mount the copies over the originals. Gone on reboot;
# `iot.sh boot` puts them back.
WWW="${WWW:-/www/webpages}"
LUCI_CTL="${LUCI_CTL:-/usr/lib/lua/luci/controller/admin}"
UI_SRC="$RUN/ui"
OV="$RUN/overlay"
UI_VER=iot4
mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }
overlay() {   # overlay <dir> <name>: bind a writable RAM copy over <dir>, echo the copy's path
    if ! mounted "$1"; then
        rm -rf "$OV/$2"; mkdir -p "$OV"
        cp -a "$1" "$OV/$2" && $MOUNT --bind "$OV/$2" "$1" || return 1
    fi
    echo "$1"
}
# The boot hook leaves the release public key here; when present, downloads must
# carry a valid signature (see boot.sh).
SIGN_PUB="${SIGN_PUB:-/tmp/archer-sign.pub}"
ui_fetch() {
    [ -f "$UI_SRC/iot_net.lua" ] && return 0
    mkdir -p "$UI_SRC"
    curl -4 -L -k -fs -m 60 "$SRC/iot-ui.tar.gz" -o "$RUN/iot-ui.tgz" || return 1
    if [ -s "$SIGN_PUB" ]; then
        curl -4 -L -k -fs -m 30 "$SRC/iot-ui.tar.gz.sig" -o "$RUN/iot-ui.tgz.sig" &&
            openssl dgst -sha256 -verify "$SIGN_PUB" -signature "$RUN/iot-ui.tgz.sig" "$RUN/iot-ui.tgz" >/dev/null 2>&1 ||
            { log "iot-ui.tar.gz: signature check failed, not installing"; rm -f "$RUN/iot-ui.tgz"*; return 1; }
    fi
    gzip -dc "$RUN/iot-ui.tgz" | tar xf - -C "$UI_SRC" && rm -f "$RUN/iot-ui.tgz"*
}
# In-place sed without sed's -i flag (its syntax differs between busybox/GNU and BSD).
sed_in() { sed "$1" "$2" > "$2.new" && cat "$2.new" > "$2"; rm -f "$2.new"; }   # sed_in <script> <file>
ui_install() {
    ui_fetch || { log "could not fetch iot-ui"; return 1; }
    ctl="$(overlay "$LUCI_CTL" luci-ctl)" || return 1
    cp "$UI_SRC/iot_net.lua" "$ctl/iot_net.lua"; chmod 644 "$ctl/iot_net.lua"
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

    w="$(overlay "$WWW/modules/advanced/wireless" wireless)" || return 1
    for m in iotNetwork guestSpeed; do
        rm -rf "$w/$m"; cp -a "$UI_SRC/$m" "$w/$m"; chmod -R a+rX "$w/$m"
    done

    c="$(overlay "$WWW/config" config)" || return 1
    grep -q '"iotNetwork"' "$c/navigator.json" ||
        sed_in 's/{"name":"guestNetworkAdv","text":"GUEST_NETWORK"}/&,{"name":"iotNetwork","text":"IOT_NETWORK"}/' "$c/navigator.json"
    grep -q '"guestSpeed"' "$c/navigator.json" ||
        sed_in 's/{"name":"guestNetworkAdv","text":"GUEST_NETWORK"}/&,{"name":"guestSpeed","text":"GUEST_SPEED"}/' "$c/navigator.json"
    # (Re)register the module; the ?t= version makes browsers fetch updated files.
    for m in iotNetwork guestSpeed; do
        grep -q "$m/script.js?t=$UI_VER\"" "$c/modules.json" && continue
        sed_in "s#\"$m\":{[^}]*},##" "$c/modules.json"
        sed_in "1s#^{#{\"$m\":{\"controller\":\"./modules/advanced/wireless/$m/script.js?t=$UI_VER\",\"view\":\"./modules/advanced/wireless/$m/view.html?t=$UI_VER\"},#" "$c/modules.json"
    done

    lang="$($UCI -q get locale.sysinfo.locale)"; lang="${lang:-en_US}"
    [ -f "$WWW/locale/$lang/lan.js" ] || lang=en_US
    l="$(overlay "$WWW/locale/$lang" "locale-$lang")" || return 1
    # Replace our labels line (it starts with ;$.su.CHAR.MENU_ITEMS_NAME.IOT_NETWORK).
    if ! grep -qF "$(cat "$UI_SRC/locale.js")" "$l/lan.js"; then
        grep -v '^;\$\.su\.CHAR\.MENU_ITEMS_NAME\.IOT_NETWORK' "$l/lan.js" > "$l/lan.js.new"
        { echo; cat "$UI_SRC/locale.js"; } >> "$l/lan.js.new"; cat "$l/lan.js.new" > "$l/lan.js"; rm -f "$l/lan.js.new"
    fi
    log "web UI pages installed (Advanced > Wireless > IoT Network, Guest Speed)"
}
ui_remove() {
    for d in "$LUCI_CTL" "$WWW/modules/advanced/wireless" "$WWW/config" "$WWW"/locale/*; do
        mounted "$d" && $UMOUNT "$d"
    done
    rm -rf "$OV" /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
    log "web UI page removed"
}

# Keep boot.sh's SSH lifeline alive: if it is gone, start it again the same way
# boot.sh does, and log it (the log tells us what killed it).
LIFELINE_BIN="${LIFELINE_BIN:-/tmp/dropbear_vanilla}"
LIFELINE_PID="${LIFELINE_PID:-/tmp/archer-boot-ssh-2222.pid}"
lifeline_guard() {
    [ -x "$LIFELINE_BIN" ] || return 0
    p="$(cat "$LIFELINE_PID" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
    lan="$($UCI -q get network.lan.ipaddr)"; [ -n "$lan" ] || return 0
    k=""; [ -s /tmp/archer-boot-host.key ] && k="-r /tmp/archer-boot-host.key"
    "$LIFELINE_BIN" -p "$lan:2222" -P "$LIFELINE_PID" $k -R -E </dev/null >/dev/null 2>&1 &
    log "SSH lifeline was not running; restarted it"
}

status() {
    load
    echo "enabled:   $(cfg enabled 0)"
    echo "ssid:      ${SSID:-<unset>}$([ "$HIDDEN" = 1 ] && echo ' (hidden)')"
    echo "wifi slot: $VIF  bridge=$(bridge_of "$VIF")  live-ssid='$(live_ssid)'  bss=$($WL -i "$VIF" bss 2>/dev/null)"
    echo "br-filter: deny_all=[$(cat "$BRF/deny_all" 2>/dev/null)]"
    echo "mesh flags: dwds=$($WL -i "$VIF" dwds 2>/dev/null) map=$($WL -i "$VIF" map 2>/dev/null | cut -c1-3)  wifi-script patched: $(grep -q " $WIFI_SH " /proc/mounts 2>/dev/null && echo yes || echo no)"
    echo "subnet:    $GW/24  dhcp $START-$END  dns $DNS"
    echo "no-inet:   ${NOINET:-none}"
    echo "static:    ${STATIC:-none}"
    echo "allow-lan: ${ALLOW_LAN:-none}"
    echo "home->iot: $LAN_MODE$([ "$LAN_MODE" = selected ] && echo " (${LAN_ALLOW:-nobody})")"
    firewall_ok && echo "firewall:  ok" || echo "firewall:  MISSING/outdated"
    grep -q "^$MARK_BEGIN\$" "$DNSMASQ_CONF" 2>/dev/null && echo "dhcp:      dnsmasq block present" || echo "dhcp:      MISSING"
    grep -q "$TAG" "$INITTAB" 2>/dev/null && echo "watcher:   registered" || echo "watcher:   not registered"
    mounted "$LUCI_CTL" && echo "web page:  installed" || echo "web page:  not installed"
    echo "--- IoT leases"; grep " $PREFIX\." "$LEASES" 2>/dev/null | awk '{print $2, $3, $4}'
    [ -f "$LOG" ] && { echo "--- last log lines"; tail -n 8 "$LOG"; }
}

# Commands that change the router take the lock for their whole run.
case "$1" in
    apply|start|stop|guest|ui|ui-remove|boot)
        lock || { log "$1: another iot.sh run still holds the lock; gave up after ${LOCK_WAIT}s"
                  echo "iot.sh: another run is in progress; try again" >&2; exit 1; }
        trap unlock EXIT ;;
esac

case "$1" in
    apply) apply ;;
    watch)
        while :; do
            if lock 5; then
                apply >/dev/null 2>&1
                guest_sync >/dev/null 2>&1
                unlock
            fi
            lifeline_guard
            trim_log
            sleep "${INTERVAL:-15}"
        done ;;
    start)
        [ "$0" = "$SELF" ] || cp "$0" "$SELF" 2>/dev/null
        apply; guest_sync; inittab_add; watcher_restart; log "watcher registered" ;;
    stop) stop; guest_clear; rm -f "$RUN/guest.sig" ;;
    guest) guest_sync; guest_load; echo "guest limit: $GL_ON  ${GL_DOWN}/${GL_UP} Mbps  full-speed: ${GL_FAST:-none}"; guest_list ;;
    ui) [ "$0" = "$SELF" ] || cp "$0" "$SELF" 2>/dev/null; ui_install; watcher_restart ;;
    ui-remove) ui_remove ;;
    boot)
        [ "$0" = "$SELF" ] || cp "$0" "$SELF" 2>/dev/null
        ui_install
        # In-process, not "$0 start": the fetched file is not executable.
        [ "$(cfg enabled 0)" = 1 ] && { apply; guest_sync; inittab_add; log "watcher registered"; }
        lifeline_guard ;;
    status) status ;;
    set)
        [ -n "$2" ] || { echo "usage: iot.sh set <key> <value>" >&2; exit 1; }
        k="${2#iot_}"
        # /etc is ramfs: plain `uci commit` is lost on reboot. TP-Link's uci_commit_flash
        # goes through its patched luci.model.uci, which also writes the config to flash.
        $UCI set "$SEC.iot_$k=$3" || exit 1
        if [ -x "${COMMIT_FLASH:-/sbin/uci_commit_flash}" ]; then "${COMMIT_FLASH:-/sbin/uci_commit_flash}" openvpn
        else $UCI commit openvpn; fi && echo "saved iot_$k" ;;
    *) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
