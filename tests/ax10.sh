#!/bin/sh
# Offline test for ax10.sh: stubs wl/brctl/ip/iptables/uci and a fake /sys/class/net.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/net/wl1.1/brport" "$T/net/wl1.4/brport" "$T/net/br-lan" "$T/run"
mkdir -p "$T/sys6/br-iot"; echo 0 > "$T/sys6/br-iot/disable_ipv6"
ln -s ../../br-lan "$T/net/wl1.4/brport/bridge"
ln -s ../../br-lan "$T/net/wl1.1/brport/bridge"
: > "$T/inittab"; : > "$T/calls"
: > "$T/arp"; : > "$T/leases"

cat > "$T/bin/uci" <<EOF
#!/bin/sh
case "\$*" in
  *iot_ssid*) echo "wifi iot" ;;
  *iot_key*) echo "password123" ;;
  *iot_enabled*) echo "1" ;;
  *network.lan.ipaddr*) echo "192.168.0.1" ;;
  *iot_noinet*) echo "aa:bb:cc:dd:ee:02" ;;
  *iot_static*) echo "aa:bb:cc:dd:ee:01,192.168.50.10" ;;
  *iot_allow_lan*) echo "tcp:8899@192.168.50.10 udp:5353" ;;
  *) exit 1 ;;
esac
EOF
# wl: remembers ssid/bss per interface in files.
cat > "$T/bin/wl" <<EOF
#!/bin/sh
echo "wl \$*" >> "$T/calls"
i=\$2; shift 2
case "\$1" in
  ssid) if [ -n "\$2" ]; then echo "\$2" > "$T/run/ssid.\$i"; else echo "Current SSID: \"\$(cat "$T/run/ssid.\$i" 2>/dev/null)\""; fi ;;
  bss) if [ -n "\$2" ]; then echo "\$2" > "$T/run/bss.\$i"; else cat "$T/run/bss.\$i" 2>/dev/null || echo down; fi ;;
  dwds) if [ -n "\$2" ]; then echo "\$2" > "$T/dwds"; else cat "$T/dwds" 2>/dev/null || echo 0; fi ;;
  assoclist) if [ "\$i" = wl1.3 ]; then echo "assoclist AA:BB:CC:00:00:08"; echo "assoclist AA:BB:CC:00:00:09"; fi
             if [ "\$i" = wl1.1 ]; then echo "assoclist AA:BB:CC:00:00:20"; echo "assoclist AA:BB:CC:00:00:21"; fi ;;
  macmode) if [ -n "\$2" ]; then echo "\$2" > "$T/run/macmode.\$i"; else cat "$T/run/macmode.\$i" 2>/dev/null; fi ;;
  wsec) cat "$T/run/wsec.\$i" 2>/dev/null || echo 4 ;;
  sta_info) cat "$T/sta.\$2" 2>/dev/null ;;
  map) if [ -n "\$2" ]; then [ "\$2" = 0 ] && echo "0x0:" > "$T/map" || echo "0x\$2:" > "$T/map"; else cat "$T/map" 2>/dev/null || echo "0x0:"; fi ;;
esac
EOF
cat > "$T/bin/hostapd_cli" <<EOF
#!/bin/sh
echo "hostapd_cli \$*" >> "$T/calls"
# not running (yet) while \$T/hapd_down exists
case "\$*" in *ping*) [ -e "$T/hapd_down" ] && exit 1; echo PONG; exit 0 ;; esac
echo OK
EOF
cat > "$T/bin/brctl" <<EOF
#!/bin/sh
echo "brctl \$*" >> "$T/calls"
case "\$1" in
  addbr) mkdir -p "$T/net/\$2" ;;
  delif) rm -f "$T/net/\$3/brport/bridge" ;;
  addif) ln -sf "../../\$2" "$T/net/\$3/brport/bridge" ;;
esac
EOF
cat > "$T/bin/ip" <<EOF
#!/bin/sh
echo "ip \$*" >> "$T/calls"
EOF
# iptables: remembers appended/inserted rules so -C works after the first apply.
cat > "$T/bin/iptables" <<EOF
#!/bin/sh
echo "iptables \$*" >> "$T/calls"
args="\$*"; tbl=filter
case "\$1" in -t) tbl=\$2; shift 2; args="\$*";; esac
op=\$1; shift
case "\$op" in
  -C) grep -qxF "\$tbl \$*" "$T/rules" 2>/dev/null ;;
  -A) echo "\$tbl \$*" >> "$T/rules" ;;
  -I) ch=\$1; shift; [ "\$1" -eq "\$1" ] 2>/dev/null && shift; echo "\$tbl \$ch \$*" >> "$T/rules" ;;
  -D) grep -qxF "\$tbl \$*" "$T/rules" 2>/dev/null || exit 1
      grep -vxF "\$tbl \$*" "$T/rules" > "$T/r2"; mv "$T/r2" "$T/rules" ;;
  -F) [ -f "$T/rules" ] && grep -v "^\$tbl \$1 " "$T/rules" > "$T/r2"; mv "$T/r2" "$T/rules" 2>/dev/null || true ;;
  -S) grep "^\$tbl \$1 " "$T/rules" 2>/dev/null || true ;;
esac
EOF
# dnsmasq init stub + a copy of the stock include file.
cat > "$T/bin/dnsmasq-init" <<EOF
#!/bin/sh
echo "dnsmasq \$*" >> "$T/calls"
EOF
printf 'cache-size=0\n' > "$T/dnsmasq.conf"
cat > "$T/bin/nvram" <<EOF
#!/bin/sh
echo "nvram \$*" >> "$T/calls"
EOF
mkdir -p "$T/brf"; echo " wl1.4 wl0.4 wds1.4 wds0.4" > "$T/brf/deny_all"
cat > "$T/bin/mount" <<EOF
#!/bin/sh
echo "mount \$*" >> "$T/calls"
EOF
printf '%s\n' 'nvram set ${CONFIG_WIFI}_map="3" # BH BSS + FH BSS' 'nvram set ${RTORCFG_WIFI}_dwds="1"' > "$T/tplink_brcm.sh"
# tc: remembers root htb and ingress qdiscs per device so "qdisc show" works.
cat > "$T/bin/tc" <<'EOF'
#!/bin/sh
echo "tc $*" >> "@T@/calls"
case "$1 $2" in
  "qdisc add") case "$*" in *" root handle 1: htb"*) echo "$4 htb" >> "@T@/qdiscs" ;; *" ingress") echo "$4 ingress" >> "@T@/qdiscs" ;; esac ;;
  "qdisc del") k=htb; [ "$5" = ingress ] && k=ingress
               grep -vx "$4 $k" "@T@/qdiscs" > "@T@/q2" 2>/dev/null; mv "@T@/q2" "@T@/qdiscs" 2>/dev/null ;;
  "qdisc show") grep "^$4 " "@T@/qdiscs" 2>/dev/null | sed "s/^$4 htb/qdisc htb 1: root/; s/^$4 ingress/qdisc ingress ffff:/" ;;
esac
exit 0
EOF
sed "s#@T@#$T#g" "$T/bin/tc" > "$T/tc.new" && mv "$T/tc.new" "$T/bin/tc"
# ip6tables: same rule memory as iptables, in its own files.
cat > "$T/bin/ip6tables" <<EOF
#!/bin/sh
echo "ip6tables \$*" >> "$T/calls"
args="\$*"; tbl=filter
case "\$1" in -t) tbl=\$2; shift 2; args="\$*";; esac
op=\$1; shift
case "\$op" in
  -C) grep -qxF "\$tbl \$*" "$T/rules6" 2>/dev/null ;;
  -A) echo "\$tbl \$*" >> "$T/rules6" ;;
  -I) ch=\$1; shift; [ "\$1" -eq "\$1" ] 2>/dev/null && shift; echo "\$tbl \$ch \$*" >> "$T/rules6" ;;
  -D) grep -qxF "\$tbl \$*" "$T/rules6" 2>/dev/null || exit 1
      grep -vxF "\$tbl \$*" "$T/rules6" > "$T/r6"; mv "$T/r6" "$T/rules6" ;;
  -F) [ -f "$T/rules6" ] && grep -v "^\$tbl \$1 " "$T/rules6" > "$T/r6"; mv "$T/r6" "$T/rules6" 2>/dev/null || true ;;
  -S) grep "^\$tbl \$1 " "$T/rules6" 2>/dev/null || true ;;
esac
EOF
# dnsmasq --test: refuses the config while $T/dnsmasq_reject exists.
cat > "$T/bin/dnsmasq-test" <<EOF
#!/bin/sh
[ ! -f "$T/dnsmasq_reject" ]
EOF
chmod +x "$T/bin/"*

# lockrun.py: what lockrun.lua does on the router (lockf, then exec in the same
# process, so the program holds the lock), for machines without nixio. Python opens
# files close-on-exec, which would let the lock go at exec: set_inheritable keeps it.
cat > "$T/lockrun.py" <<'EOF'
import fcntl, os, sys, time
f = open(sys.argv[1], "a")
deadline = time.time() + float(sys.argv[2])
while True:
    try:
        fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB); break
    except OSError:
        if time.time() >= deadline:
            s = os.environ.get("AX10_BUSY_SLEEP")
            if s: time.sleep(float(s))
            sys.exit(75)
        time.sleep(0.1)
os.set_inheritable(f.fileno(), True)
os.execv(sys.argv[3], sys.argv[3:])
EOF
PY="$(command -v python3)"
# hold_lock: something else holds the run lock (a sleeper under lockrun.py); free_lock lets it go.
hold_lock() { mkdir -p "$T/run"; "$PY" "$T/lockrun.py" "$T/run/run.lock" 5 /bin/sleep 300 & HOLDER=$!; sleep 1; }
free_lock() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true; }
lock_free() { "$PY" "$T/lockrun.py" "$T/run/run.lock" 0 /bin/sh -c : 2>/dev/null; }

# iot <uci stub> <script> <args...>: run ax10.sh with every host touch-point stubbed.
iot() {
  u="$1"; s="$2"; shift 2
  env WAN_DEV="${WAN_DEV:-none}" UCI="$u" WL="$T/bin/wl" LUA="$T/bin/lua" DHCP6S_CONF="$T/dhcp6s.conf" DHCP6S_INIT="$T/bin/none" DNSMASQ_HUP=true COMMIT_FLASH="$T/bin/none" DOH_WARMUP=0 DNSMASQ_BIN="$T/bin/dnsmasq-test" DNSMASQ_MAIN="$T/dnsmasq.conf" HAPD_CLI="$T/bin/hostapd_cli" BRCTL="$T/bin/brctl" IP="$T/bin/ip" \
      IPT="$T/bin/iptables" IPT6="$T/bin/ip6tables" TC="$T/bin/tc" \
      MOUNT="$T/bin/mount" UMOUNT="$T/bin/mount" NVRAM="$T/bin/nvram" BRF="$T/brf" \
      WIFI_SH="$T/tplink_brcm.sh" DNSMASQ_CONF="$T/dnsmasq.conf" DNSMASQ_INIT="$T/bin/dnsmasq-init" \
      NET="$T/net" RUN="$T/run" INITTAB="$T/inittab" SELF="$T/ax10.sh" LEGACY_SELF="$T/iot.sh" WWW="$T/www" LUCI_CTL="$T/ctl" \
      ARP="$T/arp" SYS6="$T/sys6" LEASES="$T/leases" INIT_HUP=true CLIENTS="$T/clients.json" \
      LIFELINE_BIN="$T/bin/dropbear" LIFELINE_PID="$T/run/ssh.pid" UBUS="$T/bin/ubus" PATH="$T/bin:$PATH" \
      LOCKRUN="$PY $T/lockrun.py" WATCH_BUSY_SLEEP=0 \
      sh "$s" "$@"
}
run() { iot "$T/bin/uci" "$ROOT/ax10.sh" "$@"; }

fail() { echo "FAIL: $1"; echo "--- calls"; cat "$T/calls"; exit 1; }
has() { grep -qF -- "$1" "$T/calls" || fail "expected call: $1"; }

