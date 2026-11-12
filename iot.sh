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
#   iot.sh forget-device <mac>[,<mac>...]  forget devices: all their settings, hidden while offline
#   iot.sh usage        data used: per day, per month, per device this month
#   iot.sh sync         apply everything now (after forget-device / entry, which only save)
#   iot.sh entry caps|noinet|guest_fast|lan_allow <mac> <value|on|off>   one device's setting
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
# filesystem here, and this busybox's flock has no timeout and leaks the lock to
# every daemon a run starts, so the lock is built from directories.
# The lock is Lamport's bakery algorithm on a directory of tickets, $LOCK/<n>.<pid>:
# a run takes the next number and goes ahead once no live run holds a lower one
# (ties: lower pid first). While it picks its number it holds $LOCK/c.<pid>, and
# others wait for that, so two runs can never both think they are first.
# A ticket whose process is gone is simply ignored and removed: there is no "take
# over a stale lock" step, which is where mkdir-style locks let two holders through.
#
# Two locks:
#   LOCK     the run lock: one run at a time rebuilds rules (apply, sync, watch...);
#   CFGLOCK  the settings lock: held only while a list in the config is read,
#            changed and saved (a second or so). The dashboard's edits take just
#            this one, so they don't wait for a rebuild in progress; the watcher
#            takes it around its own list changes (new IoT pins, allow-list
#            enrollment and expiry, un-hiding), re-reading the list inside it.
LOCK="$RUN/locks"
CFGLOCK="$RUN/cfglocks"
LOCK_WAIT="${LOCK_WAIT:-60}"
lock_start() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
# A ticket (or choosing marker) belongs to a live run if its pid is alive and is the
# same process that wrote it: the start time inside must match the pid's. Where
# there is no /proc both are empty and the pid alone decides.
lock_alive() {   # lock_alive <pid> <ticket dir>
    kill -0 "$1" 2>/dev/null || return 1
    [ "$(cat "$2/start" 2>/dev/null)" = "$(lock_start "$1")" ]
}
# Create <dir>/<name> with its start file already inside (built aside, then renamed:
# nobody ever sees a ticket without its identity).
lock_put() {   # lock_put <dir> <name>
    rm -rf "$1/.new.$$"; mkdir "$1/.new.$$" || return 1
    lock_start "$$" > "$1/.new.$$/start"
    mv "$1/.new.$$" "$1/$2"
}
lock_at() {   # lock_at <dir> <seconds to wait>; returns 1 if others are still ahead
    L_d="$1"; L_w="$2"; mkdir -p "$L_d"
    rm -rf "$L_d"/*."$$" 2>/dev/null            # leftovers of an earlier process that had my pid
    lock_put "$L_d" "c.$$" || return 1
    L_max=0
    for L_e in "$L_d"/[0-9]*.*; do
        [ -d "$L_e" ] || continue
        L_b="${L_e##*/}"; L_n="${L_b%%.*}"; L_p="${L_b#*.}"
        lock_alive "$L_p" "$L_e" || { rm -rf "$L_e"; continue; }
        [ "$L_n" -gt "$L_max" ] 2>/dev/null && L_max="$L_n"
    done
    L_mine=$((L_max + 1)); L_me="$L_d/$L_mine.$$"
    lock_put "$L_d" "$L_mine.$$" || { rm -rf "$L_d/c.$$"; return 1; }
    rm -rf "$L_d/c.$$"                           # my ticket is out before the marker goes
    while :; do
        # 1. Is anyone picking a number? Their ticket may not be out yet, so nothing
        #    can be decided now. A marker that was listed but is gone by the time we
        #    look counts too: its owner has just put a ticket out, which a list taken
        #    before that moment would miss. So look again from the start.
        L_ahead=0
        for L_e in "$L_d"/c.*; do
            L_p="${L_e##*/c.}"
            [ "$L_p" = "$$" ] || [ "$L_p" = "*" ] && continue
            if [ ! -d "$L_e" ]; then L_ahead=2
            elif lock_alive "$L_p" "$L_e"; then [ "$L_ahead" = 2 ] || L_ahead=1
            else rm -rf "$L_e"; L_ahead=2; fi
        done
        # 2. Nobody was: every run that could be ahead of me has its ticket out, and
        #    this list is taken after that was established.
        if [ "$L_ahead" = 0 ]; then
            for L_e in "$L_d"/[0-9]*.*; do
                [ -d "$L_e" ] || continue
                L_b="${L_e##*/}"; L_n="${L_b%%.*}"; L_p="${L_b#*.}"
                [ "$L_p" = "$$" ] && continue
                lock_alive "$L_p" "$L_e" || { rm -rf "$L_e"; continue; }
                if [ "$L_n" -lt "$L_mine" ] 2>/dev/null; then L_ahead=1
                elif [ "$L_n" -eq "$L_mine" ] 2>/dev/null && [ "$L_p" -lt "$$" ] 2>/dev/null; then L_ahead=1; fi
            done
            [ "$L_ahead" = 0 ] && return 0
        fi
        [ "$L_ahead" = 2 ] && continue           # something changed under us: look again at once
        [ "$L_w" -le 0 ] && { rm -rf "$L_me"; return 1; }
        L_w=$((L_w - 1)); sleep 1
    done
}
# Pid files for the helpers we start (join page, DNS over HTTPS, automatic limit):
# the pid plus its start time, so a recycled pid is never mistaken for our process.
# A file holding only a pid was written by a version before that (it is still
# running across an upgrade without a reboot): then the process counts as ours if
# its command line contains <hint>, so it is stopped and not left holding its port.
# Is the IoT network meant to be up? The setting says so, unless `iot.sh stop` took it
# down by hand ($RUN/iot.stopped): then it stays down until `start` or a reboot, even
# though the watcher keeps running for the features that don't depend on it.
iot_on() { [ "$(cfg enabled 0)" = 1 ] && [ ! -e "$RUN/iot.stopped" ]; }
pid_save() { echo "$2 $(lock_start "$2")" > "$1"; }                # pid_save <file> <pid>
pid_live() {                                                       # pid_live <file> [hint]
    pl_hint="$2"; set -- $(cat "$1" 2>/dev/null)
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
    if [ -n "$2" ]; then [ "$2" = "$(lock_start "$1")" ]; return; fi
    [ -z "$(lock_start "$1")" ] && return 0                        # no /proc here: the pid is all there is
    [ -n "$pl_hint" ] && tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q -- "$pl_hint"
}
pid_kill() { pid_live "$1" "$2" && kill "$(cut -d' ' -f1 "$1")" 2>/dev/null; rm -f "$1"; }   # pid_kill <file> [hint]
lock() { lock_at "$LOCK" "${1:-$LOCK_WAIT}"; }   # lock [seconds to wait]
cfg_lock() { lock_at "$CFGLOCK" "${1:-30}"; }
cfg_unlock() { rm -rf "$CFGLOCK"/*."$$" 2>/dev/null; return 0; }
unlock() { rm -rf "$LOCK"/*."$$" "$CFGLOCK"/*."$$" 2>/dev/null; return 0; }

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
commit_cfg() {   # commit_cfg [config]; /etc is ramfs: TP-Link's uci_commit_flash also writes flash
    if [ -x "${COMMIT_FLASH:-/sbin/uci_commit_flash}" ]; then "${COMMIT_FLASH:-/sbin/uci_commit_flash}" "${1:-openvpn}"
    else $UCI commit "${1:-openvpn}"; fi
}
# Devices removed with "Forget" (iot_forget) are not pinned again from their old
# lease; only the "allow new devices" window takes them back.
autopin() {
    [ -f "$LEASES" ] || return 0
    cfg_lock || return 0
    STATIC="$(cfg static '')"            # fresh: the dashboard may have changed it
    autopin_locked; cfg_unlock
}
autopin_locked() {
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
    H_ALLOW="$(cfg home_allow '' | tr 'A-F-' 'a-f:')"
    H_KEEP="$(cfg home_keep '' | tr 'A-F-' 'a-f:')"
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
    # Only while the lock is on: with it off the list is not in use, and a list
    # nobody is using must not shrink behind the owner's back.
    if [ "$H_LOCK" = 1 ] && [ "$H_EXPIRE" -gt 0 ] 2>/dev/null; then
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
    mkdir -p "$RUN"
    # The watcher's own list changes (last seen, expiry, un-hiding, enrollment),
    # under the settings lock and on a copy of the lists read inside it.
    cfg_lock || { home_load; return 0; }
    home_load
    conn="$(home_clients | sort -u | tr '\n' ' ')"
    gnow="$(guest_macs | sort -u | tr '\n' ' ')"
    home_seen_sync "$conn $gnow"
    unhide "$conn $gnow $(load 2>/dev/null; $WL -i "$VIF" assoclist 2>/dev/null | awk '{print tolower($2)}' | tr '\n' ' ')"
    if [ "$H_LOCK" = 1 ] && home_open_now; then
        new=""; for m in $conn; do home_listed "$m" || case " $gnow " in *" $m "*) ;; *) new="$new $m" ;; esac; done
        if [ -n "$new" ]; then H_ALLOW="$(echo $H_ALLOW $new)"; sed_seen_del $new; home_save_allow; log "added to the home allow list:$new"; fi
    fi
    cfg_unlock
    [ "$H_LOCK" = 1 ] || { home_unlock; return 0; }
    if home_open_now; then home_unlock "window open"; return 0; fi
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
portal_running() { pid_live "$RUN/portal.pid" portal/server.lua; }
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
    pid_kill "$RUN/portal.pid" portal/server.lua
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
    pid_save "$RUN/portal.pid" $!
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
# Devices forgotten on the dashboard are listed in iot_hidden_devices and stay off
# its lists while offline. (iot_hidden is something else: "hide the IoT network name".)
valid_mac() { echo "$1" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
# forget_devices <mac>[,<mac>...]: drop everything we keep for those devices: allow
# list entry and pin, speed cap, internet/speed/IoT-access settings, IoT fixed
# address (and block re-pinning), last seen. Checked as a whole before anything is
# written, saved with one commit. Custom names are cleared by the dashboard backend.
forget_devices() {
    macs=""
    for m in $(echo "$1" | tr ',A-F-' ' a-f:'); do
        valid_mac "$m" || { echo "iot.sh: bad MAC '$m'" >&2; return 1; }
        macs="$macs $m"
    done
    [ -n "$macs" ] || { echo "usage: iot.sh forget-device <mac>[,<mac>...]" >&2; return 1; }
    home_load
    a=""; for m in $H_ALLOW; do case " $macs " in *" $m "*) ;; *) a="$a $m" ;; esac; done
    k=""; for m in $H_KEEP; do case " $macs " in *" $m "*) ;; *) k="$k $m" ;; esac; done
    if [ "$H_LOCK" = 1 ] && [ -z "$(echo $a $k)" ]; then
        echo "iot.sh: that would empty the home allow list; turn the lock off first" >&2; return 1
    fi
    $UCI set "$SEC.iot_home_allow=$(echo $a)" && $UCI set "$SEC.iot_home_keep=$(echo $k)" || return 1
    # Space-separated lists whose entries start with the MAC ("mac", "mac=...", "mac,...").
    pinned=""
    for key in caps noinet guest_fast lan_allow static; do
        v="$(cfg "$key" '')"; [ -n "$v" ] || continue
        out=""; for e in $v; do
            em="$(echo "${e%%[=,]*}" | tr 'A-F-' 'a-f:')"
            case " $macs " in *" $em "*) [ "$key" = static ] && pinned="$pinned $em"; continue ;; esac
            out="$out $e"
        done
        $UCI set "$SEC.iot_$key=$(echo $out)" || return 1
    done
    fg="$(cfg forget '' | tr 'A-F-' 'a-f:')"
    for m in $pinned; do case " $fg " in *" $m "*) ;; *) fg="$fg $m" ;; esac; done
    [ -n "$pinned" ] && $UCI set "$SEC.iot_forget=$(echo $fg)"
    hd="$(cfg hidden_devices '' | tr 'A-F-' 'a-f:')"
    for m in $macs; do case " $hd " in *" $m "*) ;; *) hd="$hd $m" ;; esac; done
    $UCI set "$SEC.iot_hidden_devices=$(echo $hd)" || return 1
    sed_seen_del $macs
    commit_cfg >/dev/null || { echo "iot.sh: could not save" >&2; return 1; }
    log "forgot device(s):$macs"
}
# unhide <connected macs>: a forgotten device that is back is an ordinary device again.
unhide() {
    hd="$(cfg hidden_devices '' | tr 'A-F-' 'a-f:')"; [ -n "$hd" ] || return 0
    out=""; back=""
    for m in $hd; do case " $1 " in *" $m "*) back="$back $m" ;; *) out="$out $m" ;; esac; done
    [ -n "$back" ] || return 0
    $UCI set "$SEC.iot_hidden_devices=$(echo $out)" && commit_cfg >/dev/null
    log "forgotten device(s) back on the network:$back"
}
# entry_set <caps|noinet|guest_fast|lan_allow> <mac> <value|on|off>: change one
# device's entry in a per-device list, under the run lock, so the dashboard never
# writes a stale copy of the list. caps takes "down/up" in Mbps, or off.
entry_set() {
    case "$1" in caps|noinet|guest_fast|lan_allow) ;; *) echo "iot.sh: entry caps|noinet|guest_fast|lan_allow <mac> <value|on|off>" >&2; return 1 ;; esac
    mac="$(echo "$2" | tr 'A-F-' 'a-f:')"; valid_mac "$mac" || { echo "iot.sh: bad MAC '$2'" >&2; return 1; }
    new=""
    case "$1:$3" in
        *:off) ;;
        caps:*) echo "$3" | grep -Eq '^[0-9]{1,4}/[0-9]{1,4}$' || { echo "iot.sh: cap is down/up in Mbps" >&2; return 1; }
                [ "$3" = 0/0 ] || new="$mac=$3" ;;
        *:on) new="$mac" ;;
        *) return 1 ;;
    esac
    out=""; for e in $(cfg "$1" ''); do
        [ "$(echo "${e%%[=,]*}" | tr 'A-F-' 'a-f:')" = "$mac" ] || out="$out $e"
    done
    $UCI set "$SEC.iot_$1=$(echo $out $new)" || return 1
    # Giving a forgotten device a setting brings it back onto the lists.
    hd=""; for m in $(cfg hidden_devices '' | tr 'A-F-' 'a-f:'); do [ "$m" = "$mac" ] || hd="$hd $m"; done
    $UCI set "$SEC.iot_hidden_devices=$(echo $hd)"
    commit_cfg >/dev/null || return 1
}
# ------------------------------------------------------------- data usage
# How much data the household uses: per day and per month in total (from the
# internet connection's own counters, so every device counts), and per device per
# month for devices on the main router's Wi-Fi (from the radio's counters; devices
# on the mesh satellite or a cable can't be told apart here and show as "other").
# The log lives in $RUN/usage as lines "<key> <down bytes> <up bytes>":
#   T:2026-11-12        a day's total        (kept 62 days)
#   M:2026-11           a month's total      (kept 24 months)
#   D:2026-11:<mac>     a device in a month  (this month and the last)
# and is saved to flash once an hour (in MB, iot_usage_*), so a reboot loses at most
# the last hour. Counters restart on a reboot or reconnect; a reading lower than the
# last one is taken as a fresh count.
# The first reading after a start needs care, because the "last readings" file is in
# RAM. If it is missing and this is a new boot (iot_usage_boot in flash names another
# one), the counters began with the boot and all of it is new usage. If it is missing
# for any other reason (the feature's very first run on a router that has been up for
# days, or the file was lost), the counters hold history that was never ours or was
# counted already: that reading only sets the baseline.
WAN_DEV="${WAN_DEV:-}"
usage_wan() {
    [ -n "$WAN_DEV" ] && { echo "$WAN_DEV"; return; }
    ubus call network.interface.internet status 2>/dev/null | sed -n 's/.*"l3_device": "\([^"]*\)".*/\1/p'
}
usage_load() {   # the log as saved in flash -> $RUN/usage (bytes)
    { for e in $(cfg usage_days ''); do echo "T:${e%%=*} ${e#*=}"; done
      for e in $(cfg usage_months ''); do echo "M:${e%%=*} ${e#*=}"; done
      for e in $(cfg usage_devs ''); do echo "D:${e%%=*} ${e#*=}"; done
    } | awk '{ split($2, v, "/"); if (v[1] ~ /^[0-9]+$/ && v[2] ~ /^[0-9]+$/) printf "%s %.0f %.0f\n", $1, v[1] * 1048576, v[2] * 1048576 }' > "$RUN/usage"
}
usage_save() {   # $RUN/usage -> flash, in whole MB
    pick() { awk -v p="$1" 'index($1, p) == 1 { printf "%s=%.0f/%.0f ", substr($1, 3), $2 / 1048576, $3 / 1048576 }' "$RUN/usage" | sed 's/ $//'; }
    $UCI set "$SEC.iot_usage_days=$(pick T:)"; $UCI set "$SEC.iot_usage_months=$(pick M:)"; $UCI set "$SEC.iot_usage_devs=$(pick D:)"
    commit_cfg >/dev/null
}
usage_on() { [ "$(cfg usage_on 1)" = 1 ]; }       # counting is on unless iot_usage_on=0
usage_sync() {
    usage_on || return 0
    [ -n "$(epoch)" ] || return 0                 # no clock yet: nothing to file a reading under
    mkdir -p "$RUN"; [ -f "$RUN/usage" ] || usage_load
    day="${USAGE_DAY:-$(date +%Y-%m-%d)}"; wd="$(usage_wan)"
    { [ -n "$wd" ] && [ -r "$NET/$wd/statistics/rx_bytes" ] &&
          echo "C wan $(cat "$NET/$wd/statistics/rx_bytes") $(cat "$NET/$wd/statistics/tx_bytes")"
      # the home, guest and IoT radios' clients: bytes sent to them / received from them
      for i in $(cfg home_ifs 'wl0.1 wl1.1') $(guest_ifs) "$(cfg vif wl1.4)"; do
          [ -d "$NET/$i" ] || continue
          for m in $($WL -i "$i" assoclist 2>/dev/null | awk '{print $2}'); do
              $WL -i "$i" sta_info "$m" 2>/dev/null | awk -v m="$m" '/tx total bytes:/ {t=$4} /rx data bytes:/ {r=$4} END { if (t != "" && r != "") printf "C %s %.0f %.0f\n", tolower(m), t, r }'
          done
      done
    } > "$RUN/usage.cur"
    base=0; boot="${USAGE_BOOT:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)}"
    if [ ! -f "$RUN/usage.last" ]; then
        : > "$RUN/usage.last"
        was="$(cfg usage_boot '')"
        # a new boot only if an earlier one was recorded and it is not this one
        if [ -z "$was" ] || [ -z "$boot" ] || [ "$was" = "$boot" ]; then base=1; fi
        [ "$was" = "$boot" ] || { $UCI set "$SEC.iot_usage_boot=$boot" && commit_cfg >/dev/null; }
    fi
    # Counting is under way in this boot: make sure flash says so (written once per boot).
    [ "$base" = 0 ] && [ -n "$boot" ] && [ "$(cfg usage_boot '')" != "$boot" ] && { $UCI set "$SEC.iot_usage_boot=$boot" && commit_cfg >/dev/null; }
    awk -v day="$day" -v base="$base" -v lastf="$RUN/usage.last" -v curf="$RUN/usage.cur" '
        BEGIN {
            month = substr(day, 1, 7)
            while ((getline l < lastf) > 0) { split(l, a, " "); ld[a[1]] = a[2]; lu[a[1]] = a[3]; seen[a[1]] = 1 }
            while ((getline l < curf) > 0) {
                split(l, a, " "); id = a[2]; d = a[3] + 0; u = a[4] + 0
                # known reading: the growth, or all of it if the counter restarted.
                # unknown: all of it (a device that has just connected), unless this
                # run only sets baselines.
                dd = seen[id] ? (d >= ld[id] ? d - ld[id] : d) : (base ? 0 : d)
                du = seen[id] ? (u >= lu[id] ? u - lu[id] : u) : (base ? 0 : u)
                ld[id] = d; lu[id] = u; seen[id] = 1
                if (id == "wan") { add("T:" day, dd, du); add("M:" month, dd, du) }
                else add("D:" month ":" id, dd, du)
            }
            for (id in seen) printf "%s %.0f %.0f\n", id, ld[id], lu[id] > (lastf ".new")
        }
        function add(k, d, u) { nd[k] += d; nu[k] += u }
        { k = $1; if (!(k in out)) order[++n] = k; out[k] = 1; D[k] = $2 + nd[k]; U[k] = $3 + nu[k]; delete nd[k]; delete nu[k] }
        END {
            for (k in nd) { order[++n] = k; D[k] = nd[k]; U[k] = nu[k] }
            for (i = 1; i <= n; i++) printf "%s %.0f %.0f\n", order[i], D[order[i]], U[order[i]]
        }' "$RUN/usage" > "$RUN/usage.new" && mv "$RUN/usage.new" "$RUN/usage" && mv "$RUN/usage.last.new" "$RUN/usage.last"
    # Keep 62 days, 24 months, and devices for this month and the last.
    now="$(epoch)"
    dcut="$(date -d "@$((now - 62 * 86400))" +%Y-%m-%d 2>/dev/null)"; mcut="$(date -d "@$((now - 730 * 86400))" +%Y-%m 2>/dev/null)"
    uy="${day%%-*}"; um="${day#*-}"; um="${um%%-*}"; um=$((1$um - 100))      # "03" -> 3 (no octal surprises)
    if [ "$um" = 1 ]; then pm="$((uy - 1))-12"; else pm="$(printf '%04d-%02d' "$uy" "$((um - 1))")"; fi
    if [ -n "$dcut" ] && [ -n "$mcut" ] && [ -n "$pm" ]; then
        awk -v dcut="T:$dcut" -v mcut="M:$mcut" -v m1="D:${day%-*}:" -v m2="D:$pm:" '
            /^T:/ { if ($1 >= dcut) print; next } /^M:/ { if ($1 >= mcut) print; next }
            /^D:/ { if (index($1, m1) == 1 || index($1, m2) == 1) print; next }' "$RUN/usage" | sort > "$RUN/usage.new" && mv "$RUN/usage.new" "$RUN/usage"
    fi
    # To flash once an hour.
    last="$(cat "$RUN/usage.saved" 2>/dev/null)"
    if [ $((now - ${last:-0})) -ge 3600 ]; then usage_save; echo "$now" > "$RUN/usage.saved"; fi
}
# "Apply what is saved, soon": what the dashboard asks for after every change.
# Each plain `sync` would wait its turn for the run lock, so a burst of changes left a
# queue of them. Here a request leaves a note (sync.want); one worker runs until no
# note is left, so the last change is always applied, in one or two runs however many
# requests there were. Who the worker is, and when it goes, is settled under a small
# lock of its own (KICKLOCK), which makes two things impossible:
#   - two requests both becoming the worker (looking for one and becoming one are
#     a single step under the lock);
#   - a request slipping in while the worker leaves (the worker looks for a note and
#     gives up its place in one step under the same lock, and a request files its
#     note before it looks for the worker: it either sees a worker that has yet to
#     take its last look, or none, and then it is the worker).
KICKLOCK="$RUN/kicklocks"
kick_unlock() { rm -rf "$KICKLOCK"/*."$$" 2>/dev/null; return 0; }
kick_mine() { [ "$(cut -d' ' -f1 "$RUN/sync.pid" 2>/dev/null)" = "$$" ]; }
kick_bye() { kick_mine && rm -f "$RUN/sync.pid"; unlock; kick_unlock; }
kick_run() {
    mkdir -p "$RUN"; : > "$RUN/sync.want"
    lock_at "$KICKLOCK" 15 || return 0           # can't ask right now: the note stays for the next worker or the watcher
    if pid_live "$RUN/sync.pid" "iot.sh"; then kick_unlock; return 0; fi
    pid_save "$RUN/sync.pid" $$
    kick_unlock
    trap kick_bye EXIT
    kfail=0
    while :; do
        lock_at "$KICKLOCK" 15 || break
        if [ ! -e "$RUN/sync.want" ] || [ "$kfail" -ge 3 ]; then
            [ "$kfail" -ge 3 ] && log "could not get the run lock for 3 tries; left the changes for the next run"
            kick_mine && rm -f "$RUN/sync.pid"
            kick_unlock; break
        fi
        rm -f "$RUN/sync.want"; kick_unlock
        if lock; then run_all; watcher_sync; unlock; kfail=0
        else : > "$RUN/sync.want"; kfail=$((kfail + 1)); fi      # not applied: the request stands
    done
    trap - EXIT; kick_bye
}
# The watcher is what makes saved settings take effect and keeps them in place, and
# the fallback for every "apply soon" request that did not get through (a worker
# killed, a lock it could not get): it always runs. With every feature off a pass is
# a few settings read and nothing else.
watcher_wanted() { return 0; }
# Everything the watcher keeps in place, each part only while it is switched on.
# Local names and DNS over HTTPS don't need the IoT network: apply() covers them
# when it runs, names_sync when it doesn't.
# Speed limits, the home allow list and the usage log are not part of the IoT
# network either: they run whether it is on or off.
run_all() {
    if iot_on; then apply
    else
        # Switched off in the settings while it is still up: take it down here, so
        # "off" needs no command of its own (the dashboard only saves and asks for a sync).
        # "Still up" is read off the router itself (the slot sitting in the IoT bridge),
        # not only off our own note, which a killed run may never have written.
        load
        if [ -s "$RUN/orig_bridge" ] || [ "$(bridge_of "$VIF")" = "$BR" ]; then iot_teardown; fi
        names_sync
    fi
    shape_sync
    home_sync
    usage_sync
}
shaping_wanted() { [ "$(cfg wan_shape 0)" = 1 ] || [ "$(cfg guest_limit 0)" = 1 ] || [ -n "$(cfg caps '')" ]; }
# The watcher is registered exactly while something needs it. Only under the run lock.
watcher_sync() {
    if watcher_wanted; then grep -q "$TAG" "$INITTAB" 2>/dev/null || { inittab_add; log "watcher registered"; }
    else inittab_del; fi
}

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
# ------------------------------------------------------------- local names
# Names for the router and the devices under a private suffix (iot_dns_domain,
# default "home"), served by the router's own dnsmasq, the way Pi-hole does it:
#   router.home         the router (iot_dns_router, several names allowed)
#   <hostname>.home     every device, by the name it gave DHCP (dnsmasq does this
#                       itself once it has a domain)
#   <dashboard name>.home, and custom records (iot_dns_hosts "name=ip ...")
# For any of it to resolve, devices must ask the router: DHCP hands out the router
# as DNS server (the stock setting dhcp.lan.dhcp_option, also shown in TP-Link's
# DHCP page), and the IPv6 DNS servers TP-Link advertises over DHCPv6 are withdrawn
# (a device would ask those first and never see a local name). The router forwards
# everything else to iot_dns_upstream. Not ".local": that suffix belongs to mDNS and
# Apple devices never ask a DNS server for it.
DHCP6S_CONF="${DHCP6S_CONF:-/etc/dhcp6s.conf}"
DHCP6S_INIT="${DHCP6S_INIT:-/etc/init.d/dhcp6s}"
NL='
'
dns_load() {
    DNS_ON="$(cfg dns_on 0)"
    # Whatever is saved, dnsmasq only ever gets a clean suffix and IPv4 upstream
    # servers: a line it can't parse stops it, and with it DNS for the whole house.
    DNS_DOMAIN="$(dns_label "$(cfg dns_domain home)")"
    case "$DNS_DOMAIN" in ''|local) DNS_DOMAIN=home ;; esac
    DNS_ROUTER="$(cfg dns_router router)"
    DNS_HOSTS="$(cfg dns_hosts '')"
    DNS_UP=""; for u in $(cfg dns_upstream '1.1.1.1 1.0.0.1'); do
        valid_ip4 "$u" && DNS_UP="$DNS_UP $u"
    done; DNS_UP="$(echo $DNS_UP)"
    LAN_IP="$($UCI -q get network.lan.ipaddr)"; LAN_IP="${LAN_IP:-192.168.0.1}"
}
# A name as a DNS label: lower case, letters digits and dashes.
# (Line breaks go first: sed and cut work line by line and would pass them through.)
dns_label() { printf '%s' "$1" | tr -d '\n\r' | tr 'A-Z _.' 'a-z---' | sed 's/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-63; }
valid_ip4() {   # four numbers 0-255, nothing else
    case "$1" in *[!0-9.]*|'') return 1 ;; esac
    echo "$1" | awk -F. 'NF != 4 { exit 1 } { for (i = 1; i <= 4; i++) if ($i == "" || $i > 255) exit 1 }'
}
dns_hosts() {   # the hosts file: router names, custom records, dashboard names of devices with a lease
    for n in $DNS_ROUTER; do l="$(dns_label "$n")"; [ -n "$l" ] && echo "$LAN_IP $l.$DNS_DOMAIN"; done
    for e in $DNS_HOSTS; do
        l="$(dns_label "${e%%=*}")"; ip="${e#*=}"
        valid_ip4 "$ip" && [ -n "$l" ] && echo "$ip $l.$DNS_DOMAIN"
    done
    [ -f "$LEASES" ] || return 0
    $UCI -q -d "$NL" get "$SEC.iot_names" 2>/dev/null | while IFS= read -r e; do
        mac="$(echo "${e%%=*}" | tr 'A-F-' 'a-f:')"; l="$(dns_label "${e#*=}")"; [ -n "$l" ] || continue
        ip="$(awk -v m="$mac" 'tolower($2)==m {print $3; exit}' "$LEASES")"
        valid_ip4 "$ip" && echo "$ip $l.$DNS_DOMAIN"
    done
}
dns_block() {   # dnsmasq lines, inside our block in dnsmasq.conf
    [ "$DNS_ON" = 1 ] || return 0
    echo "domain=$DNS_DOMAIN"
    echo "local=/$DNS_DOMAIN/"
    echo "addn-hosts=$RUN/hosts"
    if [ -e "$RUN/doh.ok" ]; then echo "no-resolv"; echo "server=127.0.0.1#$DOH_PORT"
    elif [ -n "$DNS_UP" ]; then echo "no-resolv"; for u in $DNS_UP; do echo "server=$u"; done; fi
}
# DNS over HTTPS (iot_dns_doh=1, needs local names on): the router's upstream lookups
# go through iot-ui/doh.lua, a small forwarder on 127.0.0.1:$DOH_PORT that sends them
# encrypted to one provider, with the server's certificate and name verified. While
# the forwarder answers, dnsmasq uses only it; while it doesn't (no internet yet, the
# clock not set at boot so certificates look invalid, provider down), dnsmasq falls
# back to the plain servers, so the house never loses DNS because of this.
DOH_PORT="${DOH_PORT:-5053}"
doh_provider() {   # "<ip> <name>" of the chosen provider
    case "$(cfg dns_doh_provider cloudflare)" in
        google) echo "8.8.8.8 dns.google" ;;
        quad9)  echo "9.9.9.9 dns.quad9.net" ;;
        *)      echo "1.1.1.1 cloudflare-dns.com" ;;
    esac
}
doh_running() { pid_live "$RUN/doh.pid" doh.lua; }
doh_stop() {
    # Its TLS connections (openssl children) end by themselves when it does: they
    # run with -no_ign_eof and their input is a pipe from it.
    pid_kill "$RUN/doh.pid" doh.lua
    rm -f "$RUN/doh.ok" "$RUN/doh.sig" "$RUN/doh.stat"
}
doh_sync() {
    if [ "$DNS_ON" != 1 ] || [ "$(cfg dns_doh 0)" != 1 ] || [ ! -f "$UI_SRC/doh.lua" ] || [ ! -f "$UI_SRC/cacert.pem" ]; then
        [ -e "$RUN/doh.pid" ] && { doh_stop; log "DNS over HTTPS off"; }
        return 0
    fi
    set -- $(doh_provider)
    if ! doh_running || [ "$1 $2" != "$(cat "$RUN/doh.sig" 2>/dev/null)" ]; then
        doh_stop
        $LUA "$UI_SRC/doh.lua" "$DOH_PORT" "$1" "$2" "$UI_SRC/cacert.pem" "$RUN/doh.stat" >/dev/null 2>&1 &
        pid_save "$RUN/doh.pid" $!; echo "$1 $2" > "$RUN/doh.sig"
        sleep "${DOH_WARMUP:-2}"
    fi
    if $LUA "$UI_SRC/doh.lua" check "$DOH_PORT" >/dev/null 2>&1; then
        [ -e "$RUN/doh.ok" ] || { : > "$RUN/doh.ok"; log "DNS over HTTPS working ($2)"; }
    elif [ -e "$RUN/doh.ok" ]; then
        rm -f "$RUN/doh.ok"; log "DNS over HTTPS not answering; using the plain DNS servers until it does"
    fi
}
dns_sync() {
    dns_load; mkdir -p "$RUN"
    doh_sync
    # Which DNS server DHCP hands out: the router while this is on; the upstream
    # servers again when it is switched off (only if it still points at the router).
    cur="$($UCI -q get dhcp.lan.dhcp_option)"; six=""; rest=""
    for o in $cur; do case "$o" in 6,*) six="$o" ;; *) rest="$rest $o" ;; esac; done
    # What was there before is kept in iot_dns_prev6 ("none" if no DNS option was
    # set) and put back on switching off, if the setting still points at the router.
    want="$six"; prev="$(cfg dns_prev6 '')"
    if [ "$DNS_ON" = 1 ]; then
        want="6,$LAN_IP"
        if [ "$six" != "$want" ]; then $UCI set "$SEC.iot_dns_prev6=${six:-none}" && commit_cfg >/dev/null; fi
    elif [ "$six" = "6,$LAN_IP" ] && [ -n "$prev" ]; then
        case "$prev" in none) want="" ;; 6,*) want="$prev" ;; esac
    fi
    if [ "$want" != "$six" ]; then
        $UCI set "dhcp.lan.dhcp_option=$(echo $rest $want)" && commit_cfg dhcp >/dev/null
        [ "$DNS_ON" = 1 ] || { $UCI set "$SEC.iot_dns_prev6=" && commit_cfg >/dev/null; }
        dnsmasq_restart
        log "DHCP now hands out ${want:+${want#6,} as }${want:-no particular} DNS server"
    fi
    # IPv6: withdraw the DNS servers handed out over DHCPv6 while this is on.
    if [ -f "$DHCP6S_CONF" ]; then
        if [ "$DNS_ON" = 1 ] && grep -q '^option domain-name-servers' "$DHCP6S_CONF"; then
            grep -v '^option domain-name-servers' "$DHCP6S_CONF" > "$RUN/dhcp6s.new"; cat "$RUN/dhcp6s.new" > "$DHCP6S_CONF"; rm -f "$RUN/dhcp6s.new"
            : > "$RUN/dhcp6s.stripped"
            p6="$(cat /var/run/dhcp6s.pid 2>/dev/null)"
            if [ -n "$p6" ] && kill "$p6" 2>/dev/null; then sleep 1; /usr/sbin/dhcp6s -c "$DHCP6S_CONF" -P /var/run/dhcp6s.pid "$LANBR" >/dev/null 2>&1; fi
            log "IPv6 DNS servers no longer advertised: devices ask the router"
        elif [ "$DNS_ON" != 1 ] && [ -e "$RUN/dhcp6s.stripped" ]; then
            rm -f "$RUN/dhcp6s.stripped"
            [ -x "$DHCP6S_INIT" ] && "$DHCP6S_INIT" restart >/dev/null 2>&1
            log "IPv6 DNS servers advertised again"
        fi
    fi
    # TP-Link's "dnsproxy" does not proxy: its nat chain prerouting_rule_dns sends
    # every query addressed to the router on to the ISP's DNS server, so dnsmasq never
    # sees one from the LAN and no local name could resolve. An ACCEPT at the top of
    # that chain ends NAT for those packets, and they reach dnsmasq. (TP-Link rebuilds
    # the chain when the internet connection changes; checked every run.)
    for pr in udp tcp; do
        if [ "$DNS_ON" = 1 ]; then
            $IPT -t nat -C prerouting_rule_dns -i "$LANBR" -d "$LAN_IP" -p $pr --dport 53 -j ACCEPT 2>/dev/null ||
                { $IPT -t nat -I prerouting_rule_dns 1 -i "$LANBR" -d "$LAN_IP" -p $pr --dport 53 -j ACCEPT 2>/dev/null && dnsfix=1; }
        else
            while $IPT -t nat -D prerouting_rule_dns -i "$LANBR" -d "$LAN_IP" -p $pr --dport 53 -j ACCEPT 2>/dev/null; do dnsfix=1; done
        fi
    done
    if [ -n "$dnsfix" ]; then
        dnsfix=""; command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
        [ "$DNS_ON" = 1 ] && log "DNS queries from the home network now reach the router's own DNS"
    fi
    # The hosts file; dnsmasq re-reads it on SIGHUP.
    if [ "$DNS_ON" = 1 ]; then
        dns_hosts | sort -u > "$RUN/hosts.new"
        if cmp -s "$RUN/hosts.new" "$RUN/hosts" 2>/dev/null; then rm -f "$RUN/hosts.new"
        else mv "$RUN/hosts.new" "$RUN/hosts"; ${DNSMASQ_HUP:-killall -HUP dnsmasq} 2>/dev/null; fi
    fi
}
dhcp_block() {
    echo "$MARK_BEGIN"
    if iot_on; then
        echo "dhcp-range=set:iot,$START,$END,255.255.255.0,12h"
        echo "dhcp-option=tag:iot,3,$GW"
        echo "dhcp-option=tag:iot,6,$(echo $DNS | tr ' ' ',')"
        for s in $STATIC; do echo "dhcp-host=${s%%,*},${s#*,}"; done
    fi
    dns_block
    echo "$MARK_END"
}
# Local names and DNS over HTTPS without the IoT network: the same two steps apply() does.
names_sync() { load; dns_sync; dhcp_sync; }
dhcp_strip() { sed "/^$MARK_BEGIN\$/,/^$MARK_END\$/d" "$DNSMASQ_CONF"; }
dnsmasq_restart() {
    if [ -x "$DNSMASQ_INIT" ]; then "$DNSMASQ_INIT" restart >/dev/null 2>&1
    else
        killall dnsmasq 2>/dev/null; sleep 1
        /usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf
    fi
}
# Make the block match the current settings; restart dnsmasq only if it changed.
# dnsmasq checks the result first (--test): a line it can't read would stop it, and
# with it DHCP and DNS for the whole house, so such a block is never left in place.
DNSMASQ_BIN="${DNSMASQ_BIN:-/usr/sbin/dnsmasq}"
DNSMASQ_MAIN="${DNSMASQ_MAIN:-/var/etc/dnsmasq.conf}"
dnsmasq_ok() { [ -x "$DNSMASQ_BIN" ] || return 0; "$DNSMASQ_BIN" --test -C "$DNSMASQ_MAIN" >/dev/null 2>&1; }
dhcp_sync() {
    want="$(dhcp_block)"
    have="$(sed -n "/^$MARK_BEGIN\$/,/^$MARK_END\$/p" "$DNSMASQ_CONF" 2>/dev/null)"
    [ "$want" = "$have" ] && return 0
    # Nothing to say: no block at all. Not there: leave the file alone. There: take it out.
    if [ "$want" = "$MARK_BEGIN$NL$MARK_END" ]; then
        [ -z "$have" ] && return 0
        dhcp_remove; log "dnsmasq settings removed"; return 0
    fi
    [ "$want" = "$(cat "$RUN/dnsmasq.bad" 2>/dev/null)" ] && return 0     # already refused, said so once
    cat "$DNSMASQ_CONF" > "$RUN/dnsmasq.conf.old" 2>/dev/null
    { dhcp_strip; echo "$want"; } > "$RUN/dnsmasq.conf.new" && cat "$RUN/dnsmasq.conf.new" > "$DNSMASQ_CONF"
    rm -f "$RUN/dnsmasq.conf.new"
    if ! dnsmasq_ok; then
        cat "$RUN/dnsmasq.conf.old" > "$DNSMASQ_CONF"; rm -f "$RUN/dnsmasq.conf.old"
        echo "$want" > "$RUN/dnsmasq.bad"
        log "dnsmasq refused the new settings; kept the old ones (check the local-names and IoT address settings)"
        return 1
    fi
    rm -f "$RUN/dnsmasq.conf.old" "$RUN/dnsmasq.bad"
    dnsmasq_restart && log "dnsmasq settings updated$(iot_on && echo " (IoT addresses $START-$END)")"
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
    # Automatic whole-connection limit (iot-ui/autorate.lua): wan_down/up are the
    # usual speeds it starts from; it stays between the min and max.
    WS_AUTO="$(cfg wan_auto 0)"
    WS_MIN_D="$(cfg wan_min_down '')"; WS_MAX_D="$(cfg wan_max_down '')"
    WS_MIN_U="$(cfg wan_min_up '')"; WS_MAX_U="$(cfg wan_max_up '')"
}
# Range for the automatic limit: what was set, else half to three times the usual speed.
auto_range() {   # auto_range <usual> <min> <max> -> "min max", sane whatever was saved
    lo="$2"; hi="$3"
    case "$lo" in ''|*[!0-9]*) lo=$(($1 / 2)) ;; esac
    case "$hi" in ''|*[!0-9]*) hi=$(($1 * 3)) ;; esac
    [ "$lo" -ge 1 ] || lo=1; [ "$lo" -le "$1" ] || lo="$1"
    [ "$hi" -ge "$1" ] || hi="$1"; [ "$hi" -le 1000 ] || hi=1000
    echo "$lo $hi"
}
# The lanes' rates, changed in place: `sh rate.sh <down kbit> <up kbit>`. Written when
# the lanes are built, with their layout (priority lane, guest lane) baked in, so the
# controller does not have to load all of iot.sh once a second.
rate_script() {   # rate_script <prio 0|1> <low 0|1>
    cat > "$RUN/rate.sh.new" <<EOF
#!/bin/sh
# Written by iot.sh shape_sync. rate.sh <down kbit> <up kbit>
set_rate() {
    t=\$2; [ "\$t" -ge 500 ] 2>/dev/null || return 1
    b=\$((t * 5 / 2)); [ \$b -ge 15000 ] || b=15000; bb="burst \$b cburst \$b"
    $TC class change dev \$1 parent 1: classid 1:1 htb rate \${t}kbit ceil \${t}kbit \$bb || return 1
    hi=0; gs=0
    [ $1 = 1 ] && hi=\$((t * 40 / 100))
    [ $2 = 1 ] && gs=\$((t / 10))
    lo=\$((t - hi - gs))
    [ $1 = 1 ] && $TC class change dev \$1 parent 1:1 classid 1:2 htb rate \${hi}kbit ceil \${t}kbit \$bb prio 0
    if [ $1 = 1 ] || [ $2 = 1 ]; then $TC class change dev \$1 parent 1:1 classid 1:10 htb rate \${lo}kbit ceil \${t}kbit \$bb prio 1
    else $TC class change dev \$1 parent 1:1 classid 1:10 htb rate \${t}kbit ceil \${t}kbit \$bb; fi
    if [ $2 = 1 ]; then
        $TC class change dev \$1 parent 1:1 classid 1:3 htb rate \${gs}kbit ceil \${t}kbit \$bb prio 2
        $TC class change dev \$1 parent 1:3 classid 1:4 htb rate \${gs}kbit ceil \${t}kbit \$bb prio 2
    fi
    return 0
}
set_rate $LANBR "\$1" && set_rate $IFB "\$2"
EOF
    mv "$RUN/rate.sh.new" "$RUN/rate.sh"
}
auto_running() { pid_live "$RUN/autorate.pid" autorate.lua; }
auto_stop() {   # auto_stop [keep]: "keep" leaves the last rates for a restart to carry on from
    pid_kill "$RUN/autorate.pid" autorate.lua; rm -f "$RUN/autorate.sig"
    [ "$1" = keep ] || rm -f "$RUN/autorate.stat"
}
# Keep the controller running while the automatic limit is on (called after the
# lanes are in place). It restarts from the usual speeds whenever the lanes were rebuilt.
auto_sync() {   # auto_sync <wan 0|1> <rebuilt 0|1>
    if [ "$1" != 1 ] || [ "$WS_AUTO" != 1 ] || [ ! -f "$UI_SRC/autorate.lua" ] || [ ! -f "$RUN/rate.sh" ]; then
        if [ -e "$RUN/autorate.pid" ]; then
            auto_stop; log "automatic speed limit off"
            # The lanes still carry whatever rate it had reached: back to the fixed
            # speeds. If that can't be done in place, have the lanes rebuilt.
            if [ "$1" = 1 ] && [ "$2" != 1 ]; then
                sh "$RUN/rate.sh" "$((WS_DOWN * 1000))" "$((WS_UP * 1000))" >/dev/null 2>&1 || rm -f "$RUN/shape.sig"
            fi
        fi
        return 0
    fi
    set -- "$2" $(auto_range "$WS_DOWN" "$WS_MIN_D" "$WS_MAX_D") $(auto_range "$WS_UP" "$WS_MIN_U" "$WS_MAX_U")
    asig="$WS_DOWN $WS_UP $2 $3 $4 $5"
    if [ "$1" = 1 ] || ! auto_running || [ "$asig" != "$(cat "$RUN/autorate.sig" 2>/dev/null)" ]; then
        if [ "$asig" = "$(cat "$RUN/autorate.sig" 2>/dev/null)" ]; then auto_stop keep; else auto_stop; fi
        $LUA "$UI_SRC/autorate.lua" "$RUN/rate.sh" "$RUN/autorate.stat" "$LANBR" "$IFB" "$WS_DOWN" "$WS_UP" "$2" "$3" "$4" "$5" >/dev/null 2>&1 &
        pid_save "$RUN/autorate.pid" $!; echo "$asig" > "$RUN/autorate.sig"
        log "automatic speed limit on: download $2-$3 Mbps, upload $4-$5 Mbps, starting at $WS_DOWN/$WS_UP"
    fi
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
        auto_sync 0 0
        return 0
    fi
    sig="$wan|$WS_DOWN|$WS_UP|$prio|$low|$gl|$(echo $list)"
    if [ "$(cat "$RUN/shape.sig" 2>/dev/null)" = "$sig" ] && shape_ok; then
        # Lanes built by an older version have no rate script yet.
        [ "$wan" = 1 ] && [ ! -f "$RUN/rate.sh" ] && rate_script "$prio" "$low"
        auto_sync "$wan" 0; return 0
    fi
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
    if [ "$wan" = 1 ]; then rate_script "$prio" "$low"; else rm -f "$RUN/rate.sh"; fi
    auto_sync "$wan" 1
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
    # Where the slot came from is written down before it is moved (a run killed in
    # between must not leave it moved with nothing to say so), and written again if
    # it is found moved without the note.
    if [ "$cur" != "$BR" ]; then
        [ -s "$RUN/orig_bridge" ] || echo "${cur:-br-lan}" > "$RUN/orig_bridge"
        [ -n "$cur" ] && $BRCTL delif "$cur" "$VIF"
        $BRCTL addif $BR "$VIF" && log "moved $VIF from ${cur:-none} to $BR"
    elif [ ! -s "$RUN/orig_bridge" ]; then echo br-lan > "$RUN/orig_bridge"; fi
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
    dns_sync
    dhcp_sync
    lock_sync
    guest_wifi_open
}

stop() { inittab_del; iot_teardown; }
# Take the IoT network down (the watcher's registration is the caller's business).
iot_teardown() {
    load
    # dnsmasq: the block as it should be now, in one go. The IoT lines leave it
    # (iot_on is false here), the local-names lines stay, and it restarts once.
    dns_load; dhcp_sync
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
# inittab is rewritten in place (cat > it), so two writers at once could leave it
# empty: only commands holding the run lock call these, and each uses its own temp file.
inittab_add() {
    { grep -v "$TAG" "$INITTAB" 2>/dev/null; echo "::respawn:/bin/sh $SELF watch # $TAG"; } > "$INITTAB.new.$$"
    [ -s "$INITTAB.new.$$" ] && cat "$INITTAB.new.$$" > "$INITTAB"; rm -f "$INITTAB.new.$$"; $INIT_HUP 2>/dev/null
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
    grep -v "$TAG" "$INITTAB" > "$INITTAB.new.$$"; cat "$INITTAB.new.$$" > "$INITTAB"; rm -f "$INITTAB.new.$$"
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
# TP-Link's WAN IPv6 client (dhcp6c) can abort as the PPPoE link comes up at boot
# (seen 2026-11-12: a core dump one minute after boot, before any of our code ran).
# Nothing restarts it, and the router is left without an IPv6 default route or a
# prefix for the LAN until the next reconnect: IPv6 is simply dead in the house.
# If its config is in place (TP-Link removes it when the link goes down) and it is
# not running on two checks in a row, start it the way /lib/netifd/pppshare-up does.
DHCP6C_DIR="${DHCP6C_DIR:-/tmp/dhcp6c}"
DHCP6C_BIN="${DHCP6C_BIN:-/usr/sbin/dhcp6c}"
PIDOF="${PIDOF:-pidof}"
# TP-Link starts the client itself whenever the link comes up, so this must never add
# a second one next to it:
#   - the config must be the same file on both checks (TP-Link rewrites it on every
#     connect, so a changed one means a connect is in progress: start over);
#   - it is looked for again right before starting, and again two seconds after: if
#     TP-Link's own has appeared in the meantime, ours is the one that goes;
#   - after a restart that did not hold, the next try waits longer each time (2, 4,
#     8 ... 64 minutes), so a client that keeps crashing is not restarted in a loop.
d6_state() {   # D6_TRIES (0..6) and D6_UNTIL from $RUN/dhcp6c.tries; anything else in there is thrown away
    D6_TRIES=0; D6_UNTIL=0
    [ -f "$RUN/dhcp6c.tries" ] || return 0
    read -r D6_TRIES D6_UNTIL _rest < "$RUN/dhcp6c.tries"
    case "$D6_TRIES" in ''|*[!0-9]*) D6_TRIES=bad ;; esac
    case "$D6_UNTIL" in ''|*[!0-9]*) D6_TRIES=bad ;; esac
    if [ "$D6_TRIES" = bad ] || [ "${#D6_TRIES}" -gt 2 ] || [ "${#D6_UNTIL}" -gt 12 ]; then D6_TRIES=0; D6_UNTIL=0; rm -f "$RUN/dhcp6c.tries"; return 0; fi
    [ "$D6_TRIES" -le 6 ] || D6_TRIES=6
}
ipv6_guard() {
    c="$DHCP6C_DIR/dhcp6c.conf"
    if [ ! -f "$c" ] || [ ! -x "$DHCP6C_BIN" ]; then rm -f "$RUN/dhcp6c.miss"; return 0; fi
    if $PIDOF dhcp6c >/dev/null 2>&1; then
        rm -f "$RUN/dhcp6c.miss"
        # running for a while since our last restart: that one held
        d6_state; [ "$D6_TRIES" -gt 0 ] && [ "$(now_s)" -ge "$D6_UNTIL" ] && rm -f "$RUN/dhcp6c.tries"
        return 0
    fi
    id="$(ls -li "$c" 2>/dev/null | awk '{print $1, $6, $7, $8, $9}') $(cksum < "$c" 2>/dev/null)"
    if [ "$(cat "$RUN/dhcp6c.miss" 2>/dev/null)" != "$id" ]; then echo "$id" > "$RUN/dhcp6c.miss"; return 0; fi   # first miss with this config
    d6_state
    [ "$(now_s)" -ge "$D6_UNTIL" ] || return 0                               # still backing off
    rm -f "$RUN/dhcp6c.miss"
    [ "$($UCI -q get network.wan.type)" = bridge ] && return 0              # IPTV bridge mode uses another port; leave it
    ifn="$(sed -n 's/^interface \([^ ]*\) {.*/\1/p' "$c" | head -n1)"
    wif="$($UCI -q get network.wan.ifname)"
    [ -n "$ifn" ] && [ -n "$wif" ] && [ -d "$NET/$ifn" ] || return 0
    $PIDOF dhcp6c >/dev/null 2>&1 && return 0                               # it has just been started for us
    [ -f "$c" ] || return 0
    "$DHCP6C_BIN" -f -p "$DHCP6C_DIR/dhcp6c.pid" -c "$c" -I "$wif" -t internet "$ifn" >/dev/null 2>&1 &
    ours=$!; ours_start="$(lock_start "$ours")"
    tries=$((D6_TRIES + 1)); [ "$tries" -le 6 ] || tries=6
    echo "$tries $(( $(now_s) + 60 * (1 << tries) ))" > "$RUN/dhcp6c.tries"
    sleep "${DHCP6C_SETTLE:-2}"
    if [ "$($PIDOF dhcp6c 2>/dev/null | wc -w)" -gt 1 ]; then
        # only if that pid is still the process we started
        [ "$(lock_start "$ours")" = "$ours_start" ] && kill "$ours" 2>/dev/null
        log "the router started its own IPv6 client while ours was starting; left it to that one"
    else
        log "the router's IPv6 client (dhcp6c) was not running; restarted it (try $tries)"
    fi
}
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
    apply|start|stop|guest|shape|sync|usage|home|ui|ui-remove|boot)
        lock || { log "$1: another iot.sh run still holds the lock; gave up after ${LOCK_WAIT}s"
                  echo "iot.sh: another run is in progress; try again" >&2; exit 1; }
        trap unlock EXIT ;;
    # Settings edits: only the settings lock, and they only save. Follow with
    # `iot.sh sync` to apply at once; the watcher applies within its next run anyway.
    forget|forget-device|entry|home-allow|home-set)
        cfg_lock || { echo "iot.sh: the settings are busy; try again" >&2; exit 1; }
        trap unlock EXIT ;;
