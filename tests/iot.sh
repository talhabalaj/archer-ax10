#!/bin/sh
# Offline test for iot.sh: stubs wl/brctl/ip/iptables/uci and a fake /sys/class/net.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/net/wl1.1/brport" "$T/net/wl1.4/brport" "$T/net/br-lan" "$T/run"
ln -s ../../br-lan "$T/net/wl1.4/brport/bridge"
ln -s ../../br-lan "$T/net/wl1.1/brport/bridge"
: > "$T/inittab"; : > "$T/calls"

cat > "$T/bin/uci" <<EOF
#!/bin/sh
case "\$*" in
  *iot_ssid*) echo "wifi iot" ;;
  *iot_key*) echo "password123" ;;
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
chmod +x "$T/bin/"*

run() {
  env UCI="$T/bin/uci" WL="$T/bin/wl" HAPD_CLI="$T/bin/hostapd_cli" BRCTL="$T/bin/brctl" IP="$T/bin/ip" IPT="$T/bin/iptables" \
      MOUNT="$T/bin/mount" UMOUNT="$T/bin/mount" NVRAM="$T/bin/nvram" BRF="$T/brf" WIFI_SH="$T/tplink_brcm.sh" DNSMASQ_CONF="$T/dnsmasq.conf" DNSMASQ_INIT="$T/bin/dnsmasq-init" NET="$T/net" RUN="$T/run" INITTAB="$T/inittab" SELF="$T/iot.sh" PATH="$T/bin:$PATH" \
      sh "$ROOT/iot.sh" "$@"
}

fail() { echo "FAIL: $1"; echo "--- calls"; cat "$T/calls"; exit 1; }
has() { grep -qF -- "$1" "$T/calls" || fail "expected call: $1"; }

run apply || true
has "brctl addbr br-iot"
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
has "iptables -A AX10_IOT_FWD -i br-iot -m state --state ESTABLISHED,RELATED -j ACCEPT"
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

# Second pass is a no-op: nothing moved, firewall not rebuilt.
: > "$T/calls"
run apply || true
grep -q "brctl\|-F AX10\|dnsmasq\|hostapd_cli" "$T/calls" && fail "second apply was not idempotent"

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

echo "iot.sh tests passed"