run apply || true
has "brctl addbr br-iot"
# IPv6 is switched off on the IoT bridge and dropped as a second layer.
[ "$(cat "$T/sys6/br-iot/disable_ipv6")" = 1 ] || fail "IPv6 not disabled on br-iot"
has "ip6tables -A AX10_IOT6 -j DROP"
has "ip6tables -I INPUT 1 -i br-iot -j AX10_IOT6"
has "ip6tables -I FORWARD 1 -i br-iot -j AX10_IOT6"
has "ip6tables -I FORWARD 1 -o br-iot -j AX10_IOT6"
has "brctl delif br-lan wl1.4"
has "brctl addif br-iot wl1.4"
has "hostapd_cli -i wl1.4 set ssid wifi iot"
has "hostapd_cli -i wl1.4 set wpa_passphrase password123"
has "hostapd_cli -i wl1.4 set ignore_broadcast_ssid 0"
has "hostapd_cli -i wl1.4 reload_wpa_psk"
has "wl -i wl1.4 closed 0"
has "wl -i wl1.4 bss up"
has "ip addr add 192.168.50.1/24 dev br-iot"
has "iptables -A AX10_IOT_FWD -i br-lan -o br-iot -j ACCEPT"
has "iptables -A AX10_IOT_FWD -i br-iot -o br+ -m state --state ESTABLISHED,RELATED -j ACCEPT"
has "iptables -A AX10_IOT_FWD -i br-iot -o br+ -j DROP"
has "iptables -A AX10_IOT_FWD -i br-iot -m mac --mac-source aa:bb:cc:dd:ee:02 -j DROP"
has "iptables -A AX10_IOT_FWD -i br-iot -o br-lan -s 192.168.50.10 -p tcp --dport 8899 -j ACCEPT"
has "iptables -A AX10_IOT_FWD -i br-iot -o br-lan -p udp --dport 5353 -j ACCEPT"
has "iptables -A AX10_IOT_IN -j DROP"
has "dnsmasq restart"
has "iptables -t nat -A AX10_IOT_NAT -s 192.168.50.0/24 ! -o br+ -j MASQUERADE"
grep -qx "cache-size=0" "$T/dnsmasq.conf" || fail "stock dnsmasq lines kept"
[ "$(echo $(cat "$T/brf/deny_all"))" = "wl0.4 wds0.4" ] || fail "br-filter deny_all still lists wl1.4: $(cat "$T/brf/deny_all")"
grep -qx "dhcp-range=set:iot,192.168.50.100,192.168.50.200,255.255.255.0,12h" "$T/dnsmasq.conf" || fail "dhcp range"
grep -qx "dhcp-option=tag:iot,6,1.1.1.1,8.8.8.8" "$T/dnsmasq.conf" || fail "dns option"
grep -qx "dhcp-host=aa:bb:cc:dd:ee:01,192.168.50.10" "$T/dnsmasq.conf" || fail "static lease"
[ "$(cat "$T/run/orig_bridge")" = br-lan ] || fail "orig bridge recorded"

# Order inside the FORWARD chain: block-to-LAN and no-inet drops come before the final accept.
order="$(grep -n 'AX10_IOT_FWD -i br-iot' "$T/rules" | cut -d: -f1 | tr '\n' ' ')"
last="$(grep -n 'AX10_IOT_FWD -i br-iot -j ACCEPT' "$T/rules" | cut -d: -f1)"
for n in $order; do [ "$n" -le "$last" ] || fail "rule after final accept"; done
# "Internet off" must also cut connections that are already open: no rule may
# accept established traffic from IoT without limiting it to the home side, and
# the no-inet drop must come before anything that could accept Internet traffic.
grep -q 'AX10_IOT_FWD -i br-iot -m state' "$T/rules" && fail "established IoT traffic is accepted before the no-inet drop"
noinet_ln="$(grep -n 'AX10_IOT_FWD -i br-iot -m mac --mac-source aa:bb:cc:dd:ee:02 -j DROP' "$T/rules" | cut -d: -f1)"
[ -n "$noinet_ln" ] || fail "no-inet drop missing"
grep -n 'AX10_IOT_FWD -i br-iot' "$T/rules" | grep -v -- '-o br' | while IFS=: read n rule; do
  case "$rule" in *"-j ACCEPT"*) [ "$n" -gt "$noinet_ln" ] || { echo "FAIL: accept without -o before the no-inet drop: $rule"; exit 1; } ;; esac
done || exit 1

# Second pass is a no-op: nothing moved, firewall not rebuilt.
: > "$T/calls"
run apply || true
grep -v "hostapd_cli .* ping" "$T/calls" | grep -q "brctl\|-F AX10\|dnsmasq\|hostapd_cli" && fail "second apply was not idempotent"   # (the ping that asks whether hostapd runs the slot is only a question)

# Something re-enables IPv6 on the bridge: the next pass turns it off again.
echo 0 > "$T/sys6/br-iot/disable_ipv6"
run apply || true
[ "$(cat "$T/sys6/br-iot/disable_ipv6")" = 1 ] || fail "IPv6 on br-iot not switched off again"

# Same rules in the wrong order (final accept first) must be noticed and rebuilt.
{ echo "filter AX10_IOT_FWD -i br-iot -j ACCEPT"
  grep -vxF "filter AX10_IOT_FWD -i br-iot -j ACCEPT" "$T/rules"; } > "$T/r3"
mv "$T/r3" "$T/rules"
: > "$T/calls"; run apply || true
has "iptables -F AX10_IOT_FWD"
drop_ln="$(grep -nxF 'filter AX10_IOT_FWD -i br-iot -o br+ -j DROP' "$T/rules" | head -n1 | cut -d: -f1)"
acc_ln="$(grep -nxF 'filter AX10_IOT_FWD -i br-iot -j ACCEPT' "$T/rules" | head -n1 | cut -d: -f1)"
[ -n "$drop_ln" ] && [ -n "$acc_ln" ] && [ "$drop_ln" -lt "$acc_ln" ] || fail "rule order not repaired"
[ "$(grep -cxF 'filter AX10_IOT_FWD -i br-iot -j ACCEPT' "$T/rules")" -eq 1 ] || fail "final accept not exactly once"
: > "$T/calls"; run apply || true
grep -q -- "-F AX10" "$T/calls" && fail "apply not stable after order repair"

# TP-Link Wi-Fi restart puts its own SSID back: the next pass re-applies ours.
echo "e2b6520c958f5e14820332d7ee1a39" > "$T/run/ssid.wl1.4"; : > "$T/calls"
run apply || true
has "hostapd_cli -i wl1.4 set ssid wifi iot"

# Mesh flags back on the slot: patch the TP-Link script and rebuild the radio once.
echo 1 > "$T/dwds"; echo "0x3:  Fronthaul-BSS  Backhaul-BSS" > "$T/map"; : > "$T/calls"
run apply || true
has "mount --bind $T/run/overlay/tplink_brcm.sh $T/tplink_brcm.sh"
grep -q 'CONFIG_WIFI}_map="0"' "$T/run/overlay/tplink_brcm.sh" || fail "map not patched"
grep -q 'RTORCFG_WIFI}_dwds="0"' "$T/run/overlay/tplink_brcm.sh" || fail "dwds not patched"
has "nvram set wl1.4_dwds=0"
has "wl -i wl1 down"
has "wl -i wl1.4 dwds 0"
has "wl -i wl1.4 map 0"
has "wl -i wl1 up"
# ...and not again within 10 minutes, even if the flags come back.
echo 1 > "$T/dwds"; : > "$T/calls"
run apply || true
grep -q "wl -i wl1 down" "$T/calls" && fail "radio bounced twice within 10 minutes"
rm -f "$T/dwds"

# A per-client wds interface in br-lan is moved into br-iot.
mkdir -p "$T/net/wds1.4.1/brport"; ln -s ../../br-lan "$T/net/wds1.4.1/brport/bridge"; : > "$T/calls"
run apply || true
has "brctl addif br-iot wds1.4.1"

# stop removes the block and restores the original bridge.
: > "$T/calls"
run stop
grep -q "ax10-iot" "$T/dnsmasq.conf" && fail "dnsmasq block not removed"
has "brctl addif br-lan wl1.4"
has "wl -i wl1.4 bss down"
has "wl -i wl1.4 dwds 1"
has "wl -i wl1.4 map 3"
grep -qE "wl1\.1 (ssid|closed|dwds|map|bss down)|-i wl1\.1 set" "$T/calls" && fail "changed the main Wi-Fi"
has "brctl delbr br-iot"
has "ip6tables -X AX10_IOT6"
grep -q "AX10_IOT6" "$T/rules6" && fail "IPv6 drop rules left behind after stop"

# lan_mode=selected: only allowlisted home MACs may reach IoT; no blanket accept.
cat > "$T/bin/uci2" <<EOF
#!/bin/sh
case "\$*" in
  *iot_lan_mode*) echo "selected" ;;
  *iot_lan_allow*) echo "aa:bb:cc:00:00:01" ;;
  *) exec "$T/bin/uci" "\$@" ;;
esac
EOF
chmod +x "$T/bin/uci2"; : > "$T/calls"
iot "$T/bin/uci2" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
has "iptables -A AX10_IOT_FWD -i br-lan -o br-iot -m mac --mac-source aa:bb:cc:00:00:01 -j ACCEPT"
grep -q "AX10_IOT_FWD -i br-lan -o br-iot -j ACCEPT" "$T/calls" && fail "selected mode still has the blanket home->IoT accept"

# A dead SSH lifeline is restarted by the boot/watch path.
cat > "$T/bin/dropbear" <<EOF
#!/bin/sh
echo "dropbear \$*" >> "$T/calls"
EOF
chmod +x "$T/bin/dropbear"
# boot (as boot.sh runs it: a non-executable copy via sh) starts the network.
mkdir -p "$T/run/ui/iotNetwork"; : > "$T/run/ui/iot_net.lua"; : > "$T/inittab"; : > "$T/calls"
cp "$ROOT/ax10.sh" "$T/ax10.sh"; chmod 600 "$T/ax10.sh"
iot "$T/bin/uci" "$T/ax10.sh" boot >/dev/null 2>&1 || true
[ "$(readlink "$T/net/wl1.4/brport/bridge")" = "../../br-iot" ] || fail "boot did not put wl1.4 in br-iot"
grep -q "ax10-iot-watch" "$T/inittab" || fail "boot did not register the watcher"
# The lifeline starts in the background; give it up to 5 s.
i=0; while [ $i -lt 50 ] && ! grep -qF "dropbear -p" "$T/calls"; do sleep 0.1; i=$((i + 1)); done
has "dropbear -p"

# --- known devices: new IoT leases are pinned; the lock lets only pinned devices join.
cat > "$T/bin/uci4" <<EOF
#!/bin/sh
echo "uci \$*" >> "$T/calls"
case "\$*" in
  "set "*) exit 0 ;;
  *iot_lock*) cat "$T/lock_on" 2>/dev/null || echo 0 ;;
  *) exec "$T/bin/uci" "\$@" ;;
esac
EOF
chmod +x "$T/bin/uci4"
printf '%s\n' "1000 AA:BB:CC:DD:EE:05 192.168.50.150 cam *" "1000 aa:bb:cc:dd:ee:01 192.168.50.10 logger *" \
  "1000 aa:bb:cc:dd:ee:07 192.168.0.50 laptop *" > "$T/leases"
