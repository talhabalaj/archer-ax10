#!/bin/sh
# src/00-core.sh: settings, paths, log. Joined into ax10.sh by scripts/build.sh.
# ============================================================
# ax10.sh — our add-ons for the stock Archer AX10 firmware, in one file built from
# src/: an isolated IoT Wi-Fi network, our own home allow list with a join-home page,
# speed limits (fixed and automatic), local names with DNS over HTTPS, a data usage
# log, a router load watcher, the dashboard's install, and the watcher that keeps all
# of it in place. (It began as iot.sh, the IoT network alone, and still answers to
# that name: /tmp/iot.sh is a link to it, and the boot hook starts the copy saved in
# flash under that name. Its settings keep their iot_ prefix.)
#
# The IoT network: turns a spare 2.4GHz virtual AP (wl1.4 by default) into its own SSID, puts it in
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
#   IoT       -> home LAN   blocked   (except replies, iot_allow_lan exceptions, and
#                                      IoT MACs in iot_lan_open: any port)
#   IoT       -> router     DHCP, DNS and ping only (no web GUI / SSH)
#   IoT       -> internet   allowed, except MACs listed in iot_noinet
#
# Settings are UCI options on openvpn.archer_boot (next to the SSH host key), the one
# place this router persists. They are edited on the dashboard (https://192.168.0.1/)
# or with `ax10.sh set`.
#
#   ax10.sh boot       what boot.sh runs: install the dashboard; start if enabled
#   ax10.sh ui         install the dashboard (at /) and its backend
#   ax10.sh ui-remove  remove the page again
#   ax10.sh start      apply now and register the watcher with busybox-init (respawn)
#   ax10.sh stop       unregister, tear down br-iot, hand the Wi-Fi slot back to TP-Link
#   ax10.sh apply      (re)apply everything once
#   ax10.sh watch      foreground loop: re-apply whenever TP-Link undoes our state
#   ax10.sh status     show what is in place
#   ax10.sh shape      apply + show the speed limits (per device, guests, whole connection)
#   ax10.sh open [s]   with the lock on, let new devices join for s seconds (default 600)
#   ax10.sh close      end that window now
#   ax10.sh home       apply + show the home allow list (iot_home_lock, iot_home_allow)
#   ax10.sh home-open [s]  let new home devices in for s seconds; they are added
#   ax10.sh home-close     end that window now
#   ax10.sh home-allow add|remove|keep|unkeep <mac>   edit the list (under the lock)
#   ax10.sh home-set lock 0|1 / home-set expire <days>
#   ax10.sh forget-device <mac>[,<mac>...]  forget devices: all their settings, hidden while offline
#   ax10.sh usage        data used: per day, per month, per device this month
#   ax10.sh alerts       one alerts pass now; ax10.sh alert-test   send a test alert (MQTT, see 65-alerts)
#   ax10.sh reboot       save the usage log, then reboot
#   ax10.sh sync         apply everything now (after forget-device / entry, which only save)
#   ax10.sh entry caps|noinet|guest_fast|lan_allow|lan_open <mac> <value|on|off>   one device's setting
#   ax10.sh forget <mac>   drop an IoT device's fixed address (not re-pinned from its lease)
#   ax10.sh set caps "aa:bb:cc:dd:ee:03=5/2"   cap a device at 5 Mbps down, 2 up
#   ax10.sh set <key> <value>   save a setting (iot_ prefix optional), e.g.
#                     ax10.sh set ssid "wifi iot"      ax10.sh set key "<password>"
#                     ax10.sh set static "aa:bb:cc:dd:ee:01,192.168.50.10"
#                     ax10.sh set noinet "aa:bb:cc:dd:ee:02"
#                     ax10.sh set allow_lan "tcp:8899@192.168.50.10"
#                     ax10.sh set mqtt_host 192.168.0.5   (alerts to that MQTT broker; mqtt_port, mqtt_user, mqtt_pass)
#                     ax10.sh set mdns all   (IoT speakers' AirPlay/Spotify seen from home; or IoT addresses)
#                     ax10.sh set lan_mode selected; ax10.sh set lan_allow "<phone-mac>"
#                     ax10.sh set enabled 1
# ============================================================
# (AX10_TEST_PATH: the offline tests put stand-ins with the router's limits first.)
export PATH="${AX10_TEST_PATH:+$AX10_TEST_PATH:}/usr/sbin:/usr/bin:/sbin:/bin"

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
SELF="${SELF:-/tmp/ax10.sh}"
LEGACY_SELF="${LEGACY_SELF:-/tmp/iot.sh}"      # the old name, a link to $SELF (see the top)
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
    MDNS="$(cfg mdns '')"               # IoT addresses whose AirPlay/Spotify home devices see (24-iot-mdns.sh)
    LAN_MODE="$(cfg lan_mode all)"      # all | selected
    LAN_ALLOW="$(cfg lan_allow '')"     # home MACs allowed to reach IoT (mode selected)
    LAN_OPEN="$(cfg lan_open '')"       # IoT MACs allowed to reach home devices, any port
}
# has_line <file> <text>: does the file have a line that is exactly <text>? (BusyBox
# 1.19's grep has no -x, and a pattern would treat the dots in wl0.1 as wildcards.)
# The text goes in through the environment: awk -v would turn a "\n" in it into a newline.
has_line() { [ -f "$1" ] && HL_T="$2" awk '$0 == ENVIRON["HL_T"] { f = 1; exit } END { exit !f }' "$1"; }
log() { mkdir -p "$RUN"; echo "$(cut -d. -f1 /proc/uptime 2>/dev/null)s $*" >> "$LOG"; }
trim_log() { if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ]; then tail -n 200 "$LOG" > "$LOG.1" && mv "$LOG.1" "$LOG"; fi; }
