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
#   iot.sh shape      apply + show the speed limits (per device, guests, whole connection)
#   iot.sh open [s]   with the lock on, let new devices join for s seconds (default 600)
#   iot.sh close      end that window now
#   iot.sh home       apply + show the home allow list (iot_home_lock, iot_home_allow)
#   iot.sh home-open [s]  let new home devices in for s seconds; they are added
#   iot.sh home-close     end that window now
#   iot.sh home-allow add|remove|keep|unkeep <mac>   edit the list (under the lock)
#   iot.sh home-set lock 0|1 / home-set expire <days>
#   iot.sh forget <mac>   drop an IoT device's fixed address (not re-pinned from its lease)
#   iot.sh set caps "aa:bb:cc:dd:ee:03=5/2"   cap a device at 5 Mbps down, 2 up
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
            # Holder is gone. Take its lock over, one waiter at a time ($LOCK.gc):
            # two waiters that both saw the dead holder must not both remove a
            # lock, or the second removes the one the first has just taken.
            if mkdir "$LOCK.gc" 2>/dev/null; then
                [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$p" ] && rm -rf "$LOCK"
                rmdir "$LOCK.gc"
            else
                # Another waiter is taking it over; a .gc left by a dead waiter goes at the end of the wait.
                [ "$w" -le 0 ] && rmdir "$LOCK.gc" 2>/dev/null
                w=$((w - 1)); sleep 1
            fi
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
    $WL -i "$VIF" macmode 0 2>/dev/null; $WL -i "$VIF" mac none 2>/dev/null
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
# ------------------------------------------------------------ known devices
# Every IoT device keeps its address: each pass pins new IoT leases into iot_static.
# Lock (iot_lock=1): only pinned devices may join the IoT Wi-Fi (Broadcom MAC allow
# list, macmode 2), and unknown ones already connected are dropped. `iot.sh open`
# lets new devices join for a while; they are pinned as they get an address.
commit_cfg() {   # /etc is ramfs: TP-Link's uci_commit_flash also writes flash
    if [ -x "${COMMIT_FLASH:-/sbin/uci_commit_flash}" ]; then "${COMMIT_FLASH:-/sbin/uci_commit_flash}" openvpn
    else $UCI commit openvpn; fi
}
# Devices removed with "Forget" (iot_forget) are not pinned again from their old
# lease; only the "allow new devices" window takes them back.
autopin() {
    [ -f "$LEASES" ] || return 0
    new=""; back=""; forget="$(cfg forget '' | tr A-F a-f)"
    while read -r _exp mac ip _rest; do
        case "$ip" in "$PREFIX".*) ;; *) continue ;; esac
        mac="$(echo "$mac" | tr A-F a-f)"
        case " $STATIC $new " in *" $mac,"*) continue ;; esac
        case " $forget " in *" $mac "*) lock_open || continue; back="$back $mac" ;; esac
        new="$new $mac,$ip"
    done < "$LEASES"
    [ -n "$new" ] || return 0
    STATIC="$(echo $STATIC $new)"
    $UCI set "$SEC.iot_static=$STATIC"
    if [ -n "$back" ]; then
        f=""; for m in $forget; do case " $back " in *" $m "*) ;; *) f="$f $m" ;; esac; done
        $UCI set "$SEC.iot_forget=$(echo $f)"
    fi
    commit_cfg >/dev/null
    log "fixed address for new IoT device(s):$new"
}
known_macs() { for s in $STATIC; do echo "${s%%,*}"; done | tr a-f A-F | sort | tr '\n' ' '; }
now_s() { if [ -r /proc/uptime ]; then cut -d. -f1 /proc/uptime; else date +%s; fi; }   # seconds since boot
lock_open() {    # is the "allow new devices" window open?
    u="$(cat "$RUN/open_until" 2>/dev/null)"
    [ -n "$u" ] && [ "$(now_s)" -lt "$u" ] 2>/dev/null
}
lock_sync() {
    [ -d "$NET/$VIF" ] || return 0
    if [ "$(cfg lock 0)" = 1 ] && ! lock_open; then
        want="$(known_macs)"
        have="$($WL -i "$VIF" mac 2>/dev/null | awk '{print toupper($2)}' | sort | tr '\n' ' ')"
        if [ "$want" != "$have" ]; then
            $WL -i "$VIF" mac none 2>/dev/null
            [ -n "$want" ] && $WL -i "$VIF" mac $want
        fi
        if [ "$($WL -i "$VIF" macmode 2>/dev/null)" != 2 ]; then
            $WL -i "$VIF" macmode 2
            log "IoT network locked to $(echo $want | wc -w) known device(s)"
        fi
        for m in $($WL -i "$VIF" assoclist 2>/dev/null | awk '{print toupper($2)}'); do
            case " $want " in *" $m "*) ;; *) $WL -i "$VIF" deauthenticate "$m" 2>/dev/null; log "removed unknown device $m from the IoT network" ;; esac
        done
    elif [ "$($WL -i "$VIF" macmode 2>/dev/null)" = 2 ]; then
        $WL -i "$VIF" macmode 0
        log "IoT network open to new devices"
    fi
}
# ------------------------------------------------------------- home allow list
# Our own allow list for the home network (TP-Link's Access Control stays off; its
# guest exemption needs a firewall match this kernel lacks). Two layers:
#   - the home Wi-Fi radios (iot_home_ifs, default wl0.1 wl1.1) take only listed
#     MACs (wl macmode 2), and unlisted devices already on them are disconnected;
#   - devices the radios can't see (behind the mesh satellite, or wired) are dropped
#     in the raw table by MAC once TP-Link's client list shows them as home clients.
#     Only listed-as-client MACs are dropped, so guests on the same bridge and the
#     satellite's own radios are never caught.
# `iot.sh home-open [s]` lets new devices in for a while; they are added as they show
# up. Last-seen times are kept in RAM and saved to flash once a day; with
# iot_home_expire=N, entries not seen for N days are removed (iot_home_keep never).
CH_HOME=AX10_HOME
home_load() {
    H_LOCK="$(cfg home_lock 0)"
    H_ALLOW="$(cfg home_allow '' | tr A-F a-f)"
    H_KEEP="$(cfg home_keep '' | tr A-F a-f)"
    H_EXPIRE="$(cfg home_expire 0)"
    H_IFS=""; for i in $(cfg home_ifs 'wl0.1 wl1.1'); do [ -d "$NET/$i" ] && H_IFS="$H_IFS $i"; done
}
home_listed() { case " $H_ALLOW $H_KEEP " in *" $1 "*) return 0 ;; esac; return 1; }
home_open_now() { u="$(cat "$RUN/home_open_until" 2>/dev/null)"; [ -n "$u" ] && [ "$(now_s)" -lt "$u" ] 2>/dev/null; }
home_clients() {   # home devices connected now: on our home radios, or TP-Link's client list (non-guest)
    for i in $H_IFS; do $WL -i "$i" assoclist 2>/dev/null | awk '{print tolower($2)}'; done
    [ -f "$CLIENTS" ] && tr '{' '\n' < "$CLIENTS" | grep '"guest":"NON_GUEST"' | grep '"connect_status":1' |
        sed -n 's/.*"mac":"\([0-9A-Fa-f-]*\)".*/\1/p' | tr 'A-F-' 'a-f:'
}
# Forget last-seen times, so a re-added device starts a fresh clock. Also in the saved
# copy (the caller commits), so a reboot can't bring the old time back.
sed_seen_del() {
    if [ -f "$RUN/home_seen" ]; then
        for m in "$@"; do grep -v "^$m " "$RUN/home_seen" > "$RUN/home_seen.new"; mv "$RUN/home_seen.new" "$RUN/home_seen"; done
    fi
    v=""; for e in $(cfg home_seen ''); do case " $* " in *" ${e%%=*} "*) ;; *) v="$v $e" ;; esac; done
    $UCI set "$SEC.iot_home_seen=$(echo $v)"
}
home_save_allow() { $UCI set "$SEC.iot_home_allow=$(echo $H_ALLOW)" && commit_cfg >/dev/null; }
epoch() { d="$(date +%s 2>/dev/null)"; [ "${d:-0}" -gt 1700000000 ] 2>/dev/null && echo "$d"; }   # empty until NTP has set the clock
home_seen_sync() {   # home_seen_sync <connected macs>
    now="$(epoch)"; [ -n "$now" ] || return 0
    f="$RUN/home_seen"
    [ -f "$f" ] || for e in $(cfg home_seen ''); do echo "${e%%=*} ${e#*=}"; done > "$f"
    { for m in $1; do echo "$m $now"; done
      for m in $H_ALLOW; do grep -q "^$m " "$f" || echo "$m $now"; done   # first sight starts the clock
      cat "$f"; } | sort -k1,1 -k2,2nr | awk '!s[$1]++' > "$f.new" && mv "$f.new" "$f"
    # Expire entries not seen for H_EXPIRE days.
    if [ "$H_EXPIRE" -gt 0 ] 2>/dev/null; then
        old=""; for m in $H_ALLOW; do
            case " $H_KEEP " in *" $m "*) continue ;; esac
            t="$(awk -v m="$m" '$1==m{print $2}' "$f")"
            [ -n "$t" ] && [ $((now - t)) -gt $((H_EXPIRE * 86400)) ] && old="$old $m"
        done
        new=""; for m in $H_ALLOW; do case " $old " in *" $m "*) ;; *) new="$new $m" ;; esac; done
        # Never expire the list down to nothing: that would leave the lock with no one on it.
        [ -z "$(echo $new $H_KEEP)" ] && old=""
        if [ -n "$old" ]; then
            H_ALLOW="$(echo $new)"; sed_seen_del $old; home_save_allow
            log "removed from the home allow list after $H_EXPIRE days unseen:$old"
        fi
    fi
    # Save to flash once a day.
    last="$(cat "$RUN/home_seen.saved" 2>/dev/null)"
    if [ $((now - ${last:-0})) -gt 86400 ]; then
        $UCI set "$SEC.iot_home_seen=$(awk '{printf "%s=%s ", $1, $2}' "$f" | sed 's/ $//')" && commit_cfg >/dev/null
        echo "$now" > "$RUN/home_seen.saved"
    fi
}
# Open the home radios again, but only the ones we locked (home_owned): a filter
# TP-Link or someone else set is left alone.
home_unlock() {
    for i in $(cat "$RUN/home_owned" 2>/dev/null); do
        [ "$($WL -i "$i" macmode 2>/dev/null)" = 2 ] && { $WL -i "$i" macmode 0; log "home Wi-Fi ($i) open to any device${1:+ ($1)}"; }
    done
    rm -f "$RUN/home_owned"
    home_fw_clear
}
home_fw_clear() {
    for t in "$IPT" "$IPT6"; do
        while $t -t raw -D PREROUTING -i "$LANBR" -j $CH_HOME 2>/dev/null; do :; done
        $t -t raw -F $CH_HOME 2>/dev/null; $t -t raw -X $CH_HOME 2>/dev/null
    done
}
home_sync() { home_sync_lists; portal_sync; }
home_sync_lists() {
    home_load; mkdir -p "$RUN"
    conn="$(home_clients | sort -u | tr '\n' ' ')"
    home_seen_sync "$conn"
    [ "$H_LOCK" = 1 ] || { home_unlock; return 0; }
    if home_open_now; then
        g=" $(guest_macs | sort -u | tr '\n' ' ') "
        new=""; for m in $conn; do home_listed "$m" || case "$g" in *" $m "*) ;; *) new="$new $m" ;; esac; done
        if [ -n "$new" ]; then H_ALLOW="$(echo $H_ALLOW $new)"; sed_seen_del $new; home_save_allow; log "added to the home allow list:$new"; fi
        home_unlock "window open"; return 0
    fi
    # On with an empty list would lock out everyone, including whoever manages it.
    if [ -z "$(echo $H_ALLOW $H_KEEP)" ]; then home_unlock "the allow list is empty"; return 0; fi
    want="$(echo $H_ALLOW $H_KEEP | tr ' ' '\n' | tr a-f A-F | sort -u | tr '\n' ' ')"
    for i in $H_IFS; do
        have="$($WL -i "$i" mac 2>/dev/null | awk '{print toupper($2)}' | sort | tr '\n' ' ')"
        [ "$want" = "$have" ] || { $WL -i "$i" mac none 2>/dev/null; $WL -i "$i" mac $want; }
        [ "$($WL -i "$i" macmode 2>/dev/null)" = 2 ] || { $WL -i "$i" macmode 2; log "home Wi-Fi ($i) locked to $(echo $want | wc -w) device(s)"; }
        grep -qx "$i" "$RUN/home_owned" 2>/dev/null || echo "$i" >> "$RUN/home_owned"
        for m in $($WL -i "$i" assoclist 2>/dev/null | awk '{print toupper($2)}'); do
            case " $want " in *" $m "*) ;; *) $WL -i "$i" deauthenticate "$m" 2>/dev/null; log "removed unlisted device $m from the home Wi-Fi ($i)" ;; esac
        done
    done
    # Devices behind the satellite or wired: drop unlisted home clients by MAC.
    # A MAC stays dropped once seen (it vanishes from the client list when cut off),
    # until it is listed or shows up on the guest Wi-Fi: guests are never dropped.
    g=" $(guest_macs | sort -u | tr '\n' ' ') "
    drop="$(cat "$RUN/home_drop" 2>/dev/null)"
    for m in $conn; do drop="$drop $m"; done
    keep=""; for m in $drop; do
        home_listed "$m" && continue
        case "$g" in *" $m "*) continue ;; esac
        case " $keep " in *" $m "*) ;; *) keep="$keep $m" ;; esac
    done
    drop="$(echo $keep)"; echo "$drop" > "$RUN/home_drop"
    for t in "$IPT" "$IPT6"; do
        $t -t raw -N $CH_HOME 2>/dev/null
        $t -t raw -C PREROUTING -i "$LANBR" -j $CH_HOME 2>/dev/null || $t -t raw -I PREROUTING 1 -i "$LANBR" -j $CH_HOME
        w="$(echo $drop | tr ' ' '\n' | tr a-f A-F | sort | tr '\n' ' ')"
        h="$($t -t raw -S $CH_HOME 2>/dev/null | sed -n 's/.*--mac-source \([^ ]*\).*/\1/p' | tr a-f A-F | sort | tr '\n' ' ')"
        [ "$w" = "$h" ] && continue
        $t -t raw -F $CH_HOME
        for m in $drop; do $t -t raw -A $CH_HOME -m mac --mac-source "$m" -j DROP; done
        [ "$t" = "$IPT" ] && [ -n "$drop" ] && log "home network: dropping unlisted device(s) $drop"
        flush=1
    done
    # Accelerated (Broadcom flow cache) connections skip netfilter: drop them so the
    # new rules apply to connections already open.
    [ -n "$flush" ] && command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
    flush=""
}
# Change the list or settings under the run lock, so the watcher and the dashboard
# never write from stale copies. home_edit <add|remove|keep|unkeep> <mac>
home_edit() {
    mac="$(echo "$2" | tr A-F- a-f:)"
    echo "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || { echo "iot.sh: bad MAC '$2'" >&2; return 1; }
    home_load; a=""; k=""
    for m in $H_ALLOW; do [ "$m" = "$mac" ] || a="$a $m"; done
    for m in $H_KEEP; do [ "$m" = "$mac" ] || k="$k $m"; done
    was_keep=0; case " $H_KEEP " in *" $mac "*) was_keep=1 ;; esac
    case "$1" in
        add) a="$a $mac"; [ "$was_keep" = 1 ] && k="$k $mac" ;;
        keep) a="$a $mac"; k="$k $mac" ;;
        unkeep) a="$a $mac" ;;
        remove) ;;
        *) echo "iot.sh: home-allow add|remove|keep|unkeep <mac>" >&2; return 1 ;;
    esac
    if [ "$1" = remove ] && [ "$H_LOCK" = 1 ] && [ -z "$(echo $a $k)" ]; then
        echo "iot.sh: that is the last device on the list; turn the lock off instead" >&2; return 1
    fi
    $UCI set "$SEC.iot_home_allow=$(echo $a)"; $UCI set "$SEC.iot_home_keep=$(echo $k)"
    case "$1" in add|keep|remove) sed_seen_del "$mac" ;; esac
    commit_cfg >/dev/null
    log "home allow list: $1 $mac"
}
home_set() {   # home_set <lock|expire> <value>
    home_load
    case "$1" in
        lock) case "$2" in 0|1) ;; *) return 1 ;; esac
              if [ "$2" = 1 ] && [ -z "$(echo $H_ALLOW $H_KEEP)" ]; then echo "iot.sh: the allow list is empty" >&2; return 1; fi ;;
        expire) case "$2" in ''|*[!0-9]*) return 1 ;; esac ;;
        *) return 1 ;;
    esac
    $UCI set "$SEC.iot_home_$1=$2" && commit_cfg >/dev/null
    log "home allow list: $1 = $2"
}
# ------------------------------------------------------------- join-home page
# A device on the home allow list that connects to the guest Wi-Fi gets no internet
# there: its web requests go to a page on the router with the home Wi-Fi name,
# password and a QR code. It ends by itself once the device leaves the guest Wi-Fi.
# The standard captive-portal way, for those devices only:
#   - DNS (udp 53, redirected to PORTAL_DNS) answers every name with the router's
#     IPv4 address and no IPv6 answers; DNS over IPv6 to the router is refused, so
#     the phone falls back to IPv4;
#   - HTTP (tcp 80, redirected to PORTAL_PORT) gets "302 Found" to the page, so the
#     phone's captive-network check (captive.apple.com, connectivitycheck...) fails
#     and it opens its sign-in sheet;
#   - HTTPS to the router is reset at once (no stock-admin certificate warning);
#   - everything else is rejected (no internet), IPv4 and IPv6.
# One small Lua process serves both (a second uhttpd can't start: TP-Link's build
# registers a fixed ubus object). Only those devices can reach it: the page shows
# the home password.
CH_PORTAL=AX10_PORTAL; CH_PORTAL_IN=AX10_PORTAL_IN; CH_PORTAL_NAT=AX10_PORTAL_NAT
PORTAL_PORT="${PORTAL_PORT:-8081}"
PORTAL_DNS="${PORTAL_DNS:-5354}"
CH_PORTAL_IN6=AX10_PORTAL_IN6
LUA="${LUA:-/usr/bin/lua}"
PORTAL="$RUN/portal"
html_esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'"; s/'/\\&#39;/g"; }
portal_page() {
    sec="$(cfg home_wifi wl03)"
    ssid="$($UCI -q get "wireless.$sec.ssid")"; key="$($UCI -q get "wireless.$sec.psk_key")"
    [ -n "$ssid" ] || { log "join-home page: no SSID in wireless.$sec"; return 1; }
    mkdir -p "$PORTAL"
    for f in jquery.min.js jquery.qrcode.min.js; do [ -f "$PORTAL/$f" ] || cp "$WWW/js/libs/$f" "$PORTAL/$f" 2>/dev/null; done
    es="$(printf '%s' "$ssid" | html_esc)"; ek="$(printf '%s' "$key" | html_esc)"
    cat > "$PORTAL/index.html.new" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Join the home Wi-Fi</title>
<style>
:root{color-scheme:light dark;--bg:#f6f7f9;--card:#fff;--ink:#14181f;--muted:#5b6472;--line:#e3e6eb;--accent:#0f9d8a}
@media (prefers-color-scheme:dark){:root{--bg:#0d1014;--card:#161a20;--ink:#eef1f5;--muted:#9aa3b0;--line:#262c35;--accent:#2dd4bf}}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,system-ui,sans-serif}
main{max-width:420px;margin:0 auto;padding:28px 16px}
h1{font-size:24px;margin:0 0 6px}p{color:var(--muted);margin:0 0 18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;margin-bottom:14px}
.k{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.v{display:flex;align-items:center;gap:10px;font:600 20px/1.3 ui-monospace,Menlo,monospace;word-break:break-all;margin-top:2px}
.btn{display:block;text-align:center;background:var(--accent);color:#fff;text-decoration:none;font-weight:700;padding:13px;border-radius:11px}
button{margin-left:auto;flex:none;border:1px solid var(--line);background:transparent;color:var(--ink);border-radius:9px;padding:6px 12px;font:600 14px system-ui}
#qr{display:flex;justify-content:center;padding:8px 0}#qr canvas{background:#fff;padding:10px;border-radius:10px}
ol{color:var(--muted);padding-left:20px;margin:0}
</style></head><body><main>
<h1>You're on the home Wi-Fi list</h1>
<p>This device can now use the home network, so the guest Wi-Fi no longer gives it internet. Switch networks:</p>
<div class="card"><div class="k">Network</div><div class="v"><span id="s">$es</span></div></div>
<div class="card"><div class="k">Password</div><div class="v"><span id="p">$ek</span><button id="c" type="button">Copy</button></div></div>
<div class="card" id="apple" hidden><a class="btn" href="/home.mobileconfig">Join automatically</a>
<p style="margin:10px 0 0;font-size:14px">Downloads a Wi-Fi profile. Then open Settings, tap <b>Profile Downloaded</b>, and Install: the device joins <b>$es</b> by itself. If nothing downloads here, open Safari, visit any http:// site and tap this again.</p></div>
<div class="card"><ol><li>Copy the password.</li><li>Open Settings, then Wi-Fi.</li><li>Choose <b>$es</b> and paste the password.</li></ol></div>
<div class="card"><div class="k">Or scan from another phone</div><div id="qr"></div></div>
</main>
<script src="/jquery.min.js"></script><script src="/jquery.qrcode.min.js"></script>
<script>
var s=document.getElementById("s").textContent,p=document.getElementById("p").textContent;
if(/iPhone|iPad|iPod|Macintosh/.test(navigator.userAgent))document.getElementById("apple").hidden=false;
var q=function(x){return x.replace(/([\\\;,:"])/g,"\\\\\$1")};
try{jQuery("#qr").qrcode({width:200,height:200,text:unescape(encodeURIComponent("WIFI:T:WPA;S:"+q(s)+";P:"+q(p)+";;"))})}catch(e){document.getElementById("qr").textContent="QR code unavailable."}
document.getElementById("c").onclick=function(){var b=this;var done=function(){b.textContent="Copied"};
if(navigator.clipboard){navigator.clipboard.writeText(p).then(done,function(){sel()})}else sel();
function sel(){var r=document.createRange();r.selectNodeContents(document.getElementById("p"));var w=getSelection();w.removeAllRanges();w.addRange(r);try{document.execCommand("copy");done()}catch(e){}}};
</script></body></html>
EOF
    mv "$PORTAL/index.html.new" "$PORTAL/index.html"
    # Apple Wi-Fi profile: installing it joins the home network with the password saved.
    u1="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 7d1c4e2a-0b5f-4c4e-9a51-2f6d8e1b3a01)"
    u2="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 3e9b0f6c-8d2a-4f17-b6c4-5a0e7d9c1b02)"
    cat > "$PORTAL/home.mobileconfig" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PayloadContent</key><array><dict>
<key>PayloadType</key><string>com.apple.wifi.managed</string><key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>ax10.home.wifi.$u2</string><key>PayloadUUID</key><string>$u2</string>
<key>PayloadDisplayName</key><string>Home Wi-Fi ($es)</string>
<key>SSID_STR</key><string>$es</string><key>Password</key><string>$ek</string>
<key>EncryptionType</key><string>WPA3</string><key>AutoJoin</key><true/><key>HIDDEN_NETWORK</key><false/>
</dict></array>
<key>PayloadType</key><string>Configuration</string><key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>ax10.home.$u1</string><key>PayloadUUID</key><string>$u1</string>
<key>PayloadDisplayName</key><string>Home Wi-Fi</string>
<key>PayloadDescription</key><string>Joins the home Wi-Fi ($es).</string>
<key>PayloadRemovalDisallowed</key><false/>
</dict></plist>
EOF
    cat > "$PORTAL/server.lua" <<'EOF'
-- server.lua <root> <addr> <http port> <dns port>: captive-portal DNS + HTTP.
local socket = require "socket"
local root, addr, hport, dport = arg[1], arg[2], tonumber(arg[3]), tonumber(arg[4])
local home = "http://" .. addr .. ":" .. hport .. "/"
local http = assert(socket.bind(addr, hport))
local dns = assert(socket.udp()); assert(dns:setsockname(addr, dport))
http:settimeout(0); dns:settimeout(0)
local ip4 = string.char(addr:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$"))
local function read(p) local f = io.open(p, "rb"); if not f then return nil end; local d = f:read("*a"); f:close(); return d end
-- Every A query gets the router; other types get an empty answer (so no IPv6).
local function answer(q)
    if #q < 17 then return nil end
    local i = 13
    while i <= #q do local n = q:byte(i); if n == 0 then break end; i = i + n + 1 end
    if i + 4 > #q then return nil end
    local qtype = q:byte(i + 1) * 256 + q:byte(i + 2)
    local question = q:sub(13, i + 4)
    local a = qtype == 1
    local r = q:sub(1, 2) .. "\129\128\0\1\0" .. (a and "\1" or "\0") .. "\0\0\0\0" .. question
    if a then r = r .. "\192\12\0\1\0\1\0\0\0\10\0\4" .. ip4 end
    return r
end
local function serve(c)
    c:settimeout(5)
    local path = (c:receive("*l") or ""):match("^%u+%s+(%S+)") or "/"
    local host = ""
    repeat local h = c:receive("*l"); if h then host = h:match("^[Hh]ost:%s*(%S+)") or host end until not h or h == ""
    local ours = host == addr .. ":" .. hport
    local js = ours and path:match("^/(jquery[%w.]*%.js)$")
    local body, head
    if ours and path == "/home.mobileconfig" then
        body = read(root .. "/home.mobileconfig") or ""
        head = "200 OK\r\nContent-Type: application/x-apple-aspen-config\r\nContent-Disposition: attachment; filename=home.mobileconfig"
    elseif js then body = read(root .. "/" .. js) or ""; head = "200 OK\r\nContent-Type: application/javascript"
    elseif ours then body = read(root .. "/index.html") or ""; head = "200 OK\r\nContent-Type: text/html; charset=utf-8"
    else body = '<a href="' .. home .. '">Join the home Wi-Fi</a>'; head = "302 Found\r\nLocation: " .. home .. "\r\nContent-Type: text/html" end
    c:send("HTTP/1.0 " .. head .. "\r\nCache-Control: no-store\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
    c:close()
end
while true do
    local ready = socket.select({ http, dns }, nil, 60)
    for _, s in ipairs(ready or {}) do
        if s == dns then
            local q, ip, port = dns:receivefrom()
            local r = q and answer(q)
            if r then dns:sendto(r, ip, port) end
        else
            local c = http:accept()
            if c then pcall(serve, c) end
        end
    end
end
EOF
}
portal_running() { p="$(cat "$RUN/portal.pid" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
portal_clear() {
    while $IPT -D FORWARD -i "$LANBR" -j $CH_PORTAL 2>/dev/null; do :; done
    while $IPT6 -D FORWARD -i "$LANBR" -j $CH_PORTAL 2>/dev/null; do :; done
    while $IPT -t nat -D PREROUTING -i "$LANBR" -j $CH_PORTAL_NAT 2>/dev/null; do :; done
    while $IPT -D INPUT -i "$LANBR" -j $CH_PORTAL_IN 2>/dev/null; do :; done
    while $IPT6 -D INPUT -i "$LANBR" -j $CH_PORTAL_IN6 2>/dev/null; do :; done
    $IPT -F $CH_PORTAL 2>/dev/null; $IPT -X $CH_PORTAL 2>/dev/null
    $IPT6 -F $CH_PORTAL 2>/dev/null; $IPT6 -X $CH_PORTAL 2>/dev/null
    $IPT -t nat -F $CH_PORTAL_NAT 2>/dev/null; $IPT -t nat -X $CH_PORTAL_NAT 2>/dev/null
    $IPT -F $CH_PORTAL_IN 2>/dev/null; $IPT -X $CH_PORTAL_IN 2>/dev/null
    $IPT6 -F $CH_PORTAL_IN6 2>/dev/null; $IPT6 -X $CH_PORTAL_IN6 2>/dev/null
    portal_running && kill "$(cat "$RUN/portal.pid")" 2>/dev/null
    rm -f "$RUN/portal.pid"
}
# A phone checks for a captive portal only right after it joins. The watcher sees a
# new guest up to 15 s later, by when the check has passed and the phone thinks the
# network works. So a device newly given the page is disconnected from the guest
# Wi-Fi once: it rejoins at once, with the rules in place, and its check finds the
# page. A device that was on the page in the last PORTAL_GRACE seconds keeps it
# while it rejoins.
PORTAL_GRACE="${PORTAL_GRACE:-60}"
portal_sync() {
    pm=""; now="$(now_s)"
    if [ "$H_LOCK" = 1 ]; then
        g=" $(guest_macs | sort -u | tr '\n' ' ') "
        for m in $H_ALLOW $H_KEEP; do
            case "$g" in *" $m "*) case " $pm " in *" $m "*) ;; *) pm="$pm $m" ;; esac ;; esac
        done
        # Grace: listed devices seen on the page recently (they may be rejoining).
        if [ -f "$RUN/portal_seen" ]; then
            while read -r m t; do
                [ $((now - t)) -le "$PORTAL_GRACE" ] 2>/dev/null || continue
                home_listed "$m" || continue
                case " $pm " in *" $m "*) ;; *) pm="$pm $m" ;; esac
            done < "$RUN/portal_seen"
        fi
        { for m in $pm; do case "$g" in *" $m "*) echo "$m $now" ;; esac; done
          [ -f "$RUN/portal_seen" ] && cat "$RUN/portal_seen"; } | awk '!s[$1]++' > "$RUN/portal_seen.new"
        mv "$RUN/portal_seen.new" "$RUN/portal_seen"
    fi
    pm="$(echo $pm)"
    prev=" $(cat "$RUN/portal_macs" 2>/dev/null) "
    if [ -z "$pm" ]; then
        [ -s "$RUN/portal_macs" ] && log "join-home page off"
        [ -e "$RUN/portal_macs" ] && { portal_clear; rm -f "$RUN/portal_macs"; }
        return 0
    fi
    if [ "$pm" = "$(cat "$RUN/portal_macs" 2>/dev/null)" ] && portal_running &&
       $IPT -C FORWARD -i "$LANBR" -j $CH_PORTAL 2>/dev/null &&
       $IPT -t nat -C PREROUTING -i "$LANBR" -j $CH_PORTAL_NAT 2>/dev/null; then return 0; fi
    portal_clear
    portal_page || return 0
    lan="$($UCI -q get network.lan.ipaddr)"; lan="${lan:-192.168.0.1}"
    $IPT -N $CH_PORTAL 2>/dev/null; $IPT6 -N $CH_PORTAL 2>/dev/null
    $IPT -t nat -N $CH_PORTAL_NAT 2>/dev/null; $IPT -N $CH_PORTAL_IN 2>/dev/null; $IPT6 -N $CH_PORTAL_IN6 2>/dev/null
    for m in $pm; do
        $IPT -A $CH_PORTAL -m mac --mac-source "$m" -p tcp -j REJECT --reject-with tcp-reset
        $IPT -A $CH_PORTAL -m mac --mac-source "$m" -j REJECT
        $IPT6 -A $CH_PORTAL -m mac --mac-source "$m" -j REJECT
        $IPT -t nat -A $CH_PORTAL_NAT -m mac --mac-source "$m" -p tcp --dport 80 -j DNAT --to-destination "$lan:$PORTAL_PORT"
        $IPT -t nat -A $CH_PORTAL_NAT -m mac --mac-source "$m" -p udp --dport 53 -j DNAT --to-destination "$lan:$PORTAL_DNS"
        $IPT -A $CH_PORTAL_IN -m mac --mac-source "$m" -p tcp --dport "$PORTAL_PORT" -j ACCEPT
        $IPT -A $CH_PORTAL_IN -m mac --mac-source "$m" -p udp --dport "$PORTAL_DNS" -j ACCEPT
        $IPT -A $CH_PORTAL_IN -m mac --mac-source "$m" -p tcp --dport 53 -j REJECT --reject-with tcp-reset
        $IPT -A $CH_PORTAL_IN -m mac --mac-source "$m" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
        $IPT6 -A $CH_PORTAL_IN6 -m mac --mac-source "$m" -p udp --dport 53 -j REJECT
        $IPT6 -A $CH_PORTAL_IN6 -m mac --mac-source "$m" -p tcp -j REJECT --reject-with tcp-reset
    done
    $IPT -A $CH_PORTAL_IN -p tcp --dport "$PORTAL_PORT" -j DROP
    $IPT -A $CH_PORTAL_IN -p udp --dport "$PORTAL_DNS" -j DROP
    $IPT -I FORWARD 1 -i "$LANBR" -j $CH_PORTAL; $IPT6 -I FORWARD 1 -i "$LANBR" -j $CH_PORTAL
    $IPT -t nat -I PREROUTING 1 -i "$LANBR" -j $CH_PORTAL_NAT
    $IPT -I INPUT 1 -i "$LANBR" -j $CH_PORTAL_IN; $IPT6 -I INPUT 1 -i "$LANBR" -j $CH_PORTAL_IN6
    $LUA "$PORTAL/server.lua" "$PORTAL" "$lan" "$PORTAL_PORT" "$PORTAL_DNS" >/dev/null 2>&1 &
    echo $! > "$RUN/portal.pid"
    echo "$pm" > "$RUN/portal_macs"
    command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
    log "guest Wi-Fi: showing the join-home page to $pm"
    # Newly added: make them rejoin so their captive-portal check sees the page.
    for m in $pm; do
        case "$prev" in *" $m "*) continue ;; esac
        for i in $(guest_ifs); do
            $WL -i "$i" assoclist 2>/dev/null | grep -qi "$m" && $WL -i "$i" deauthenticate "$(echo "$m" | tr a-f A-F)" 2>/dev/null
        done
    done
}
watcher_wanted() { [ "$(cfg enabled 0)" = 1 ] || [ "$(cfg home_lock 0)" = 1 ]; }

# TP-Link's Access Control in allow-list mode is meant for the home Wi-Fi, but it
# catches guests twice:
#   - its Wi-Fi MAC filter goes on the guest interfaces too, so strangers can't join;
#   - its firewall chain (raw table, access_control) drops every MAC not on the list.
#     With guest_enable=off it means to let guests through with "-m physdev
#     --physdev-in <guest if>" rules, but this kernel has no physdev match, so those
#     rules fail silently and guests get no address and no internet.
# Keep the guest interfaces open, and accept each connected guest by MAC in our own
# chain at the top of TP-Link's (rebuilt on every firewall reload; checked every run).
# Block-list mode is left as TP-Link has it.
GUEST_AC=ax10_guest_ac
guest_wifi_open() {
    on=0
    [ "$($UCI -q get access_control.settings.enable)" = on ] &&
        [ "$($UCI -q get access_control.settings.access_mode)" = white ] && on=1
    if [ "$on" = 1 ]; then
        for i in $(guest_ifs); do
            [ "$($WL -i "$i" macmode 2>/dev/null)" = 0 ] && continue
            $WL -i "$i" macmode 0 && log "kept the guest Wi-Fi ($i) open: TP-Link's allow list is for the home Wi-Fi"
        done
    fi
    macs="$(guest_macs | sort -u | tr '\n' ' ')"
    for t in "$IPT" "$IPT6"; do
        $t -t raw -S access_control >/dev/null 2>&1 || continue      # Access Control off: no chain
        $t -t raw -N "$GUEST_AC" 2>/dev/null
        if [ "$on" != 1 ]; then
            $t -t raw -D access_control -j "$GUEST_AC" 2>/dev/null
            $t -t raw -F "$GUEST_AC"; continue
        fi
        $t -t raw -C access_control -j "$GUEST_AC" 2>/dev/null || $t -t raw -I access_control 1 -j "$GUEST_AC"
        want="$(echo $macs | tr ' ' '\n' | tr a-f A-F | sort | tr '\n' ' ')"
        have="$($t -t raw -S "$GUEST_AC" 2>/dev/null | sed -n 's/.*--mac-source \([^ ]*\).*/\1/p' | tr a-f A-F | sort | tr '\n' ' ')"
        [ "$want" = "$have" ] && continue
        $t -t raw -F "$GUEST_AC"
        for m in $macs; do $t -t raw -A "$GUEST_AC" -m mac --mac-source "$m" -j ACCEPT; done
    done
}
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

# ------------------------------------------------------------- speed limits
# Three kinds of cap, all optional:
#   - per device: iot_caps "mac=down/up ..." in Mbps (0 = no cap that way);
#   - guests: each connected guest gets iot_guest_down/up (iot_guest_limit=1)
#     unless its MAC is in iot_guest_fast; a per-device cap wins;
#   - the whole connection: iot_wan_shape=1 caps all internet traffic at
#     iot_wan_down/up, a little under the line speed, so queues stay short;
#   - a priority lane (iot_prio=1, needs the whole-connection cap): calls and
#     games go first, guaranteed 40% of the line and allowed all of it;
#   - guests last (iot_guest_low=1, needs the whole-connection cap): every guest's
#     traffic goes in a bottom lane guaranteed 10%, so home devices win when the
#     line is busy. Guests' own caps still apply inside it.
# Devices are matched by MAC, so a cap covers IPv4 and IPv6 and survives a new IP.
# Download: htb on br-lan's egress (routed traffic into the home bridge; traffic
# between home devices is bridged and never passes there), one class per capped
# device, u32-matched on the Ethernet destination. Upload: br-lan's ingress is
# redirected to ifb0 and shaped there by Ethernet source. Leaves are sfq (fair
# between connections; this kernel has no fq_codel or cake). The IoT bridge is
# never shaped.
# Broadcom acceleration bypasses Linux queues, so shaped traffic gets BLOGSKIP:
# everything when the whole connection is capped, else only connections of capped
# devices (conntrack bit 0x1000000, set when the device sends). Packet marks are
# left alone; TP-Link's VPN client uses them.
TC="${TC:-tc}"
IPT6="${IPT6:-/usr/sbin/ip6tables -w}"
IFB="${IFB:-ifb0}"
LANBR="${LANBR:-br-lan}"
CLIENTS="${CLIENTS:-/tmp/client_list.json}"
CH_SHAPE=AX10_SHAPE          # mangle FORWARD: BLOGSKIP
CH_SHAPE_IN=AX10_SHAPE_IN    # mangle PREROUTING: mark capped devices' connections
CT_BIT=0x1000000
CH_GUEST=AX10_GUEST; CH_GUEST6=AX10_GUEST6   # the guest-only limit of v27 and older
shape_load() {
    GL_ON="$(cfg guest_limit 0)"; GL_DOWN="$(cfg guest_down 5)"; GL_UP="$(cfg guest_up 2)"
    GL_FAST="$(cfg guest_fast '' | tr 'A-F-' 'a-f:')"
    CAPS="$(cfg caps '' | tr 'A-F-' 'a-f:')"
    WS_ON="$(cfg wan_shape 0)"; WS_DOWN="$(cfg wan_down 0)"; WS_UP="$(cfg wan_up 0)"
    PRIO="$(cfg prio 0)"; GLOW="$(cfg guest_low 0)"
}
guest_ifs() {   # guest Wi-Fi interfaces from TP-Link's own config (wifi-iface guest=on)
    for sec in $($UCI show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.guest='\{0,1\}on'\{0,1\}$/\1/p"); do
        i="$($UCI -q get "wireless.$sec.ifname")"; [ -d "$NET/$i" ] && echo "$i"
    done
}
guest_macs() {  # connected guests: on our guest Wi-Fi, or behind the mesh satellite (TP-Link's client list)
    for i in $(guest_ifs); do $WL -i "$i" assoclist 2>/dev/null | awk '{print tolower($2)}'; done
    [ -f "$CLIENTS" ] && tr '{' '\n' < "$CLIENTS" | grep '"guest":"GUEST"' | grep '"connect_status":1' |
        sed -n 's/.*"mac":"\([0-9A-Fa-f-]*\)".*/\1/p' | tr 'A-F-' 'a-f:'
}
is_fast() { case " $GL_FAST " in *" $1 "*) return 0;; esac; return 1; }
shape_list() {  # "mac down up" for every device to cap
    for e in $CAPS; do echo "${e%%=*} $(echo "${e#*=}" | tr '/' ' ')"; done
    [ "$GL_ON" = 1 ] || return 0
    for m in $(guest_macs | sort -u); do
        is_fast "$m" && continue
        case " $CAPS " in *" $m="*) continue;; esac
        echo "$m $GL_DOWN $GL_UP"
    done
}
sfq_limit() { l=$(($1 * 3)); [ "$l" -ge 20 ] || l=20; [ "$l" -le 127 ] || l=127; echo "$l"; }   # ~35 ms at the cap
# htb's default burst (a few KB) is too small for this kernel's timer: measured, an
# 18 Mbps class delivered 10-13 Mbps. Allow ~20 ms of traffic at the rate, >= 15 KB.
htb_burst() { b=$(($1 * 2500)); [ "$b" -ge 15000 ] || b=15000; echo "burst $b cburst $b"; }
shape_clear() {
    $TC qdisc del dev "$LANBR" root 2>/dev/null; $TC qdisc del dev "$LANBR" ingress 2>/dev/null
    $TC qdisc del dev "$IFB" root 2>/dev/null
    for c in "$IPT" "$IPT6"; do
        while $c -t mangle -D FORWARD -j $CH_SHAPE 2>/dev/null; do :; done
        while $c -t mangle -D PREROUTING -j $CH_SHAPE_IN 2>/dev/null; do :; done
        $c -t mangle -F $CH_SHAPE 2>/dev/null; $c -t mangle -X $CH_SHAPE 2>/dev/null
        $c -t mangle -F $CH_SHAPE_IN 2>/dev/null; $c -t mangle -X $CH_SHAPE_IN 2>/dev/null
    done
    # Leftovers of the old guest-only limit (per guest Wi-Fi interface, by IP).
    if $IPT -t mangle -S $CH_GUEST >/dev/null 2>&1 || [ -f "$RUN/guest.sig" ]; then
        for i in $(guest_ifs); do $TC qdisc del dev "$i" root 2>/dev/null; $TC qdisc del dev "$i" ingress 2>/dev/null; done
        while $IPT -t mangle -D PREROUTING -j $CH_GUEST 2>/dev/null; do :; done
        while $IPT -t mangle -D FORWARD -j $CH_GUEST 2>/dev/null; do :; done
        $IPT -t mangle -F $CH_GUEST 2>/dev/null; $IPT -t mangle -X $CH_GUEST 2>/dev/null
        while $IPT6 -D FORWARD -j $CH_GUEST6 2>/dev/null; do :; done
        $IPT6 -F $CH_GUEST6 2>/dev/null; $IPT6 -X $CH_GUEST6 2>/dev/null
        rm -f "$RUN/guest.sig"
    fi
}
shape_ok() {   # everything the last build added is still there
    $TC qdisc show dev "$LANBR" 2>/dev/null | grep -q "htb 1:" &&
    $TC qdisc show dev "$LANBR" 2>/dev/null | grep -q "ingress" &&
    $TC qdisc show dev "$IFB" 2>/dev/null | grep -q "htb 1:" &&
    $IPT -t mangle -C FORWARD -j $CH_SHAPE 2>/dev/null && $IPT6 -t mangle -C FORWARD -j $CH_SHAPE 2>/dev/null
}
# Priority lane: what goes in class 1:2. <sel> is sport for downloads (packets from
# the internet) and dport for uploads. Port blocks are mask-aligned, so they cover a
# few neighbouring ports too.
#   calls: Zoom media 8801-8810, STUN/TURN 3478-3481 (Zoom, Teams, WhatsApp, FaceTime),
#          Google Meet 19302-19309, Teams 50000-50059;
#   games: UDP packets under 512 bytes (game state, voice; bulk UDP such as QUIC
#          downloads and torrents uses full-size packets and stays in the normal lane);
#   also ICMP and traffic marked real-time (DSCP EF, AF41).
PRIO_PORTS="8800/0xfff8 8808/0xfff8 3476/0xfff8 19296/0xfff0 49984/0xffc0 50048/0xffc0"
prio_filters() {   # prio_filters <dev> <sport|dport>
    # Filters sharing a prio number must share a protocol: IPv4 at 2, IPv6 at 3.
    pf() { [ "$2" = ip ] && fp=2 || fp=3; $TC filter add dev "$1" parent 1: protocol "$2" prio $fp u32 $3 flowid 1:2; }
    pf "$1" ip "match ip protocol 1 0xff"
    pf "$1" ipv6 "match ip6 protocol 58 0xff"
    pf "$1" ip "match ip protocol 17 0xff match u16 0x0000 0xfe00 at 2"
    pf "$1" ipv6 "match ip6 protocol 17 0xff match u16 0x0000 0xfe00 at 4"
    for p in $PRIO_PORTS; do
        pf "$1" ip "match ip protocol 17 0xff match ip $2 ${p%/*} ${p#*/}"
        pf "$1" ipv6 "match ip6 protocol 17 0xff match ip6 $2 ${p%/*} ${p#*/}"
    done
    for t in 0xb8 0x88; do
        pf "$1" ip "match ip tos $t 0xfc"
        pf "$1" ipv6 "match ip6 priority $t 0xfc"
    done
}
shape_class() {   # shape_class <dev> <minor> <Mbps> [parent]: capped class with an sfq leaf
    $TC class add dev "$1" parent "${4:-1:1}" classid "1:$2" htb rate "${3}mbit" ceil "${3}mbit" $(htb_burst "$3") prio 1
    $TC qdisc add dev "$1" parent "1:$2" handle "$2:" sfq perturb 10 limit "$(sfq_limit "$3")"
}
shape_sync() {
    shape_load
    list="$(shape_list | awk 'NF == 3 && $1 ~ /^[0-9a-f:]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && ($2 > 0 || $3 > 0)' | sort -u)"
    wan=0
    [ "$WS_ON" = 1 ] && [ "$WS_DOWN" -gt 0 ] 2>/dev/null && [ "$WS_UP" -gt 0 ] 2>/dev/null && wan=1
    prio=0; [ "$wan" = 1 ] && [ "$PRIO" = 1 ] && prio=1
    low=0; gl=""; [ "$wan" = 1 ] && [ "$GLOW" = 1 ] && { low=1; gl="$(guest_macs | sort -u | tr '\n' ' ')"; }
    if [ -z "$list" ] && [ "$wan" = 0 ]; then
        if [ -f "$RUN/shape.sig" ] || [ -f "$RUN/guest.sig" ]; then
            shape_clear; rm -f "$RUN/shape.sig"; log "speed limits off"
        fi
        return 0
    fi
    sig="$wan|$WS_DOWN|$WS_UP|$prio|$low|$gl|$(echo $list)"
    [ "$(cat "$RUN/shape.sig" 2>/dev/null)" = "$sig" ] && shape_ok && return 0
    shape_clear
    lsmod 2>/dev/null | grep -q '^xt_BLOGSKIP' || insmod /lib/modules/iplatform/xt_BLOGSKIP.ko 2>/dev/null
    for c in "$IPT" "$IPT6"; do
        $c -t mangle -N $CH_SHAPE 2>/dev/null
        $c -t mangle -I FORWARD 1 -j $CH_SHAPE
        if [ "$wan" = 1 ]; then
            $c -t mangle -A $CH_SHAPE -j BLOGSKIP
        else
            $c -t mangle -N $CH_SHAPE_IN 2>/dev/null
            $c -t mangle -I PREROUTING 1 -j $CH_SHAPE_IN
            echo "$list" | while read m d u; do
                $c -t mangle -A $CH_SHAPE_IN -i "$LANBR" -m mac --mac-source "$m" -j CONNMARK --set-xmark $CT_BIT/$CT_BIT
            done
            $c -t mangle -A $CH_SHAPE -m connmark --mark $CT_BIT/$CT_BIT -j BLOGSKIP
        fi
    done
    $IP link set "$IFB" up 2>/dev/null
    for dev in "$LANBR" "$IFB"; do
        if [ "$wan" = 1 ]; then
            [ "$dev" = "$LANBR" ] && t="$WS_DOWN" || t="$WS_UP"
            r="${t}mbit"; q="$(sfq_limit "$t")"
        else t=1000; r=1000mbit; q=127; fi
        $TC qdisc add dev "$dev" root handle 1: htb default 10
        $TC class add dev "$dev" parent 1: classid 1:1 htb rate "$r" ceil "$r" $(htb_burst "$t")
        if [ "$prio" = 1 ] || [ "$low" = 1 ]; then
            hi=0; gs=0
            [ "$prio" = 1 ] && { hi=$((t * 40 / 100)); [ "$hi" -ge 1 ] || hi=1; }
            [ "$low" = 1 ] && { gs=$((t / 10)); [ "$gs" -ge 1 ] || gs=1; }
            lo=$((t - hi - gs)); [ "$lo" -ge 1 ] || lo=1
            if [ "$prio" = 1 ]; then
                $TC class add dev "$dev" parent 1:1 classid 1:2 htb rate "${hi}mbit" ceil "$r" $(htb_burst "$t") prio 0
                $TC qdisc add dev "$dev" parent 1:2 handle 2: sfq perturb 10 limit "$q"
            fi
            $TC class add dev "$dev" parent 1:1 classid 1:10 htb rate "${lo}mbit" ceil "$r" $(htb_burst "$t") prio 1
            if [ "$low" = 1 ]; then
                # 1:3 holds the guest lane: guests' own caps nest inside it, and 1:4
                # takes the rest of their traffic (a class with children holds no packets).
                $TC class add dev "$dev" parent 1:1 classid 1:3 htb rate "${gs}mbit" ceil "$r" $(htb_burst "$t") prio 2
                $TC class add dev "$dev" parent 1:3 classid 1:4 htb rate "${gs}mbit" ceil "$r" $(htb_burst "$t") prio 2
                $TC qdisc add dev "$dev" parent 1:4 handle 4: sfq perturb 10 limit "$q"
            fi
        else
            $TC class add dev "$dev" parent 1:1 classid 1:10 htb rate "$r" ceil "$r" $(htb_burst "$t")
        fi
        $TC qdisc add dev "$dev" parent 1:10 handle 10: sfq perturb 10 limit "$q"
    done
    # Device caps match first (prio 1), so a capped device stays within its cap.
    [ "$prio" = 1 ] && { prio_filters "$LANBR" sport; prio_filters "$IFB" dport; }
    $TC qdisc add dev "$LANBR" ingress
    $TC filter add dev "$LANBR" parent ffff: protocol all prio 10 u32 match u32 0 0 action mirred egress redirect dev "$IFB"
    n=11
    echo "$list" | while read m d u; do
        par=1:1; [ "$low" = 1 ] && case " $gl " in *" $m "*) par=1:3 ;; esac
        if [ "$d" -gt 0 ]; then
            shape_class "$LANBR" "$n" "$d" "$par"
            $TC filter add dev "$LANBR" parent 1: protocol all prio 1 u32 match ether dst "$m" flowid "1:$n"
        fi
        if [ "$u" -gt 0 ]; then
            shape_class "$IFB" "$n" "$u" "$par"
            $TC filter add dev "$IFB" parent 1: protocol all prio 1 u32 match ether src "$m" flowid "1:$n"
        fi
        n=$((n + 1))
    done
    # Guests last: whatever a guest's own cap does not catch lands in the bottom lane.
    # Added after the cap filters, so within prio 1 those match first.
    for m in $gl; do
        $TC filter add dev "$LANBR" parent 1: protocol all prio 1 u32 match ether dst "$m" flowid 1:4
        $TC filter add dev "$IFB" parent 1: protocol all prio 1 u32 match ether src "$m" flowid 1:4
    done
    command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
    echo "$sig" > "$RUN/shape.sig"
    log "speed limits: $(echo "$list" | grep -c .) device(s) capped$([ "$wan" = 1 ] && echo ", whole connection at ${WS_DOWN}/${WS_UP} Mbps")$([ "$prio" = 1 ] && echo ", calls and games first")$([ "$low" = 1 ] && echo ", guests last")"
}
guest_sync() { shape_sync; }   # older callers

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
    autopin
    dhcp_sync
    lock_sync
    guest_wifi_open
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
WWW_ROOT="${WWW_ROOT:-${WWW%/*}}"
LUCI_CTL="${LUCI_CTL:-/usr/lib/lua/luci/controller/admin}"
UI_SRC="$RUN/ui"
OV="$RUN/overlay"
UI_VER=iot6
mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }
overlay() {   # overlay <dir> <name>: bind a writable RAM copy over <dir>, echo the copy's path
    if ! mounted "$1"; then
        rm -rf "$OV/$2"; mkdir -p "$OV"
        cp -a "$1" "$OV/$2" && $MOUNT --bind "$OV/$2" "$1" || return 1
    fi
    echo "$1"
}
bind_file() {   # bind_file <src> <dst>: show <src> at existing file <dst> (re-bound, so updates show)
    [ -f "$1" ] && [ -f "$2" ] || return 0
    mounted "$2" && $UMOUNT "$2"
    $MOUNT --bind "$1" "$2"
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
    # Theme: the per-language stylesheet loads after the stock ones, so our rules go at
    # its end (from the marker to end of file is ours; replaced on every install).
    if [ -f "$UI_SRC/theme.css" ]; then
        touch "$l/lan.css"
        sed '/ax10-theme-begin/,$d' "$l/lan.css" > "$l/lan.css.new"
        { echo '/* ax10-theme-begin */'; cat "$UI_SRC/theme.css"; } >> "$l/lan.css.new"
        cat "$l/lan.css.new" > "$l/lan.css"; rm -f "$l/lan.css.new"
    fi
    # Dashboard at /: our page over the stock root redirect, and over /webpages/login.html,
    # where plain-HTTP visits are sent. The stock UI stays at /webpages/index.html.
    chmod -R a+rX "$UI_SRC/dash" 2>/dev/null
    bind_file "$UI_SRC/dash/index.html" "$WWW_ROOT/index.html"
    bind_file "$UI_SRC/dash/login.html" "$WWW/login.html"
    log "web UI installed: dashboard at /, stock pages and theme (Advanced > Wireless > IoT Network, Guest Speed)"
}
ui_remove() {
    for d in "$WWW_ROOT/index.html" "$WWW/login.html" "$LUCI_CTL" "$WWW/modules/advanced/wireless" "$WWW/config" "$WWW"/locale/*; do
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
    echo "lock:      $([ "$(cfg lock 0)" = 1 ] && { lock_open && echo "on, open to new devices" || echo "on ($($WL -i "$VIF" macmode 2>/dev/null) = allow list)"; } || echo off)"
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
    apply|start|stop|guest|shape|open|close|forget|home|home-open|home-close|home-allow|home-set|ui|ui-remove|boot)
        lock || { log "$1: another iot.sh run still holds the lock; gave up after ${LOCK_WAIT}s"
                  echo "iot.sh: another run is in progress; try again" >&2; exit 1; }
        trap unlock EXIT ;;
esac

case "$1" in
    apply) apply ;;
    watch)
        while :; do
            if lock 5; then
                if [ "$(cfg enabled 0)" = 1 ]; then
                    apply >/dev/null 2>&1
                    shape_sync >/dev/null 2>&1
                fi
                home_sync >/dev/null 2>&1
                unlock
            fi
            lifeline_guard
            trim_log
            sleep "${INTERVAL:-15}"
        done ;;
    start)
        [ "$0" = "$SELF" ] || cp "$0" "$SELF" 2>/dev/null
        apply; shape_sync; home_sync; inittab_add; watcher_restart; log "watcher registered" ;;
    stop)
        stop; shape_clear; rm -f "$RUN/shape.sig"
        # The home allow list is not part of the IoT network: keep it (and a watcher) running.
        if [ "$(cfg home_lock 0)" = 1 ]; then home_sync; inittab_add; log "watcher kept for the home allow list"
        else home_load; home_unlock; portal_clear; rm -f "$RUN/portal_macs"; fi ;;
    open|close)
        load; mkdir -p "$RUN"
        if [ "$1" = open ]; then
            s="${2:-600}"; case "$s" in ''|*[!0-9]*) s=600 ;; esac
            echo $(( $(now_s) + s )) > "$RUN/open_until"
            log "new IoT devices allowed for ${s}s"
        else rm -f "$RUN/open_until"; fi
        lock_sync ;;
    home-open|home-close)
        mkdir -p "$RUN"
        if [ "$1" = home-open ]; then
            s="${2:-600}"; case "$s" in ''|*[!0-9]*) s=600 ;; esac
            echo $(( $(now_s) + s )) > "$RUN/home_open_until"; log "new home devices allowed for ${s}s"
        else rm -f "$RUN/home_open_until"; fi
        home_sync ;;
    home-allow) home_edit "$2" "$3" || exit 1; home_sync ;;
    forget)   # forget <mac>: drop an IoT device's fixed address; autopin won't re-pin it
        load; mac="$(echo "$2" | tr A-F- a-f:)"
        echo "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || { echo "iot.sh: bad MAC '$2'" >&2; exit 1; }
        st=""; for e in $STATIC; do [ "$(echo "${e%%,*}" | tr A-F a-f)" = "$mac" ] || st="$st $e"; done
        fg="$(cfg forget '' | tr A-F a-f)"; case " $fg " in *" $mac "*) ;; *) fg="$fg $mac" ;; esac
        $UCI set "$SEC.iot_static=$(echo $st)"; $UCI set "$SEC.iot_forget=$(echo $fg)"
        commit_cfg >/dev/null; log "forgot IoT device $mac"
        if [ "$(cfg enabled 0)" = 1 ]; then apply; fi ;;
    home-set)
        home_set "$2" "$3" || exit 1
        home_sync
        if watcher_wanted; then grep -q "$TAG" "$INITTAB" 2>/dev/null || { inittab_add; log "watcher registered (home allow list)"; }
        else inittab_del; fi ;;
    home)
        home_sync
        echo "home lock: $([ "$H_LOCK" = 1 ] && { home_open_now && echo "on, open to new devices" || echo on; } || echo off)"
        echo "radios:    $H_IFS"
        echo "allowed:   $H_ALLOW"
        echo "always:    ${H_KEEP:-none}"
        echo "dropped:   $(cat "$RUN/home_drop" 2>/dev/null)"
        echo "join page: $(cat "$RUN/portal_macs" 2>/dev/null)$(portal_running && echo " (server up)")"
        echo "expire:    $([ "$H_EXPIRE" -gt 0 ] 2>/dev/null && echo "$H_EXPIRE days" || echo off)" ;;
    guest|shape)
        shape_sync; shape_load
        echo "whole connection: $([ "$WS_ON" = 1 ] && echo "${WS_DOWN}/${WS_UP} Mbps" || echo off)"
        echo "priority lane: $([ "$PRIO" = 1 ] && { [ "$WS_ON" = 1 ] && echo on || echo "on, but needs the whole-connection cap"; } || echo off)"
        echo "guests last: $([ "$GLOW" = 1 ] && { [ "$WS_ON" = 1 ] && echo on || echo "on, but needs the whole-connection cap"; } || echo off)"
        echo "guest limit: $GL_ON  ${GL_DOWN}/${GL_UP} Mbps  full-speed: ${GL_FAST:-none}"
        echo "capped (mac down up):"; shape_list | sort -u ;;
    ui) [ "$0" = "$SELF" ] || cp "$0" "$SELF" 2>/dev/null; ui_install; watcher_restart ;;
    ui-remove) ui_remove ;;
    boot)
        [ "$0" = "$SELF" ] || cp "$0" "$SELF" 2>/dev/null
        ui_install
        # In-process, not "$0 start": the fetched file is not executable.
        if [ "$(cfg enabled 0)" = 1 ]; then apply; shape_sync; home_sync; inittab_add; log "watcher registered"
        elif [ "$(cfg home_lock 0)" = 1 ]; then home_sync; inittab_add; log "watcher registered (home allow list)"; fi
        lifeline_guard ;;
    status) status ;;
    set)
        [ -n "$2" ] || { echo "usage: iot.sh set <key> <value>" >&2; exit 1; }
        k="${2#iot_}"
        # /etc is ramfs: plain `uci commit` is lost on reboot. TP-Link's uci_commit_flash
        # goes through its patched luci.model.uci, which also writes the config to flash.
        $UCI set "$SEC.iot_$k=$3" || exit 1
        commit_cfg && echo "saved iot_$k" ;;
    *) sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