: > "$T/calls"
iot "$T/bin/uci4" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
has "uci set openvpn.archer_boot.iot_static=aa:bb:cc:dd:ee:01,192.168.50.10 aa:bb:cc:dd:ee:05,192.168.50.150"
grep -q "dhcp-host=aa:bb:cc:dd:ee:05,192.168.50.150" "$T/dnsmasq.conf" || fail "new fixed address not in dnsmasq.conf"
grep -q "aa:bb:cc:dd:ee:07" "$T/calls" && fail "home device pinned on the IoT network"
grep -q "macmode 2" "$T/calls" && fail "locked although the lock is off"
# Lock on: allow list of the known devices, allow-only mode.
echo 1 > "$T/lock_on"; : > "$T/calls"
iot "$T/bin/uci4" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
has "wl -i wl1.4 mac AA:BB:CC:DD:EE:01 AA:BB:CC:DD:EE:05"
has "wl -i wl1.4 macmode 2"
# The "allow new devices" window lifts it.
: > "$T/calls"
iot "$T/bin/uci4" "$ROOT/ax10.sh" open 600 >/dev/null 2>&1 || true
[ -s "$T/run/open_until" ] || fail "open did not record its window"
grep -q "macmode 2" "$T/calls" && fail "locked while open to new devices"
rm -f "$T/lock_on" "$T/run/open_until"; : > "$T/leases"
# TP-Link's allow list must not close the guest Wi-Fi.
cat > "$T/bin/uci5" <<EOF
#!/bin/sh
case "\$*" in
  *access_control.settings.enable*) echo on ;;
  *access_control.settings.access_mode*) cat "$T/ac_mode" ;;
  "show wireless") echo "wireless.guest2g.guest='on'" ;;
  *wireless.guest2g.ifname*) echo "wl1.3" ;;
  *) exec "$T/bin/uci" "\$@" ;;
esac
EOF
chmod +x "$T/bin/uci5"; mkdir -p "$T/net/wl1.3"
echo white > "$T/ac_mode"; : > "$T/calls"
iot "$T/bin/uci5" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
has "wl -i wl1.3 macmode 0"
# ...nor its firewall chain: connected guests are accepted by MAC, IPv4 and IPv6.
has "iptables -t raw -I access_control 1 -j ax10_guest_ac"
has "iptables -t raw -A ax10_guest_ac -m mac --mac-source aa:bb:cc:00:00:08 -j ACCEPT"
has "ip6tables -t raw -A ax10_guest_ac -m mac --mac-source aa:bb:cc:00:00:09 -j ACCEPT"
: > "$T/calls"
iot "$T/bin/uci5" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
grep -q "raw -F ax10_guest_ac" "$T/calls" && fail "guest accept rules rebuilt with no change"
echo black > "$T/ac_mode"; : > "$T/calls"
iot "$T/bin/uci5" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
grep -q "wl -i wl1.3 macmode 0" "$T/calls" && fail "guest Wi-Fi filter removed in block-list mode"
has "iptables -t raw -D access_control -j ax10_guest_ac"

# --- speed limits: guests, a per-device cap and a mesh guest, all matched by MAC.
mkdir -p "$T/net/wl1.3"
echo 1 > "$T/guest_on"; echo 0 > "$T/wan_on"
# TP-Link's client list: 06 is a guest behind the mesh satellite (capped), 05 an
# offline guest and 04 a home device (both left alone).
printf '%s' '{"AA-BB-CC-00-00-06":{"mac":"AA-BB-CC-00-00-06","connect_status":1,"guest":"GUEST"},"AA-BB-CC-00-00-05":{"mac":"AA-BB-CC-00-00-05","connect_status":0,"guest":"GUEST"},"AA-BB-CC-00-00-04":{"mac":"AA-BB-CC-00-00-04","connect_status":1,"guest":"NON_GUEST"}}' > "$T/clients.json"
cat > "$T/bin/uci3" <<EOF
#!/bin/sh
case "\$*" in
  "show wireless") echo "wireless.guest2g.guest='on'" ;;
  *wireless.guest2g.ifname*) echo "wl1.3" ;;
  *iot_guest_limit*) cat "$T/guest_on" ;;
  *iot_guest_down*) echo "5" ;;
  *iot_guest_up*) echo "2" ;;
  *iot_guest_fast*) echo "AA:BB:CC:00:00:09" ;;
  *iot_caps*) [ -f "$T/caps" ] && cat "$T/caps" || exit 1 ;;
  *iot_wan_shape*) cat "$T/wan_on" ;;
  *iot_wan_down*) echo "90" ;;
  *iot_wan_up*) echo "40" ;;
  *iot_prio*) [ -f "$T/prio_on" ] && echo 1 || echo 0 ;;
  *iot_wan_auto*) [ -f "$T/auto_on" ] && echo 1 || echo 0 ;;
  *iot_wan_max_down*) echo 200 ;;
  *iot_guest_low*) [ -f "$T/glow_on" ] && echo 1 || echo 0 ;;
  *) exec "$T/bin/uci" "\$@" ;;
esac
EOF
chmod +x "$T/bin/uci3"
echo "aa-bb-cc-00-00-07=10/0" > "$T/caps"     # download-only cap, given with dashes
: > "$T/calls"; : > "$T/qdiscs"
iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
for c in iptables ip6tables; do
  for m in 08 06 07; do
    has "$c -t mangle -A AX10_SHAPE_IN -i br-lan -m mac --mac-source aa:bb:cc:00:00:$m -j CONNMARK --set-xmark 0x1000000/0x1000000"
  done
  has "$c -t mangle -A AX10_SHAPE -m connmark --mark 0x1000000/0x1000000 -j BLOGSKIP"
  has "$c -t mangle -I FORWARD 1 -j AX10_SHAPE"
done
grep -qi "aa:bb:cc:00:00:09" "$T/calls" && fail "full-speed guest was shaped"
grep -qi "aa:bb:cc:00:00:0[45]" "$T/calls" && fail "offline guest or home device was shaped"
has "tc filter add dev br-lan parent ffff: protocol all prio 10 u32 match u32 0 0 action mirred egress redirect dev ifb0"
for m in 06 07 08; do has "match ether dst aa:bb:cc:00:00:$m"; done
for m in 06 08; do has "match ether src aa:bb:cc:00:00:$m"; done
grep -q "match ether src aa:bb:cc:00:00:07" "$T/calls" && fail "upload capped although the cap is download-only"
has "htb rate 5mbit ceil 5mbit"
has "htb rate 2mbit ceil 2mbit"
has "htb rate 10mbit ceil 10mbit"
has "sfq perturb 10 limit 30"
[ -f "$T/run/shape.sig" ] || fail "shape.sig not written"
# Nothing changed: no rebuild.
: > "$T/calls"
iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
grep -q "tc qdisc add" "$T/calls" && fail "second sync rebuilt tc"
grep -q -- "-A AX10_SHAPE" "$T/calls" && fail "second sync re-added rules"
# Queues gone (e.g. TP-Link reset them): rebuilt.
: > "$T/qdiscs"; : > "$T/calls"
iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
has "tc qdisc add dev br-lan root handle 1: htb default 10"
# Whole connection capped: everything skips acceleration, no per-device marks.
echo 1 > "$T/wan_on"; : > "$T/calls"
iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
has "iptables -t mangle -A AX10_SHAPE -j BLOGSKIP"
has "ip6tables -t mangle -A AX10_SHAPE -j BLOGSKIP"
has "tc class add dev br-lan parent 1: classid 1:1 htb rate 90mbit ceil 90mbit"
has "tc class add dev ifb0 parent 1: classid 1:1 htb rate 40mbit ceil 40mbit"
grep -q -- "-A AX10_SHAPE_IN" "$T/calls" && fail "per-device marks added with the whole connection capped"
grep -q "classid 1:2 " "$T/calls" && fail "priority lane built while it is off"
# Priority lane: class 1:2 first in line, guaranteed 40%, with the call and game filters.
: > "$T/prio_on"; : > "$T/calls"
iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
has "tc class add dev br-lan parent 1:1 classid 1:2 htb rate 36mbit ceil 90mbit"
has "tc class add dev ifb0 parent 1:1 classid 1:2 htb rate 16mbit ceil 40mbit"
has "tc class add dev br-lan parent 1:1 classid 1:10 htb rate 54mbit ceil 90mbit"
has "tc filter add dev br-lan parent 1: protocol ip prio 2 u32 match ip protocol 17 0xff match ip sport 8800 0xfff8 flowid 1:2"
has "tc filter add dev ifb0 parent 1: protocol ip prio 2 u32 match ip protocol 17 0xff match ip dport 8800 0xfff8 flowid 1:2"
has "tc filter add dev ifb0 parent 1: protocol ipv6 prio 3 u32 match ip6 protocol 17 0xff match u16 0x0000 0xfe00 at 4 flowid 1:2"
has "tc filter add dev br-lan parent 1: protocol ip prio 2 u32 match ip tos 0xb8 0xfc flowid 1:2"
rm -f "$T/prio_on"
# Guests last: a bottom lane at 10%, guest caps nested in it, uncapped directions caught by it.
: > "$T/glow_on"; : > "$T/prio_on"; : > "$T/calls"
iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
has "tc class add dev br-lan parent 1:1 classid 1:3 htb rate 9mbit ceil 90mbit"
has "tc class add dev br-lan parent 1:1 classid 1:10 htb rate 45mbit ceil 90mbit"
has "tc class add dev br-lan parent 1:3 classid"
has "tc filter add dev br-lan parent 1: protocol all prio 1 u32 match ether dst aa:bb:cc:00:00:08 flowid 1:4"
has "tc filter add dev ifb0 parent 1: protocol all prio 1 u32 match ether src aa:bb:cc:00:00:06 flowid 1:4"
has "tc class add dev br-lan parent 1:3 classid 1:4 htb rate 9mbit ceil 90mbit"
grep -q "match ether dst aa:bb:cc:00:00:07 flowid 1:4" "$T/calls" && fail "home device put in the guest lane"
rm -f "$T/glow_on" "$T/prio_on"
# Everything off: cleared, including the old guest-only limit's leftovers.
echo 0 > "$T/wan_on"; echo 0 > "$T/guest_on"; rm -f "$T/caps"
echo "mangle PREROUTING -j AX10_GUEST" >> "$T/rules"; : > "$T/run/guest.sig"; : > "$T/calls"
iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
has "tc qdisc del dev br-lan root"
has "tc qdisc del dev br-lan ingress"
has "tc qdisc del dev wl1.3 root"
grep -q "AX10_GUEST" "$T/rules" && fail "old guest-limit rule left behind"
grep -q "AX10_SHAPE" "$T/rules" "$T/rules6" 2>/dev/null && fail "shape rules left behind"
[ ! -f "$T/run/shape.sig" ] || fail "shape.sig left behind after limits off"
[ ! -f "$T/run/guest.sig" ] || fail "guest.sig left behind"

# --- web-page installer: files copied, JSON edited once even when run twice.
rm -rf "$T/run/ui" "$T/www" "$T/ctl"
mkdir -p "$T/run/ui" "$T/www/config" "$T/www/locale/en_US" "$T/www/modules/advanced/wireless" "$T/ctl"
cp -R "$ROOT/iot-ui/." "$T/run/ui/"
printf '%s\n' '{"advanced":[{"name":"wireless","children":[{"name":"guestNetworkAdv","text":"GUEST_NETWORK"}]}]}' > "$T/www/config/navigator.json"
printf '%s\n' '{"guestNetworkAdv":{"controller":"./modules/x/script.js","view":"./modules/x/view.html"}}' > "$T/www/config/modules.json"
printf '%s\n' '$.su.CHAR.MENU_ITEMS_NAME = {};' > "$T/www/locale/en_US/lan.js"
printf '%s\n' '.stock-rule { color: red }' > "$T/www/locale/en_US/lan.css"
printf '%s\n' 'stock root redirect' > "$T/index.html"
printf '%s\n' 'stock login redirect' > "$T/www/login.html"
: > "$T/calls"
run ui >/dev/null 2>&1 || true
run ui >/dev/null 2>&1 || true
[ -f "$T/ctl/iot_net.lua" ] || fail "iot_net.lua not installed"
[ -f "$T/www/modules/advanced/wireless/iotNetwork/script.js" ] || fail "iotNetwork page not installed"
[ -f "$T/www/modules/advanced/wireless/guestSpeed/script.js" ] || fail "guestSpeed page not installed"
for f in navigator.json modules.json; do
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$T/www/config/$f" || fail "$f is not valid JSON"
done
[ "$(grep -o '"iotNetwork"' "$T/www/config/navigator.json" | wc -l)" -eq 1 ] || fail "navigator.json: iotNetwork not exactly once"
[ "$(grep -o '"guestSpeed"' "$T/www/config/navigator.json" | wc -l)" -eq 1 ] || fail "navigator.json: guestSpeed not exactly once"
[ "$(grep -o '"iotNetwork":{' "$T/www/config/modules.json" | wc -l)" -eq 1 ] || fail "modules.json: iotNetwork not exactly once"
[ "$(grep -o '"guestSpeed":{' "$T/www/config/modules.json" | wc -l)" -eq 1 ] || fail "modules.json: guestSpeed not exactly once"
loc="$(head -c 40 "$ROOT/iot-ui/locale.js")"
[ "$(grep -cF -- "$loc" "$T/www/locale/en_US/lan.js")" -eq 1 ] || fail "lan.js: locale line not exactly once"
grep -qF 'MENU_ITEMS_NAME = {};' "$T/www/locale/en_US/lan.js" || fail "lan.js lost its original line"
[ "$(grep -c 'ax10-theme-begin' "$T/www/locale/en_US/lan.css")" -eq 1 ] || fail "lan.css: theme not exactly once"
grep -qF 'stock-rule' "$T/www/locale/en_US/lan.css" || fail "lan.css lost its original rule"
[ "$(tail -n 1 "$T/www/locale/en_US/lan.css")" = "$(tail -n 1 "$ROOT/iot-ui/theme.css")" ] || fail "lan.css: theme not at the end"
has "mount --bind $T/run/ui/dash/index.html $T/index.html"
has "mount --bind $T/run/ui/dash/login.html $T/www/login.html"