esac

case "$1" in
    apply) mkdir -p "$RUN"; rm -f "$RUN/iot.stopped"; apply ;;   # asked for by hand: a manual stop no longer holds
    watch)
        while :; do
            if lock 5; then
                rm -f "$RUN/sync.want"          # this pass applies whatever was asked for up to now
                run_all >/dev/null 2>&1
                unlock
            fi
            lifeline_guard
            ipv6_guard
            trim_log
            sleep "${INTERVAL:-15}"
        done ;;
    start)
        [ "$0" = "$SELF" ] || cp "$0" "$SELF" 2>/dev/null
        rm -f "$RUN/iot.stopped"
        run_all; inittab_add; watcher_restart; log "watcher registered" ;;
    stop)
        # Taken down by hand while the setting still says "on": stay down (see iot_on).
        mkdir -p "$RUN"; [ "$(cfg enabled 0)" = 1 ] && : > "$RUN/iot.stopped"
        stop
        shape_sync          # speed limits stay; this clears them only if none are set
        # The home allow list is not part of the IoT network: keep it (and a watcher) running.
        if [ "$(cfg home_lock 0)" = 1 ]; then home_sync
        else home_load; home_unlock; portal_clear; rm -f "$RUN/portal_macs"; fi
        # Local names and DNS over HTTPS are not part of the IoT network either.
        if [ "$(cfg dns_on 0)" = 1 ]; then names_sync; else doh_stop; fi
        watcher_sync ;;
    open|close)
        load; mkdir -p "$RUN"
        if [ "$1" = open ]; then
            s="${2:-600}"; case "$s" in ''|*[!0-9]*) s=600 ;; esac
            echo $(( $(now_s) + s )) > "$RUN/open_until"
            log "new IoT devices allowed for ${s}s"
        else rm -f "$RUN/open_until"; fi
        # "later": the caller asks for the sync itself (the dashboard: it records the
        # window before it answers, so two clicks can't end up in the wrong order).
        case " $2 $3 " in *" later "*) ;; *) kick_run ;; esac ;;
    home-open|home-close)
        mkdir -p "$RUN"
        if [ "$1" = home-open ]; then
            s="${2:-600}"; case "$s" in ''|*[!0-9]*) s=600 ;; esac
            echo $(( $(now_s) + s )) > "$RUN/home_open_until"; log "new home devices allowed for ${s}s"
        else rm -f "$RUN/home_open_until"; fi
        case " $2 $3 " in *" later "*) ;; *) kick_run ;; esac ;;
    home-allow) home_edit "$2" "$3" || exit 1 ;;
    forget-device) forget_devices "$2" || exit 1 ;;
    entry) entry_set "$2" "$3" "$4" || exit 1 ;;
    sync) run_all; watcher_sync ;;
    kick)   # kick [up]: apply what is saved, soon (see kick_run). "up": the IoT network was switched on in the settings.
        mkdir -p "$RUN"; [ "$2" = up ] && rm -f "$RUN/iot.stopped"
        kick_run ;;
    forget)   # forget <mac>: drop an IoT device's fixed address; autopin won't re-pin it
        load; mac="$(echo "$2" | tr A-F- a-f:)"
        echo "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || { echo "iot.sh: bad MAC '$2'" >&2; exit 1; }
        st=""; for e in $STATIC; do [ "$(echo "${e%%,*}" | tr A-F a-f)" = "$mac" ] || st="$st $e"; done
        fg="$(cfg forget '' | tr A-F a-f)"; case " $fg " in *" $mac "*) ;; *) fg="$fg $mac" ;; esac
        $UCI set "$SEC.iot_static=$(echo $st)"; $UCI set "$SEC.iot_forget=$(echo $fg)"
        commit_cfg >/dev/null; log "forgot IoT device $mac" ;;
    home-set) home_set "$2" "$3" || exit 1 ;;   # `sync` (run lock) registers or drops the watcher
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
        shape_sync; watcher_sync; shape_load
        echo "whole connection: $([ "$WS_ON" = 1 ] && echo "${WS_DOWN}/${WS_UP} Mbps$([ "$WS_AUTO" = 1 ] && echo ", automatic: $(cat "$RUN/autorate.stat" 2>/dev/null)")" || echo off)"
        echo "priority lane: $([ "$PRIO" = 1 ] && { [ "$WS_ON" = 1 ] && echo on || echo "on, but needs the whole-connection cap"; } || echo off)"
        echo "guests last: $([ "$GLOW" = 1 ] && { [ "$WS_ON" = 1 ] && echo on || echo "on, but needs the whole-connection cap"; } || echo off)"
        echo "guest limit: $GL_ON  ${GL_DOWN}/${GL_UP} Mbps  full-speed: ${GL_FAST:-none}"
        echo "capped (mac down up):"; shape_list | sort -u ;;
    ui) [ "$0" = "$SELF" ] || cp "$0" "$SELF" 2>/dev/null; ui_install; watcher_sync; watcher_restart ;;
    ui-remove) ui_remove ;;
    boot)
        [ "$0" = "$SELF" ] || cp "$0" "$SELF" 2>/dev/null
        ui_install
        # In-process, not "$0 start": the fetched file is not executable.
        run_all; watcher_sync
        lifeline_guard ;;
    status) status ;;
    guard) mkdir -p "$RUN"; lifeline_guard; ipv6_guard ;;   # what the watcher checks besides the rules
    usage)   # count up to now, then show the log: days, months, devices this month
        usage_sync
        awk '{ printf "%-34s %9.2f GB down %9.2f GB up\n", $1, $2 / 1073741824, $3 / 1073741824 }' "$RUN/usage" ;;
    set)
        [ -n "$2" ] || { echo "usage: iot.sh set <key> <value>" >&2; exit 1; }
        k="${2#iot_}"
        # /etc is ramfs: plain `uci commit` is lost on reboot. TP-Link's uci_commit_flash
        # goes through its patched luci.model.uci, which also writes the config to flash.
        $UCI set "$SEC.iot_$k=$3" || exit 1
        commit_cfg && echo "saved iot_$k" ;;
    *) sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
