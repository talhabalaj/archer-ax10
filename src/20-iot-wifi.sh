# ==== src/20-iot-wifi.sh: IoT network: the Wi-Fi slot
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
# Is TP-Link's hostapd running the IoT slot? Until it is, the slot is left exactly as
# TP-Link made it. At boot the copy in flash starts before TP-Link's own Wi-Fi setup;
# a slot we had already moved and reconfigured made hostapd fail on it ("Could not set
# interface wl1.4 hwaddr"), and that failure took down the whole 2.4 GHz hostapd: the
# guest Wi-Fi off the air, the 2.4 GHz home Wi-Fi refusing new devices, and the IoT
# slot broadcasting without encryption. Seen on the router.
wifi_ready() { $HAPD_CLI -i "$VIF" ping 2>/dev/null | grep -q PONG; }
# A slot on the air without encryption while hostapd isn't running it: off the air.
# Only when seen twice in a row, so hostapd's own start (up a moment before its keys)
# is never caught.
vif_open_guard() {
    if [ "$($WL -i "$VIF" bss 2>/dev/null)" = up ] && [ "$($WL -i "$VIF" wsec 2>/dev/null)" = 0 ]; then
        if [ -e "$RUN/vif.open" ]; then
            $WL -i "$VIF" bss down; rm -f "$RUN/vif.open" "$RUN/vif.sig"
            log "$VIF was on the air without encryption and hostapd wasn't running it; took it off the air"
        else : > "$RUN/vif.open"; fi
    else rm -f "$RUN/vif.open"; fi
}
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