# Lock 1: held by another process -> the run waits, gives up and changes nothing.
hold_lock; : > "$T/calls"
set +e; ( LOCK_WAIT=1 run apply >/dev/null 2>&1 ); st=$?; set -e
[ "$st" = 75 ] || fail "apply did not give up (exit 75) while the lock was held (exit $st)"
[ ! -s "$T/calls" ] || fail "apply touched the router while the lock was held"
kill -0 "$HOLDER" 2>/dev/null || fail "the holder was disturbed"

# Lock 2: the holder killed outright -> the lock is free at once; nothing stale is left.
kill -9 "$HOLDER"; wait "$HOLDER" 2>/dev/null || true
rm -f "$T/run/fw.sig"; : > "$T/calls"
( LOCK_WAIT=1 run apply >/dev/null 2>&1 ) || true
[ -s "$T/calls" ] || fail "the lock of a killed holder was not free"

# Lock 3: let go after a normal run; `status` doesn't take it.
run apply >/dev/null 2>&1 || true
lock_free || fail "lock still held after a normal run"
hold_lock; run status >/dev/null 2>&1 || fail "status waited for the lock"; free_lock

# Lock 4: concurrent runs take turns, so the rules end up in order.
rm -f "$T/run/fw.sig"
run apply >/dev/null 2>&1 & run apply >/dev/null 2>&1 & run apply >/dev/null 2>&1 & wait
acc='filter AX10_IOT_FWD -i br-iot -j ACCEPT'
[ "$(grep -cxF "$acc" "$T/rules")" -eq 1 ] || fail "concurrent runs: final accept not exactly once"
drop_ln="$(grep -nxF 'filter AX10_IOT_FWD -i br-iot -o br+ -j DROP' "$T/rules" | head -n1 | cut -d: -f1)"
acc_ln="$(grep -nxF "$acc" "$T/rules" | head -n1 | cut -d: -f1)"
last_ln="$(grep -n '^filter AX10_IOT_FWD ' "$T/rules" | tail -n1 | cut -d: -f1)"
[ -n "$drop_ln" ] && [ "$drop_ln" -lt "$acc_ln" ] || fail "concurrent runs: drop not before accept"
[ "$acc_ln" -eq "$last_ln" ] || fail "concurrent runs: final accept is not last"

# Lock 5: a holder killed while five runs wait for it: still one run at a time.
for round in 1 2 3; do
  hold_lock; rm -f "$T/run/fw.sig"
  run apply >/dev/null 2>&1 & run apply >/dev/null 2>&1 & run apply >/dev/null 2>&1 & run apply >/dev/null 2>&1 & run apply >/dev/null 2>&1 &
  sleep 1; kill -9 "$HOLDER"; wait
  [ "$(grep -cxF "$acc" "$T/rules")" -eq 1 ] || fail "killed holder + 5 waiters: two runs built the firewall at once (round $round)"
done
lock_free || fail "lock left held after the waiters"

# --- home allow list: radios take listed MACs only, unlisted ones are kicked, and an
# unlisted home client behind the satellite (04 in the client list) is dropped by MAC;
# guests (06 behind the satellite, 08/09 on the guest radio) are left alone.
mkdir -p "$T/net/wl1.1"; rm -f "$T/run/home_drop"
cat > "$T/bin/uci6" <<EOF
#!/bin/sh
case "\$*" in
  *iot_home_lock*) [ -f "$T/home_on" ] && echo 1 || echo 0 ;;
  *iot_home_allow*) echo "aa:bb:cc:00:00:20" ;;
  *iot_home_keep*) echo "aa:bb:cc:00:00:30" ;;
  "show wireless") echo "wireless.guest2g.guest='on'" ;;
  *wireless.guest2g.ifname*) echo "wl1.3" ;;
  *) exec "$T/bin/uci" "\$@" ;;
esac
EOF
chmod +x "$T/bin/uci6"
: > "$T/home_on"; : > "$T/calls"
iot "$T/bin/uci6" "$ROOT/ax10.sh" home >/dev/null 2>&1 || true
has "wl -i wl1.1 mac AA:BB:CC:00:00:20 AA:BB:CC:00:00:30"
has "wl -i wl1.1 macmode 2"
has "wl -i wl1.1 deauthenticate AA:BB:CC:00:00:21"
grep -q "deauthenticate AA:BB:CC:00:00:20" "$T/calls" && fail "listed device kicked off the home Wi-Fi"
has "iptables -t raw -I PREROUTING 1 -i br-lan -j AX10_HOME"
has "iptables -t raw -A AX10_HOME -m mac --mac-source aa:bb:cc:00:00:04 -j DROP"
has "ip6tables -t raw -A AX10_HOME -m mac --mac-source aa:bb:cc:00:00:04 -j DROP"
grep -q "AX10_HOME -m mac --mac-source aa:bb:cc:00:00:0[689]" "$T/calls" && fail "guest dropped by the home allow list"
grep -q "AX10_HOME -m mac --mac-source aa:bb:cc:00:00:20" "$T/calls" && fail "listed device dropped"
# A device dropped earlier that moves to the guest Wi-Fi is let go.
echo "aa:bb:cc:00:00:04 aa:bb:cc:00:00:08" > "$T/run/home_drop"; : > "$T/calls"
iot "$T/bin/uci6" "$ROOT/ax10.sh" home >/dev/null 2>&1 || true
grep -q "aa:bb:cc:00:00:08" "$T/run/home_drop" && fail "device on the guest Wi-Fi still dropped"
grep -q "aa:bb:cc:00:00:04" "$T/run/home_drop" || fail "unlisted home device no longer dropped"
# Nothing changes on a second run.
: > "$T/calls"
iot "$T/bin/uci6" "$ROOT/ax10.sh" home >/dev/null 2>&1 || true
grep -q "raw -F AX10_HOME\|macmode 2" "$T/calls" && fail "home allow list rebuilt with no change"
# Lock off: radios open, chain gone.
rm -f "$T/home_on"; : > "$T/calls"
iot "$T/bin/uci6" "$ROOT/ax10.sh" home >/dev/null 2>&1 || true
has "wl -i wl1.1 macmode 0"
has "iptables -t raw -D PREROUTING -i br-lan -j AX10_HOME"

# --- home allow list edits go through ax10.sh (stateful uci: settings are really saved).
mkdir -p "$T/u"; rm -f "$T/u/"* "$T/run/home_seen" "$T/run/home_drop"
cat > "$T/bin/uci7" <<EOF
#!/bin/sh
case "\$*" in
  "-q get openvpn.archer_boot.iot_home_"*|"-q get openvpn.archer_boot.iot_enabled") k="\${3#openvpn.archer_boot.}"; cat "$T/u/\$k" 2>/dev/null ;;
  "-q get openvpn.archer_boot.iot_usage_"*) k="\${3#openvpn.archer_boot.}"; cat "$T/u/\$k" 2>/dev/null ;;
  "-q get openvpn.archer_boot.iot_static"|"-q get openvpn.archer_boot.iot_forget"|"-q get openvpn.archer_boot.iot_caps"|"-q get openvpn.archer_boot.iot_noinet"|"-q get openvpn.archer_boot.iot_guest_fast"|"-q get openvpn.archer_boot.iot_lan_allow"|"-q get openvpn.archer_boot.iot_hidden"|"-q get openvpn.archer_boot.iot_hidden_devices") k="\${3#openvpn.archer_boot.}"; cat "$T/u/\$k" 2>/dev/null ;;
  "set openvpn.archer_boot.iot_"*) kv="\${2#openvpn.archer_boot.}"; echo "\${kv#*=}" > "$T/u/\${kv%%=*}" ;;
  "commit openvpn") ;;
  "show wireless") echo "wireless.guest2g.guest='on'" ;;
  *wireless.guest2g.ifname*) echo "wl1.3" ;;
  *wireless.wl03.ssid*) echo "home net" ;;
  *wireless.wl03.psk_key*) echo 'pa<ss&"w0rd' ;;
  *) exec "$T/bin/uci" "\$@" ;;
esac
EOF
chmod +x "$T/bin/uci7"
cat > "$T/bin/lua" <<EOF
#!/bin/sh
echo "lua \$*" >> "$T/calls"
case "\$*" in *"doh.lua check"*) [ -f "$T/doh_healthy" ]; exit ;; esac
exec sleep 30
EOF
chmod +x "$T/bin/lua"; mkdir -p "$T/www/js/libs"; : > "$T/www/js/libs/jquery.min.js"; : > "$T/www/js/libs/jquery.qrcode.min.js"
h() { iot "$T/bin/uci7" "$ROOT/ax10.sh" "$@" >/dev/null 2>&1; }
# The lock can't go on with an empty list.
h home-set lock 1 && fail "lock turned on with an empty allow list"
# An empty list with the window open enrolls the home clients on the radios (not guests).
echo 1 > "$T/u/iot_home_lock"; h home-open 600
grep -q "aa:bb:cc:00:00:20" "$T/u/iot_home_allow" || fail "open window did not enroll a home device into an empty list"
grep -q "aa:bb:cc:00:00:08" "$T/u/iot_home_allow" && fail "guest enrolled into the home allow list"
h home-close
# add / keep / unkeep / remove
h home-allow add AA-BB-CC-00-00-40 || fail "home-allow add failed"
grep -q "aa:bb:cc:00:00:40" "$T/u/iot_home_allow" || fail "add did not save"
h home-allow keep aa:bb:cc:00:00:40; grep -q "aa:bb:cc:00:00:40" "$T/u/iot_home_keep" || fail "keep did not save"
h home-allow unkeep aa:bb:cc:00:00:40
grep -q "aa:bb:cc:00:00:40" "$T/u/iot_home_keep" && fail "unkeep left it pinned"
grep -q "aa:bb:cc:00:00:40" "$T/u/iot_home_allow" || fail "unkeep took it off the list"
h home-allow remove aa:bb:cc:00:00:40; grep -q "aa:bb:cc:00:00:40" "$T/u/iot_home_allow" && fail "remove did not save"
h home-allow add "bad;rm" && fail "bad MAC accepted"
# Re-adding an expired device starts a fresh clock instead of expiring it again.
echo 1 > "$T/u/iot_home_expire"
echo "aa:bb:cc:00:00:50 1000000000" >> "$T/run/home_seen"
h home-allow add aa:bb:cc:00:00:50; h home
grep -q "aa:bb:cc:00:00:50" "$T/u/iot_home_allow" || fail "re-added device expired again at once"
# A settings edit waits for a run in progress (one lock for both), then lands.
hold_lock
iot "$T/bin/uci7" "$ROOT/ax10.sh" home-allow add aa:bb:cc:00:00:52 > "$T/ep.out" 2>&1 & ep=$!
sleep 2; grep -q "aa:bb:cc:00:00:52" "$T/u/iot_home_allow" && fail "a settings edit ran while another run held the lock"
free_lock; set +e; wait "$ep"; est=$?; set -e; [ "$est" = 0 ] || fail "the waiting settings edit failed (exit $est): $(cat "$T/ep.out")"
grep -q "aa:bb:cc:00:00:52" "$T/u/iot_home_allow" || fail "the waiting settings edit was lost"
h home-allow remove aa:bb:cc:00:00:52
# Expiry never empties the list.
echo "aa:bb:cc:00:00:60" > "$T/u/iot_home_allow"; : > "$T/u/iot_home_keep"
echo "aa:bb:cc:00:00:60 1000000000" > "$T/run/home_seen"; h home
[ -n "$(cat "$T/u/iot_home_allow")" ] || fail "expiry emptied the allow list"
# With the lock off, nothing is ever taken off the saved list.
echo 0 > "$T/u/iot_home_lock"; echo "aa:bb:cc:00:00:60 aa:bb:cc:00:00:61" > "$T/u/iot_home_allow"
printf '%s\n' "aa:bb:cc:00:00:60 1000000000" "aa:bb:cc:00:00:61 1000000000" > "$T/run/home_seen"; h home
[ "$(cat "$T/u/iot_home_allow")" = "aa:bb:cc:00:00:60 aa:bb:cc:00:00:61" ] || fail "entries expired off the allow list while the lock was off: $(cat "$T/u/iot_home_allow")"
echo 1 > "$T/u/iot_home_lock"; echo "aa:bb:cc:00:00:60" > "$T/u/iot_home_allow"
echo 0 > "$T/u/iot_home_expire"
# The last device can't be removed while the lock is on.
h home-allow remove aa:bb:cc:00:00:60 && fail "removed the last device with the lock on"
# Turning the IoT network off keeps the home lock and its watcher.
: > "$T/inittab"; : > "$T/calls"; h stop
grep -q "ax10-iot-watch" "$T/inittab" || fail "stop removed the watcher the home lock needs"
grep -q "raw -D PREROUTING -i br-lan -j AX10_HOME" "$T/calls" && fail "stop tore down the home lock"
echo 0 > "$T/u/iot_home_lock"; h home-set lock 0; h sync
grep -q "ax10-iot-watch" "$T/inittab" || fail "the watcher was dropped"
# The watcher always runs, even with every feature off: it is what applies saved
# changes if an "apply soon" request never got through.
echo 0 > "$T/u/iot_usage_on"; h sync
grep -q "ax10-iot-watch" "$T/inittab" || fail "the watcher was dropped with every feature off"
rm -f "$T/u/iot_usage_on"

