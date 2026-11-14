# ==== src/85-status.sh: status report
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
    echo "iot->home any port: ${LAN_OPEN:-none}"
    if mdns_running; then echo "speakers seen from home: $(echo $(mdns_ips)) ($(tr '\n' ' ' < "$RUN/mdns.stat" 2>/dev/null))"; else echo "speakers seen from home: ${MDNS:+not running }${MDNS:-none}"; fi
    if [ -n "$EXTRA_LOADED" ]; then echo "extras:    loaded (speakers, usage, load, alerts)"
    else echo "extras:    not loaded$([ -f "$EXTRA" ] && echo ": extra.sh is from another release" || echo ": waiting for the downloaded files")"; fi
    if alerts_on; then echo "alerts:    MQTT $(cfg mqtt_host ''):$(cfg mqtt_port 1883)$([ -n "$(cfg mqtt_user '')" ] && echo " as $(cfg mqtt_user '')"), $(mq_waiting && echo "$( [ -s "$MQ_Q" ] && wc -l < "$MQ_Q" || echo 0) event(s) waiting ($(head -c 120 "$RUN/alerts.err" 2>/dev/null))" || echo "nothing waiting")"
    else echo "alerts:    off"; fi
    echo "home->iot: $LAN_MODE$([ "$LAN_MODE" = selected ] && echo " (${LAN_ALLOW:-nobody})")"
    firewall_ok && echo "firewall:  ok" || echo "firewall:  MISSING/outdated"
    grep -q "^$MARK_BEGIN\$" "$DNSMASQ_CONF" 2>/dev/null && echo "dhcp:      dnsmasq block present" || echo "dhcp:      MISSING"
    grep -q "$TAG" "$INITTAB" 2>/dev/null && echo "watcher:   registered" || echo "watcher:   not registered"
    mounted "$LUCI_CTL" && echo "dashboard: installed" || echo "dashboard: not installed"
    echo "--- IoT leases"; grep " $PREFIX\." "$LEASES" 2>/dev/null | awk '{print $2, $3, $4}'
    [ -f "$LOG" ] && { echo "--- last log lines"; tail -n 8 "$LOG"; }
}
