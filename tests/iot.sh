#!/bin/sh
# Offline test for iot.sh: stubs wl/brctl/ip/iptables/uci and a fake /sys/class/net.
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
  assoclist) if [ "\$i" = wl1.3 ]; then echo "assoclist AA:BB:CC:00:00:08"; echo "assoclist AA:BB:CC:00:00:09"; fi ;;
  map) if [ -n "\$2" ]; then [ "\$2" = 0 ] && echo "0x0:" > "$T/map" || echo "0x\$2:" > "$T/map"; else cat "$T/map" 2>/dev/null || echo "0x0:"; fi ;;
esac
EOF
cat > "$T/bin/hostapd_cli" <<EOF
#!/bin/sh
echo "hostapd_cli \$*" >> "$T/calls"
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
chmod +x "$T/bin/"*

# iot <uci stub> <script> <args...>: run iot.sh with every host touch-point stubbed.
iot() {
  u="$1"; s="$2"; shift 2
  env UCI="$u" WL="$T/bin/wl" HAPD_CLI="$T/bin/hostapd_cli" BRCTL="$T/bin/brctl" IP="$T/bin/ip" \
      IPT="$T/bin/iptables" IPT6="$T/bin/ip6tables" TC="$T/bin/tc" \
      MOUNT="$T/bin/mount" UMOUNT="$T/bin/mount" NVRAM="$T/bin/nvram" BRF="$T/brf" \
      WIFI_SH="$T/tplink_brcm.sh" DNSMASQ_CONF="$T/dnsmasq.conf" DNSMASQ_INIT="$T/bin/dnsmasq-init" \
      NET="$T/net" RUN="$T/run" INITTAB="$T/inittab" SELF="$T/iot.sh" WWW="$T/www" LUCI_CTL="$T/ctl" \
      ARP="$T/arp" SYS6="$T/sys6" LEASES="$T/leases" INIT_HUP=true CLIENTS="$T/clients.json" \
      LIFELINE_BIN="$T/bin/dropbear" LIFELINE_PID="$T/run/ssh.pid" PATH="$T/bin:$PATH" \
      sh "$s" "$@"
}
run() { iot "$T/bin/uci" "$ROOT/iot.sh" "$@"; }

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
grep -q "brctl\|-F AX10\|dnsmasq\|hostapd_cli" "$T/calls" && fail "second apply was not idempotent"

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
iot "$T/bin/uci2" "$ROOT/iot.sh" apply >/dev/null 2>&1 || true
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
cp "$ROOT/iot.sh" "$T/iot.sh"; chmod 600 "$T/iot.sh"
iot "$T/bin/uci" "$T/iot.sh" boot >/dev/null 2>&1 || true
[ "$(readlink "$T/net/wl1.4/brport/bridge")" = "../../br-iot" ] || fail "boot did not put wl1.4 in br-iot"
grep -q "ax10-iot-watch" "$T/inittab" || fail "boot did not register the watcher"
# The lifeline starts in the background; give it up to 5 s.
i=0; while [ $i -lt 50 ] && ! grep -qF "dropbear -p" "$T/calls"; do sleep 0.1; i=$((i + 1)); done
has "dropbear -p"

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
  *) exec "$T/bin/uci" "\$@" ;;
esac
EOF
chmod +x "$T/bin/uci3"
echo "aa-bb-cc-00-00-07=10/0" > "$T/caps"     # download-only cap, given with dashes
: > "$T/calls"; : > "$T/qdiscs"
iot "$T/bin/uci3" "$ROOT/iot.sh" shape >/dev/null 2>&1 || true
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
iot "$T/bin/uci3" "$ROOT/iot.sh" shape >/dev/null 2>&1 || true
grep -q "tc qdisc add" "$T/calls" && fail "second sync rebuilt tc"
grep -q -- "-A AX10_SHAPE" "$T/calls" && fail "second sync re-added rules"
# Queues gone (e.g. TP-Link reset them): rebuilt.
: > "$T/qdiscs"; : > "$T/calls"
iot "$T/bin/uci3" "$ROOT/iot.sh" shape >/dev/null 2>&1 || true
has "tc qdisc add dev br-lan root handle 1: htb default 10"
# Whole connection capped: everything skips acceleration, no per-device marks.
echo 1 > "$T/wan_on"; : > "$T/calls"
iot "$T/bin/uci3" "$ROOT/iot.sh" shape >/dev/null 2>&1 || true
has "iptables -t mangle -A AX10_SHAPE -j BLOGSKIP"
has "ip6tables -t mangle -A AX10_SHAPE -j BLOGSKIP"
has "tc class add dev br-lan parent 1: classid 1:1 htb rate 90mbit ceil 90mbit"
has "tc class add dev ifb0 parent 1: classid 1:1 htb rate 40mbit ceil 40mbit"
grep -q -- "-A AX10_SHAPE_IN" "$T/calls" && fail "per-device marks added with the whole connection capped"
# Everything off: cleared, including the old guest-only limit's leftovers.
echo 0 > "$T/wan_on"; echo 0 > "$T/guest_on"; rm -f "$T/caps"
echo "mangle PREROUTING -j AX10_GUEST" >> "$T/rules"; : > "$T/run/guest.sig"; : > "$T/calls"
iot "$T/bin/uci3" "$ROOT/iot.sh" shape >/dev/null 2>&1 || true
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

# Lock 1: held by a live process -> the run gives up and changes nothing.
mkdir -p "$T/run/lock"; echo $$ > "$T/run/lock/pid"
: > "$T/calls"
set +e; LOCK_WAIT=1 run apply >/dev/null 2>&1; st=$?; set -e
[ "$st" -ne 0 ] || fail "apply succeeded while the lock was held"
[ ! -s "$T/calls" ] || fail "apply touched the router while the lock was held"
[ "$(cat "$T/run/lock/pid" 2>/dev/null)" = "$$" ] || fail "live lock was disturbed"
rm -rf "$T/run/lock"

# Lock 2: a lock left by a dead process is taken over.
sh -c 'exit 0' & dead=$!; wait "$dead" 2>/dev/null || true
mkdir -p "$T/run/lock"; echo "$dead" > "$T/run/lock/pid"
rm -f "$T/run/fw.sig"; : > "$T/calls"
run apply >/dev/null 2>&1 || true
[ -s "$T/calls" ] || fail "stale lock was not taken over"
[ ! -e "$T/run/lock" ] || fail "lock left behind after taking over a stale one"

# Lock 3: released after normal runs.
run status >/dev/null 2>&1 || true
run apply >/dev/null 2>&1 || true
[ ! -e "$T/run/lock" ] || fail "lock not released after a normal run"

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
[ ! -e "$T/run/lock" ] || fail "lock left behind after concurrent runs"

echo "iot.sh tests passed"