# A re-added device's old last-seen time is gone from the saved copy too (reboot-safe).
echo "aa:bb:cc:00:00:70=1000000000 aa:bb:cc:00:00:20=1000000001" > "$T/u/iot_home_seen"; rm -f "$T/run/home_seen"
h home-allow add aa:bb:cc:00:00:70
grep -q "aa:bb:cc:00:00:70" "$T/u/iot_home_seen" && fail "old last-seen time kept in the saved copy"
grep -q "aa:bb:cc:00:00:20" "$T/u/iot_home_seen" || fail "other devices' last-seen times lost"
h home-allow remove aa:bb:cc:00:00:70
# A radio filter we didn't set (TP-Link deny mode 1) survives stop with both features off.
echo 0 > "$T/u/iot_home_lock"; rm -f "$T/run/home_owned"; echo 1 > "$T/run/macmode.wl1.1"; : > "$T/calls"; h stop
grep -q "wl -i wl1.1 macmode 0" "$T/calls" && fail "stop reset a radio filter it did not set"
rm -f "$T/run/macmode.wl1.1"
# forget: drops the pin and records it, under the lock.
echo "aa:bb:cc:dd:ee:01,192.168.50.10 aa:bb:cc:dd:ee:05,192.168.50.150" > "$T/u/iot_static"; : > "$T/u/iot_forget"
h forget AA:BB:CC:DD:EE:05 || fail "forget failed"
grep -q "ee:05" "$T/u/iot_static" && fail "forget kept the fixed address"
grep -q "aa:bb:cc:dd:ee:01" "$T/u/iot_static" || fail "forget dropped another device"
grep -q "aa:bb:cc:dd:ee:05" "$T/u/iot_forget" || fail "forget not recorded"
rm -f "$T/u/iot_static" "$T/u/iot_forget"

# forget-device: every setting for the MACs goes, others stay; hidden; one commit.
echo 0 > "$T/u/iot_home_lock"
echo "aa:bb:cc:00:00:20 AA-BB-CC-00-00-90 aa:bb:cc:00:00:91" > "$T/u/iot_home_allow"; echo "aa:bb:cc:00:00:91" > "$T/u/iot_home_keep"
echo "aa:bb:cc:00:00:90=5/2 aa:bb:cc:00:00:20=3/3" > "$T/u/iot_caps"; echo "AA:BB:CC:00:00:91" > "$T/u/iot_noinet"
echo "aa:bb:cc:00:00:90 aa:bb:cc:00:00:20" > "$T/u/iot_guest_fast"; echo "aa:bb:cc:00:00:90" > "$T/u/iot_lan_allow"
echo "aa:bb:cc:00:00:91,192.168.50.20" > "$T/u/iot_static"; : > "$T/u/iot_forget"; : > "$T/u/iot_hidden_devices"; echo 1 > "$T/u/iot_hidden"
echo "aa:bb:cc:00:00:90=1700000001 aa:bb:cc:00:00:20=1700000002" > "$T/u/iot_home_seen"
h forget-device aa:bb:cc:00:00:91,AA-BB-CC-00-00-90 || fail "forget-device failed"
grep -qi "00[:-]00[:-]9[01]" "$T/u/iot_home_allow" "$T/u/iot_home_keep" "$T/u/iot_caps" "$T/u/iot_guest_fast" "$T/u/iot_lan_allow" && fail "forget-device left allow list, pin, cap or switch entries"
grep -qi "00:91" "$T/u/iot_noinet" "$T/u/iot_static" && fail "forget-device left settings or the IoT pin"
grep -q "00:00:90" "$T/u/iot_home_seen" && fail "forget-device left the last-seen time"
grep -q "aa:bb:cc:00:00:20=3/3" "$T/u/iot_caps" || fail "forget-device dropped another device's cap"
grep -q "aa:bb:cc:00:00:20" "$T/u/iot_guest_fast" || fail "forget-device dropped another device's switch"
grep -q "aa:bb:cc:00:00:90" "$T/u/iot_hidden_devices" && grep -q "aa:bb:cc:00:00:91" "$T/u/iot_hidden_devices" || fail "forgotten devices not hidden"
[ "$(cat "$T/u/iot_hidden")" = 1 ] || fail "forget-device changed the hide-network-name setting"
grep -q "aa:bb:cc:00:00:91" "$T/u/iot_forget" || fail "forgotten IoT device could be re-pinned"
grep -q "aa:bb:cc:00:00:90" "$T/u/iot_forget" && fail "a device with no fixed address put on the no-re-pin list"
h forget-device "x;y" && fail "forget-device accepted a bad MAC"
# A batch that would empty the locked allow list is refused whole: nothing changes.
echo 1 > "$T/u/iot_home_lock"; echo "aa:bb:cc:00:00:20 aa:bb:cc:00:00:21" > "$T/u/iot_home_allow"; : > "$T/u/iot_home_keep"
before="$(cat "$T/u/iot_home_allow" "$T/u/iot_caps" "$T/u/iot_hidden_devices")"
h forget-device aa:bb:cc:00:00:20,aa:bb:cc:00:00:21 && fail "forgot every allowed device with the lock on"
[ "$(cat "$T/u/iot_home_allow" "$T/u/iot_caps" "$T/u/iot_hidden_devices")" = "$before" ] || fail "a refused forget changed settings"
h forget-device aa:bb:cc:00:00:20,bad && fail "batch with a bad MAC accepted"
[ "$(cat "$T/u/iot_home_allow" "$T/u/iot_caps" "$T/u/iot_hidden_devices")" = "$before" ] || fail "a batch with a bad MAC changed settings"
# A forgotten device that reconnects (20 is on the home radio) is un-hidden.
echo "aa:bb:cc:00:00:20 aa:bb:cc:00:00:99" > "$T/u/iot_hidden_devices"; h home
grep -q "aa:bb:cc:00:00:20" "$T/u/iot_hidden_devices" && fail "reconnected device still hidden"
grep -q "aa:bb:cc:00:00:99" "$T/u/iot_hidden_devices" || fail "offline forgotten device un-hidden"
# entry: one device's setting, others untouched; a new setting un-hides the device.
echo 0 > "$T/u/iot_home_lock"; echo "aa:bb:cc:00:00:20=3/3" > "$T/u/iot_caps"
h entry caps AA-BB-CC-00-00-99 5/2 || fail "entry caps failed"
[ "$(cat "$T/u/iot_caps")" = "aa:bb:cc:00:00:20=3/3 aa:bb:cc:00:00:99=5/2" ] || fail "entry caps wrote '$(cat "$T/u/iot_caps")'"
grep -q "aa:bb:cc:00:00:99" "$T/u/iot_hidden_devices" && fail "a device given a cap stayed hidden"
h entry caps aa:bb:cc:00:00:99 off; [ "$(cat "$T/u/iot_caps")" = "aa:bb:cc:00:00:20=3/3" ] || fail "entry caps off left the cap"
h entry noinet aa:bb:cc:00:00:99 on; grep -q "aa:bb:cc:00:00:99" "$T/u/iot_noinet" || fail "entry noinet on did not save"
h entry noinet aa:bb:cc:00:00:99 off; grep -q "aa:bb:cc:00:00:99" "$T/u/iot_noinet" && fail "entry noinet off left the entry"
h entry caps aa:bb:cc:00:00:99 "5/2;reboot" && fail "entry accepted a bad cap"
h entry static aa:bb:cc:00:00:99 on && fail "entry accepted a list it does not own"
rm -f "$T/u/iot_caps" "$T/u/iot_noinet" "$T/u/iot_guest_fast" "$T/u/iot_lan_allow" "$T/u/iot_static" "$T/u/iot_forget" "$T/u/iot_hidden_devices" "$T/u/iot_hidden" "$T/u/iot_home_seen"

# --- local names: hosts file, dnsmasq lines, DHCP hands out the router, and back again.
cat > "$T/bin/uci9" <<EOF
#!/bin/sh
echo "uci \$*" >> "$T/calls"
case "\$*" in
  *iot_dns_on*) cat "$T/dns_on" ;;
  *iot_dns_doh_provider*) echo quad9 ;;
  *iot_dns_doh*) cat "$T/doh_on" 2>/dev/null || echo 0 ;;
  *iot_dns_domain*) if [ -f "$T/dns_nl" ]; then printf 'ho\nme\nserver=6.6.6.6\n'; else echo "Ho me!"; fi ;;
  *iot_dns_router*) echo "router Talha" ;;
  *iot_dns_hosts*) echo "nas=192.168.0.9 bad=999.x cam=192.168.50.187" ;;
  *iot_dns_upstream*) echo "1.1.1.1 evil;rm 9.9.9.9 999.1.1.1 1.2.3" ;;
  *"get openvpn.archer_boot.iot_dns_prev6"*) cat "$T/prev6" 2>/dev/null ;;
  "set openvpn.archer_boot.iot_dns_prev6="*) v="\$*"; echo "\${v#set openvpn.archer_boot.iot_dns_prev6=}" > "$T/prev6" ;;
  *"get openvpn.archer_boot.iot_names"*) printf '%s\n' "aa:bb:cc:dd:ee:07=Living Room TV" "aa:bb:cc:00:00:55=No Lease" ;;
  "-q get dhcp.lan.dhcp_option") cat "$T/dhcp_opt" ;;
  "set dhcp.lan.dhcp_option="*) v="\$*"; echo "\${v#set dhcp.lan.dhcp_option=}" > "$T/dhcp_opt" ;;
  "commit dhcp") ;;
  "set "*) exit 0 ;;
  *) exec "$T/bin/uci" "\$@" ;;
