# ==== src/23-iot-network.sh: IoT network: apply and tear down
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