esac
EOF
chmod +x "$T/bin/uci9"
printf '%s\n' "1000 aa:bb:cc:dd:ee:07 192.168.0.50 laptop *" > "$T/leases"
echo "3,192.168.0.1 6,1.1.1.1,1.0.0.1" > "$T/dhcp_opt"; echo 1 > "$T/dns_on"
printf 'option domain-name-servers 2001:db8::1;\n\noption x y;\n' > "$T/dhcp6s.conf"; : > "$T/calls"
iot "$T/bin/uci9" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
[ "$(cat "$T/dhcp_opt")" = "3,192.168.0.1 6,192.168.0.1" ] || fail "DHCP not handing out the router as DNS: $(cat "$T/dhcp_opt")"
for l in "192.168.0.1 router.ho-me" "192.168.0.1 talha.ho-me" "192.168.0.9 nas.ho-me" "192.168.50.187 cam.ho-me" "192.168.0.50 living-room-tv.ho-me"; do
  grep -qxF "$l" "$T/run/hosts" || fail "hosts file lacks '$l': $(cat "$T/run/hosts")"
done
grep -q "bad\|no-lease" "$T/run/hosts" && fail "hosts file has a bad record or a device without an address"
for l in "domain=ho-me" "local=/ho-me/" "addn-hosts=$T/run/hosts" "no-resolv" "server=1.1.1.1" "server=9.9.9.9"; do
  grep -qxF "$l" "$T/dnsmasq.conf" || fail "dnsmasq.conf lacks '$l'"
done
grep "^server=" "$T/dnsmasq.conf" | grep -q "evil\|rm\|999\|=1\.2\.3$" && fail "a bad upstream server reached dnsmasq.conf"   # (server lines only: the temp path may contain "rm")
[ "$(cat "$T/prev6")" = "6,1.1.1.1,1.0.0.1" ] || fail "the previous DHCP DNS setting was not remembered"
# A suffix saved with line breaks in it stays one label, never extra dnsmasq lines.
: > "$T/dns_nl"; iot "$T/bin/uci9" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
grep -qxF "domain=homeserver6-6-6-6" "$T/dnsmasq.conf" || fail "suffix with line breaks: $(grep '^domain=' "$T/dnsmasq.conf")"
grep -qx "me\|server=6.6.6.6" "$T/dnsmasq.conf" && fail "a line break in the suffix became a dnsmasq line"
rm -f "$T/dns_nl"; iot "$T/bin/uci9" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
# Settings dnsmasq refuses are not left in place.
before="$(cat "$T/dnsmasq.conf")"; : > "$T/dnsmasq_reject"; echo 0 > "$T/dns_on"
iot "$T/bin/uci9" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
[ "$(cat "$T/dnsmasq.conf")" = "$before" ] || fail "a block dnsmasq refused was left in dnsmasq.conf"
rm -f "$T/dnsmasq_reject" "$T/run/dnsmasq.bad"; echo 1 > "$T/dns_on"
iot "$T/bin/uci9" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
has "iptables -t nat -I prerouting_rule_dns 1 -i br-lan -d 192.168.0.1 -p udp --dport 53 -j ACCEPT"
has "iptables -t nat -I prerouting_rule_dns 1 -i br-lan -d 192.168.0.1 -p tcp --dport 53 -j ACCEPT"
grep -q "domain-name-servers" "$T/dhcp6s.conf" && fail "IPv6 DNS servers still advertised"
grep -q "option x y" "$T/dhcp6s.conf" || fail "other DHCPv6 options lost"
# DNS over HTTPS: the forwarder runs against the chosen provider; dnsmasq uses only it
# while it answers, and the plain servers while it doesn't.
: > "$T/run/ui/doh.lua"; : > "$T/run/ui/cacert.pem"; echo 1 > "$T/doh_on"; : > "$T/doh_healthy"; : > "$T/calls"
iot "$T/bin/uci9" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
i=0; while [ $i -lt 30 ] && ! grep -qF "doh.lua 5053" "$T/calls"; do sleep 0.1; i=$((i + 1)); done
has "doh.lua 5053 9.9.9.9 dns.quad9.net $T/run/ui/cacert.pem"
grep -qxF "server=127.0.0.1#5053" "$T/dnsmasq.conf" || fail "dnsmasq not using the DNS-over-HTTPS forwarder"
grep -qxF "server=1.1.1.1" "$T/dnsmasq.conf" && fail "plain DNS server still in use next to DNS over HTTPS"
rm -f "$T/doh_healthy"
iot "$T/bin/uci9" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
grep -qxF "server=1.1.1.1" "$T/dnsmasq.conf" || fail "no fallback to plain DNS while the forwarder is not answering"
grep -q "127.0.0.1#5053" "$T/dnsmasq.conf" && fail "dnsmasq still pointed at a forwarder that is not answering"
echo 0 > "$T/doh_on"
iot "$T/bin/uci9" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
[ -e "$T/run/doh.pid" ] && fail "DNS-over-HTTPS forwarder left running after it was switched off"
# Off again: DHCP hands out the upstream servers, the dnsmasq lines go.
echo 0 > "$T/dns_on"
iot "$T/bin/uci9" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
[ "$(cat "$T/dhcp_opt")" = "3,192.168.0.1 6,1.1.1.1,1.0.0.1" ] || fail "DHCP DNS not put back as it was: $(cat "$T/dhcp_opt")"
grep -q "^domain=\|no-resolv" "$T/dnsmasq.conf" && fail "local-names lines left in dnsmasq.conf"
has "iptables -t nat -D prerouting_rule_dns -i br-lan -d 192.168.0.1 -p udp --dport 53 -j ACCEPT"
: > "$T/leases"; rm -f "$T/dhcp6s.conf"

# --- speed limits don't need the IoT network (uci7 has it switched off).
echo 0 > "$T/u/iot_home_lock"; echo "aa:bb:cc:00:00:20=5/2" > "$T/u/iot_caps"; rm -f "$T/run/shape.sig"; : > "$T/inittab"; : > "$T/calls"
h sync
has "tc class add dev br-lan parent 1:1 classid 1:11 htb rate 5mbit ceil 5mbit"
grep -q "ax10-iot-watch" "$T/inittab" || fail "no watcher kept for speed limits with the IoT network off"
# ...and the dashboard's own "apply speed limits" call (`shape`) registers the watcher
# too: with a guest limit set and no guest connected yet, nothing else would.
echo 0 > "$T/u/iot_usage_on"; : > "$T/inittab"; h shape
grep -q "ax10-iot-watch" "$T/inittab" || fail "\`shape\` did not register the watcher speed limits need"
h entry caps aa:bb:cc:00:00:20 off; : > "$T/calls"; h sync
has "tc qdisc del dev br-lan root"
rm -f "$T/u/iot_caps" "$T/u/iot_usage_on"

# --- join-home page: a listed device on the guest Wi-Fi (08) gets the page, not internet.
echo 1 > "$T/u/iot_home_lock"; echo "aa:bb:cc:00:00:20 aa:bb:cc:00:00:08" > "$T/u/iot_home_allow"; : > "$T/calls"
h home
has "iptables -t nat -A AX10_PORTAL_NAT -m mac --mac-source aa:bb:cc:00:00:08 -p tcp --dport 80 -j DNAT --to-destination 192.168.0.1:8081"
has "iptables -A AX10_PORTAL -m mac --mac-source aa:bb:cc:00:00:08 -j REJECT"
has "ip6tables -A AX10_PORTAL -m mac --mac-source aa:bb:cc:00:00:08 -j REJECT"
has "iptables -A AX10_PORTAL_IN -p tcp --dport 8081 -j DROP"
i=0; while [ $i -lt 30 ] && ! grep -qF "server.lua" "$T/calls"; do sleep 0.1; i=$((i + 1)); done
has "server.lua $T/run/portal 192.168.0.1 8081 5354"
has "iptables -t nat -A AX10_PORTAL_NAT -m mac --mac-source aa:bb:cc:00:00:08 -p udp --dport 53 -j DNAT --to-destination 192.168.0.1:5354"
has "ip6tables -A AX10_PORTAL_IN6 -m mac --mac-source aa:bb:cc:00:00:08 -p udp --dport 53 -j REJECT"
has "iptables -A AX10_PORTAL_IN -m mac --mac-source aa:bb:cc:00:00:08 -p tcp --dport 443 -j REJECT --reject-with tcp-reset"
grep -q "mac-source aa:bb:cc:00:00:20 .*REJECT\|mac-source aa:bb:cc:00:00:09 .*REJECT" "$T/calls" && fail "join page for a device not on the guest Wi-Fi or not listed"
grep -q 'pa&lt;ss&amp;&quot;w0rd' "$T/run/portal/index.html" || fail "join page lacks the escaped home password"
has "wl -i wl1.3 deauthenticate AA:BB:CC:00:00:08"
grep -q "home net" "$T/run/portal/index.html" || fail "join page lacks the home SSID"
grep -q "<string>pa&lt;ss&amp;&quot;w0rd</string>" "$T/run/portal/home.mobileconfig" || fail "Wi-Fi profile lacks the escaped password"
grep -q "<key>SSID_STR</key><string>home net</string>" "$T/run/portal/home.mobileconfig" || fail "Wi-Fi profile lacks the SSID"
# Unchanged on the next run; gone once it is off the list.
: > "$T/calls"; h home
grep -q "server.lua" "$T/calls" && fail "join page server restarted with no change"
grep -q "deauthenticate AA:BB:CC:00:00:08" "$T/calls" && fail "device on the join page disconnected again"
echo "aa:bb:cc:00:00:20" > "$T/u/iot_home_allow"; : > "$T/calls"; h home
has "iptables -t nat -D PREROUTING -i br-lan -j AX10_PORTAL_NAT"
[ -e "$T/run/portal.pid" ] && fail "join page server left running"
echo 0 > "$T/u/iot_home_lock"; h home

# --- automatic whole-connection limit: the lanes' rates change in place, and the
# controller runs with the usual speeds and the range.
: > "$T/run/ui/autorate.lua"; echo 1 > "$T/wan_on"; : > "$T/prio_on"; : > "$T/glow_on"; : > "$T/auto_on"; rm -f "$T/run/shape.sig"; : > "$T/calls"
iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
i=0; while [ $i -lt 30 ] && ! grep -qF "autorate.lua" "$T/calls"; do sleep 0.1; i=$((i + 1)); done
has "autorate.lua $T/run/rate.sh $T/run/autorate.stat br-lan ifb0 90 40 45 200 20 120"
[ -f "$T/run/rate.sh" ] || fail "no rate script written"
: > "$T/calls"; sh "$T/run/rate.sh" 60000 20000 || fail "rate script failed"
has "tc class change dev br-lan parent 1: classid 1:1 htb rate 60000kbit ceil 60000kbit burst 150000 cburst 150000"
has "tc class change dev br-lan parent 1:1 classid 1:2 htb rate 24000kbit ceil 60000kbit burst 150000 cburst 150000 prio 0"
has "tc class change dev br-lan parent 1:1 classid 1:10 htb rate 30000kbit ceil 60000kbit burst 150000 cburst 150000 prio 1"
has "tc class change dev br-lan parent 1:3 classid 1:4 htb rate 6000kbit ceil 60000kbit burst 150000 cburst 150000 prio 2"
has "tc class change dev ifb0 parent 1: classid 1:1 htb rate 20000kbit ceil 20000kbit burst 50000 cburst 50000"
sh "$T/run/rate.sh" "1;reboot" 20000 2>/dev/null && fail "rate script accepted a bad rate"
# Unchanged on the next run; stopped when automatic is switched off.
: > "$T/calls"; iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
grep -q "autorate.lua" "$T/calls" && fail "controller restarted with no change"
rm -f "$T/auto_on"; : > "$T/calls"; iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true
[ -e "$T/run/autorate.pid" ] && fail "controller left running after automatic was switched off"
has "tc class change dev br-lan parent 1: classid 1:1 htb rate 90000kbit ceil 90000kbit"
has "tc class change dev ifb0 parent 1: classid 1:1 htb rate 40000kbit ceil 40000kbit"
rm -f "$T/prio_on" "$T/glow_on"; echo 0 > "$T/wan_on"; iot "$T/bin/uci3" "$ROOT/ax10.sh" shape >/dev/null 2>&1 || true

# --- data usage: counted from the internet connection's counters, across counter
# restarts, and brought back from flash after a reboot.
M=1048576; day="$(date +%Y-%m-%d)"; mon="${day%-*}"
mkdir -p "$T/net/wan0/statistics"; rm -f "$T/run/usage" "$T/run/usage.last" "$T/run/usage.saved" "$T/u/iot_usage_"*
wanc() { echo $(($1 * M)) > "$T/net/wan0/statistics/rx_bytes"; echo $(($2 * M)) > "$T/net/wan0/statistics/tx_bytes"; }
usage() { WAN_DEV=wan0 USAGE_BOOT="$BOOTID" iot "$T/bin/uci7" "$ROOT/ax10.sh" usage >/dev/null 2>&1; awk -v k="$1" '$1 == k { printf "%.0f/%.0f", $2 / 1048576, $3 / 1048576 }' "$T/run/usage"; }
# The very first run on a router that has been up a while: what the counter already
# holds is history from before counting began, so it only sets the baseline.
BOOTID=boot1
wanc 100 50; [ "$(usage "T:$day")" = "0/0" ] || fail "usage: history from before counting began was counted ($(usage "T:$day"))"
wanc 400 90; [ "$(usage "T:$day")" = "300/40" ] || fail "usage: growth not added ($(usage "T:$day"))"
[ "$(usage "M:$mon")" = "300/40" ] || fail "usage: month total wrong ($(usage "M:$mon"))"
wanc 10 5;   [ "$(usage "T:$day")" = "310/45" ] || fail "usage: a restarted counter not counted as new ($(usage "T:$day"))"
[ "$(usage "T:$day")" = "310/45" ] || fail "usage: an unchanged counter was counted again"
grep -q "$day=0/0" "$T/u/iot_usage_days" || fail "usage: saved to flash more than once in 4 hours ($(cat "$T/u/iot_usage_days" 2>/dev/null))"
rm -f "$T/run/usage.saved"; usage "T:$day" >/dev/null                      # the 4 hours are up
grep -q "$day=310/45" "$T/u/iot_usage_days" || fail "usage: not saved to flash ($(cat "$T/u/iot_usage_days" 2>/dev/null))"
[ "$(cat "$T/u/iot_usage_boot")" = boot1 ] || fail "usage: the boot it is counting in was not recorded"
# The baseline file lost while the router keeps running: nothing is counted twice.
rm -f "$T/run/usage.last"; [ "$(usage "T:$day")" = "310/45" ] || fail "usage: lost baseline made it count the same traffic again ($(usage "T:$day"))"
wanc 12 6; [ "$(usage "T:$day")" = "312/46" ] || fail "usage: counting did not carry on after a lost baseline ($(usage "T:$day"))"
# A reboot: RAM gone, a new boot, the counter starts again from zero: all of it is new.
rm -f "$T/run/usage" "$T/run/usage.last" "$T/run/usage.saved"; BOOTID=boot2; wanc 7 3
# (From the last save, 310/45: what came after it went with the RAM.)
[ "$(usage "T:$day")" = "317/48" ] || fail "usage: log not carried over a reboot, or the new boot's traffic not counted ($(usage "T:$day"))"
# Device history: the previous calendar month is kept on the 1st of March, May and July too.
if date -d @0 +%Y >/dev/null 2>&1; then
  for d in 2026-03-01 2026-05-01 2026-07-01 2026-01-01; do
    y="${d%%-*}"; m="${d#*-}"; m="${m%%-*}"; m=$((1$m - 100)); if [ $m = 1 ]; then pv="$((y - 1))-12"; else pv="$(printf '%04d-%02d' $y $((m - 1)))"; fi
    printf '%s\n' "D:$pv:aa:bb:cc:00:00:20 1048576 1048576" "D:2025-01:aa:bb:cc:00:00:20 1048576 1048576" > "$T/run/usage"
    WAN_DEV=wan0 USAGE_BOOT=boot2 USAGE_DAY="$d" iot "$T/bin/uci7" "$ROOT/ax10.sh" usage >/dev/null 2>&1
    grep -q "^D:$pv:" "$T/run/usage" || fail "usage: last month's device figures ($pv) dropped on $d"
    grep -q "^D:2025-01:" "$T/run/usage" && fail "usage: old device figures kept on $d"
  done
fi
# Per device: the radio for devices on our Wi-Fi, TP-Link's statistics (tfstats) for
# the rest, and a device's tfstats growth while it was on our Wi-Fi is never added.
cat > "$T/bin/ubus" <<EOF
#!/bin/sh
[ "\$2" = tfstats ] || exit 1
echo '{ "tfslist": ['
while read ip mac rx tx; do printf '\t\t{\n\t\t\t"ip": "%s",\n\t\t\t"mac": "%s",\n\t\t\t"total_byte": 1,\n\t\t\t"total_rx_byte": %s,\n\t\t\t"total_tx_byte": %s,\n\t\t},\n' "\$ip" "\$mac" "\$rx" "\$tx"; done < "$T/tf"
echo '] }'
EOF
chmod +x "$T/bin/ubus"
tf() { printf '%s\n' "192.168.0.20 aa-bb-cc-00-00-20 $(($1 * M)) $(($2 * M))" "192.168.0.30 AA-BB-CC-00-00-30 $(($3 * M)) $(($4 * M))" "100.82.1.2 60-83-e7-30-23-bd $((50 * M)) 0" > "$T/tf"; }
sta() { printf 'tx total bytes: %s\nrx data bytes: %s\n' $(($1 * M)) $(($2 * M)) > "$T/sta.AA:BB:CC:00:00:20"; }
dev() { awk -v k="D:$mon:$1" '$1 == k { printf "%.0f/%.0f", $2 / 1048576, $3 / 1048576 }' "$T/run/usage"; }
rm -f "$T/run/usage" "$T/run/usage.last" "$T/run/usage.saved"; BOOTID=boot3; wanc 1 1
sta 10 5; tf 100 100 30 3; usage "T:$day" >/dev/null                                  # a new boot: all of it counts
[ "$(dev aa:bb:cc:00:00:20)" = "10/5" ] || fail "usage: a device on our Wi-Fi not counted from the radio ($(dev aa:bb:cc:00:00:20))"
[ "$(dev aa:bb:cc:00:00:30)" = "30/3" ] || fail "usage: a device elsewhere not counted from tfstats ($(dev aa:bb:cc:00:00:30))"
grep -q "60:83:e7" "$T/run/usage" && fail "usage: the router's own WAN address counted as a device"
sta 20 10; tf 200 200 40 4; usage "T:$day" >/dev/null
[ "$(dev aa:bb:cc:00:00:20)" = "20/10" ] || fail "usage: tfstats added for a device the radio counts ($(dev aa:bb:cc:00:00:20))"
[ "$(dev aa:bb:cc:00:00:30)" = "40/4" ] || fail "usage: tfstats growth not added ($(dev aa:bb:cc:00:00:30))"
rm -f "$T/sta.AA:BB:CC:00:00:20"; tf 210 205 40 4; usage "T:$day" >/dev/null          # it moved to the satellite
[ "$(dev aa:bb:cc:00:00:20)" = "30/15" ] || fail "usage: a device that moved off our Wi-Fi counted wrong ($(dev aa:bb:cc:00:00:20); want only what came after)"
# Updated in the middle of a boot (readings without tfstats): its totals so far are not ours to add.
grep -v "^t:" "$T/run/usage.last" > "$T/run/usage.last.x"; mv "$T/run/usage.last.x" "$T/run/usage.last"
tf 210 205 90 9; usage "T:$day" >/dev/null
[ "$(dev aa:bb:cc:00:00:30)" = "40/4" ] || fail "usage: tfstats history counted after an update mid-boot ($(dev aa:bb:cc:00:00:30))"
tf 210 205 95 10; usage "T:$day" >/dev/null
[ "$(dev aa:bb:cc:00:00:30)" = "45/5" ] || fail "usage: tfstats not counted after the baseline ($(dev aa:bb:cc:00:00:30))"
rm -f "$T/bin/ubus" "$T/tf" "$T/sta."*
rm -rf "$T/net/wan0" "$T/run/usage"* "$T/u/iot_usage_"*

# --- router load: busy share and throughput per pass; a note after a minute nearly full.
mkdir -p "$T/proc" "$T/net/wan0/statistics"; rm -f "$T/run/load."*
pst() { echo "cpu  $1 0 $2 $3 0 0 $4 0 0 0" > "$T/proc/stat"; echo "$5.37 1.00" > "$T/proc/uptime"; echo "2.50 2.00 1.00 1/100 200" > "$T/proc/loadavg"; }
ld() { PROC="$T/proc" WAN_DEV=wan0 iot "$T/bin/uci7" "$ROOT/ax10.sh" load >/dev/null 2>&1; }
LG="$T/run/iot.log"; : > "$LG"
wanc 0 0; pst 100 100 800 0 1000; ld
[ -s "$T/run/load.log" ] && fail "load: a reading made without an earlier one to compare with"
wanc 30 3; pst 400 300 1100 200 1015; ld
[ "$(tail -n 1 "$T/run/load.log")" = "1015 70 20 2.50 16777 1677" ] || fail "load: reading wrong ($(tail -n 1 "$T/run/load.log"))"
lu_=1015; lc_=1100; li_=1100
full() { k=0; while [ $k -lt "$1" ]; do lu_=$((lu_ + 15)); lc_=$((lc_ + 950)); li_=$((li_ + $2)); pst "$lc_" 300 "$li_" 200 "$lu_"; ld; k=$((k + 1)); done; }
full 3 50; [ "$(grep -c "router processor" "$LG")" = 0 ] || fail "load: noted before a minute was up"
full 1 50; grep -q "router processor 95% busy for about a minute" "$LG" || fail "load: a minute nearly full not noted ($(tail -n 2 "$LG"))"
full 3 50; [ "$(grep -c "router processor" "$LG")" = 1 ] || fail "load: noted more than once for one busy spell"
full 1 900; full 4 50; [ "$(grep -c "router processor" "$LG")" = 2 ] || fail "load: a new busy spell after it eased off not noted"
grep "router processor" "$LG" | grep -qi "pppd\|password" && fail "load: a command line got into the log"
rm -rf "$T/proc" "$T/run/load."* "$T/net/wan0"

# --- The IoT slot waits for TP-Link's hostapd (at boot the copy in flash starts first):
# until hostapd answers, the slot is left alone; everything else still goes ahead.
: > "$T/hapd_down"; rm -f "$T/run/wifi.wait" "$T/run/fw.sig" "$T/run/vif.open"; : > "$T/calls"; : > "$T/run/iot.log"
run apply >/dev/null 2>&1 || true
grep -q "brctl addif br-iot wl1.4\|hostapd_cli -i wl1.4 set ssid\|wl -i wl1 down" "$T/calls" && fail "the IoT slot was touched before hostapd was running"
grep -q "waiting for TP-Link's Wi-Fi" "$T/run/iot.log" || fail "no note that the IoT slot waits for hostapd"
grep -q "AX10_IOT_FWD" "$T/rules" || fail "the firewall waited for hostapd too"
# A slot on the air without encryption while hostapd isn't running it: off the air on the second look.
echo up > "$T/run/bss.wl1.4"; echo 0 > "$T/run/wsec.wl1.4"; : > "$T/calls"
run apply >/dev/null 2>&1 || true
grep -q "wl -i wl1.4 bss down" "$T/calls" && fail "an open slot was taken down on the first look (hostapd may be starting)"
run apply >/dev/null 2>&1 || true
grep -q "wl -i wl1.4 bss down" "$T/calls" || fail "an open IoT slot without hostapd was left on the air"
# hostapd up: the slot is set up as usual.
rm -f "$T/hapd_down" "$T/run/wsec.wl1.4"; : > "$T/calls"
run apply >/dev/null 2>&1 || true
grep -q "hostapd_cli -i wl1.4 set ssid" "$T/calls" || fail "the IoT slot was not set up once hostapd answered"
grep -q "TP-Link's Wi-Fi is up" "$T/run/iot.log" || fail "no note that the wait for hostapd ended"

# --- IPv6 client guard: restarted only after two misses, and only if its config is there.
cat > "$T/bin/dhcp6c" <<EOF
#!/bin/sh
echo "dhcp6c \$*" >> "$T/calls"
EOF
chmod +x "$T/bin/dhcp6c"; mkdir -p "$T/d6" "$T/net/ppp9"; printf 'interface ppp9 {\n\tsend ia-pd 1;\n};\n' > "$T/d6/dhcp6c.conf"
cat > "$T/bin/uci10" <<EOF
#!/bin/sh
case "\$*" in *network.wan.ifname*) echo eth9 ;; *network.wan.type*) echo normal ;; *) exec "$T/bin/uci" "\$@" ;; esac
EOF
chmod +x "$T/bin/uci10"
# pidof stub: "running" (and which pids) is whatever $T/pidof_out holds.
cat > "$T/bin/pidof" <<EOF
#!/bin/sh
[ -s "$T/pidof_out" ] && cat "$T/pidof_out"
EOF
chmod +x "$T/bin/pidof"
guard() { DHCP6C_DIR="$1" DHCP6C_BIN="$T/bin/dhcp6c" PIDOF="$T/bin/pidof" DHCP6C_SETTLE=0 iot "$T/bin/uci10" "$ROOT/ax10.sh" guard >/dev/null 2>&1 || true; }
started() { i=0; while [ $i -lt 10 ] && ! grep -q "^dhcp6c " "$T/calls"; do sleep 0.1; i=$((i + 1)); done; grep -q "^dhcp6c " "$T/calls"; }
rm -f "$T/run/dhcp6c.miss" "$T/run/dhcp6c.tries" "$T/pidof_out"; : > "$T/calls"
guard "$T/nowhere"; guard "$T/nowhere"
started && fail "IPv6 client started although it has no config"
guard "$T/d6"; started && fail "IPv6 client restarted on the first miss"
# The config rewritten between the two checks (a connect in progress): start over.
printf 'interface ppp9 {\n\tsend ia-pd 2;\n};\n' > "$T/d6/dhcp6c.conf"; guard "$T/d6"
started && fail "IPv6 client restarted although its config had just been rewritten"
# Running after all: nothing to do.
echo 123 > "$T/pidof_out"; guard "$T/d6"; guard "$T/d6"; started && fail "IPv6 client started next to a running one"
rm -f "$T/pidof_out"; guard "$T/d6"; guard "$T/d6"
started || fail "IPv6 client not restarted after two misses"
has "dhcp6c -f -p $T/d6/dhcp6c.pid -c $T/d6/dhcp6c.conf -I eth9 -t internet ppp9"
# It did not hold: the next try waits (back-off), however often the check runs.
: > "$T/calls"; guard "$T/d6"; guard "$T/d6"; guard "$T/d6"
started && fail "IPv6 client restarted again at once after a restart that did not hold"
# The router's own client appears while ours is starting: ours is the one that goes.
rm -f "$T/run/dhcp6c.tries" "$T/run/dhcp6c.miss"; : > "$T/calls"
printf '#!/bin/sh\necho "dhcp6c $*" >> "%s/calls"\necho "111 222" > "%s/pidof_out"\nsleep 5\n' "$T" "$T" > "$T/bin/dhcp6c"
guard "$T/d6"; guard "$T/d6"
grep -q "left it to that one" "$T/run/iot.log" || fail "a second IPv6 client was left running next to the router's own"
# Garbage in the retry file must not stop the watcher (it would be respawned into the same crash).
for junk in "1 2x" "x 5" "9999999999999999999999 1" "3" ""; do
  printf '%s\n' "$junk" > "$T/run/dhcp6c.tries"; rm -f "$T/pidof_out" "$T/run/dhcp6c.miss"
  DHCP6C_DIR="$T/d6" DHCP6C_BIN="$T/bin/dhcp6c" PIDOF="$T/bin/pidof" DHCP6C_SETTLE=0 iot "$T/bin/uci10" "$ROOT/ax10.sh" guard >/dev/null 2>&1 || fail "IPv6 guard died on a retry file holding '$junk'"
  DHCP6C_DIR="$T/d6" DHCP6C_BIN="$T/bin/dhcp6c" PIDOF="$T/bin/pidof" DHCP6C_SETTLE=0 iot "$T/bin/uci10" "$ROOT/ax10.sh" guard >/dev/null 2>&1 || fail "IPv6 guard died on its second check with '$junk'"
done
rm -f "$T/pidof_out" "$T/run/dhcp6c.tries" "$T/run/dhcp6c.miss"

# --- a pid file from before start times were recorded (an upgrade without a reboot):
# the old helper is recognised by its command line and stopped. Needs /proc.
if [ -r "/proc/$$/cmdline" ]; then
  mkdir -p "$T/old/portal"; printf '#!/bin/sh\nsleep 60\n' > "$T/old/portal/server.lua"
  sh "$T/old/portal/server.lua" & op=$!; sleep 0.3
  echo "$op" > "$T/run/portal.pid"; echo "aa:bb:cc:00:00:08" > "$T/run/portal_macs"
  echo 0 > "$T/u/iot_home_lock"; h home
  sleep 0.3; kill -0 "$op" 2>/dev/null && { kill "$op"; fail "a helper from the previous version was left running"; }
  # ...but a pid that is somebody else's process is left alone.
  sleep 60 & op=$!; echo "$op" > "$T/run/portal.pid"; echo "aa:bb:cc:00:00:08" > "$T/run/portal_macs"; h home
  kill -0 "$op" 2>/dev/null || fail "an unrelated process was killed through a stale pid file"
  kill "$op" 2>/dev/null; wait "$op" 2>/dev/null || true
fi

# --- Forget: a forgotten IoT device is not pinned again from its old lease.
cat > "$T/bin/uci8" <<EOF
#!/bin/sh
echo "uci \$*" >> "$T/calls"
case "\$*" in
  "set "*) exit 0 ;;
  *iot_forget*) echo "aa:bb:cc:dd:ee:05" ;;
  *iot_lock*) echo 0 ;;
  *) exec "$T/bin/uci" "\$@" ;;
esac
EOF
chmod +x "$T/bin/uci8"
printf '%s\n' "1000 AA:BB:CC:DD:EE:05 192.168.50.150 cam *" > "$T/leases"; rm -f "$T/run/open_until"; : > "$T/calls"
iot "$T/bin/uci8" "$ROOT/ax10.sh" apply >/dev/null 2>&1 || true
grep -q "iot_static=.*aa:bb:cc:dd:ee:05" "$T/calls" && fail "forgotten device pinned again from its lease"
: > "$T/leases"

# --- a burst of "apply now" requests becomes one or two passes, and none is lost.
rm -f "$T/run/sync.want" "$T/kicks"; hold_lock
kp=""; for k in 1 2 3 4 5 6 7 8; do KICK_COUNT="$T/kicks" LOCK_WAIT=20 iot "$T/bin/uci7" "$ROOT/ax10.sh" kick >/dev/null 2>&1 & kp="$kp $!"; done
sleep 1; [ -e "$T/run/sync.want" ] || fail "kick left no note while the lock was held"
free_lock
for p in $kp; do set +e; wait "$p"; kst=$?; set -e; [ "$kst" = 0 ] || fail "a request in the burst failed (exit $kst)"; done
n="$(wc -l < "$T/kicks" 2>/dev/null | tr -d ' ')"
[ "${n:-0}" -ge 1 ] && [ "$n" -le 2 ] || fail "8 requests in a row made ${n:-0} passes (want 1 or 2)"
[ ! -e "$T/run/sync.want" ] || fail "a note was left after the burst"
# A request that gives up waiting keeps its note, and the watcher's next pass applies it.
hold_lock; set +e; ( LOCK_WAIT=1 h kick ); set -e
[ -e "$T/run/sync.want" ] || fail "a request that could not be applied was dropped"
free_lock; h pass
[ ! -e "$T/run/sync.want" ] || fail "the watcher's pass did not take the kept request"
# One watcher at a time: a second one exits (after a pause, so init doesn't spin).
rm -f "$T/run/watch.lock"
INTERVAL=300 iot "$T/bin/uci7" "$ROOT/ax10.sh" watch >/dev/null 2>&1 & w1=$!
sleep 1; set +e; INTERVAL=300 iot "$T/bin/uci7" "$ROOT/ax10.sh" watch >/dev/null 2>&1; st=$?; set -e
[ "$st" = 75 ] || fail "a second watcher did not stand down (exit $st)"
kill -0 "$w1" 2>/dev/null || fail "the first watcher died"
# $w1 is the test's subshell; the watcher runs below it. Let its first pass finish,
# then stop the watcher itself, so it doesn't run passes in the middle of later tests.
i=0; while [ $i -lt 50 ] && pgrep -f "$ROOT/ax10.sh pass" >/dev/null 2>&1; do sleep 0.2; i=$((i + 1)); done
pkill -f "$ROOT/ax10.sh watch" 2>/dev/null || true; kill "$w1" 2>/dev/null; wait "$w1" 2>/dev/null || true
sleep 1; pgrep -f "$ROOT/ax10.sh watch" >/dev/null 2>&1 && fail "the test watcher is still running"
# The dashboard's open and close record the window at once and leave the applying
# to the worker ("later"), so the last click is what counts.
: > "$T/calls"; h open 600 later; [ -s "$T/run/open_until" ] || fail "open ... later did not record the window"
h close later; [ ! -e "$T/run/open_until" ] || fail "close later left the window open"
h home-open 600 later; [ -s "$T/run/home_open_until" ] || fail "home-open ... later did not record the window"
h home-close later; [ ! -e "$T/run/home_open_until" ] || fail "home-close later left the window open"
grep -q "^tc \|^iptables \|^wl " "$T/calls" && fail "a \"later\" command applied things itself"
# Switching the IoT network on and off in the settings needs nothing but a sync.
echo 1 > "$T/u/iot_enabled"; : > "$T/calls"; h kick up
has "brctl addif br-iot wl1.4"
echo 0 > "$T/u/iot_enabled"; : > "$T/calls"; h kick
has "brctl delif br-iot wl1.4"
[ "$(grep -c "^dnsmasq " "$T/calls")" -le 1 ] || fail "dnsmasq restarted $(grep -c "^dnsmasq " "$T/calls") times for one switch-off"
: > "$T/calls"; h kick; grep -q "brctl delif" "$T/calls" && fail "the IoT network was taken down again on every sync"
# Up, but our own note of it lost (a run killed mid-move): switching off still takes it down.
echo 1 > "$T/u/iot_enabled"; h kick up; rm -f "$T/run/orig_bridge"
echo 0 > "$T/u/iot_enabled"; : > "$T/calls"; h kick
has "brctl delif br-iot wl1.4"
# ...and a normal run writes the note again when it finds the slot moved without one.
echo 1 > "$T/u/iot_enabled"; h kick up; rm -f "$T/run/orig_bridge"; h kick
[ -s "$T/run/orig_bridge" ] || fail "the missing bridge note was not written again"
echo 0 > "$T/u/iot_enabled"; h kick
rm -f "$T/u/iot_enabled"

# --- `stop` by hand keeps the IoT network down while the watcher runs on for the rest.
run start >/dev/null 2>&1 || true
run stop >/dev/null 2>&1 || true
: > "$T/calls"; run sync >/dev/null 2>&1 || true; run kick >/dev/null 2>&1 || true
grep -q "brctl addbr br-iot\|brctl addif br-iot" "$T/calls" && fail "the watcher brought the IoT network back after stop"
grep -q "dhcp-range=set:iot" "$T/dnsmasq.conf" && fail "IoT addresses handed out again after stop"
: > "$T/calls"; run start >/dev/null 2>&1 || true
has "brctl addif br-iot wl1.4"

echo "ax10.sh tests passed"
