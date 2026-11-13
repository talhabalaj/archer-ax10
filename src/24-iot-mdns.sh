# ==== src/24-iot-mdns.sh: IoT speakers (AirPlay, Spotify Connect) seen from home
# Phones find AirPlay and Spotify Connect speakers by mDNS, which stays inside one
# network, so a speaker on the IoT Wi-Fi is invisible to them. With iot_mdns set to
# "all" (every IoT device) or to IoT addresses (e.g. "192.168.50.137"),
# helpers/mdns.lua repeats those devices' answers about the services in
# iot_mdns_services into the home network, and home devices' questions about them
# into the IoT network. Nothing else crosses: no other service of any device.
# Reaching the speaker afterwards is the usual rules: home -> IoT (every home device,
# or the selected ones), and for AirPlay 2 the IoT -> home exception for its timing
# (udp:319-320@<device> in iot_allow_lan).
MDNS_SVC_DEFAULT="_airplay._tcp _raop._tcp _spotify-connect._tcp"
mdns_ips() {     # "all", or the listed IoT addresses that are valid and on the IoT network
    for a in $(cfg mdns ''); do [ "$a" = all ] && { echo all; return; }; done
    for a in $(cfg mdns ''); do valid_ip4 "$a" && case "$a" in "$PREFIX".*) echo "$a" ;; esac; done
}
mdns_services() {   # _name._tcp / _name._udp, nothing else
    for v in $(cfg mdns_services "$MDNS_SVC_DEFAULT"); do
        case "$v" in *[!A-Za-z0-9._-]*) continue ;; _?*._tcp|_?*._udp) echo "$v" ;; esac
    done
}
mdns_running() { pid_live "$RUN/mdns.pid" mdns.lua; }
mdns_stop() { pid_kill "$RUN/mdns.pid" mdns.lua; rm -f "$RUN/mdns.sig" "$RUN/mdns.stat"; }
mdns_sync() {
    m_ips="$(echo $(mdns_ips))"; m_svc="$(echo $(mdns_services))"
    if [ -z "$m_ips" ] || [ -z "$m_svc" ] || [ ! -f "$UI_SRC/helpers/mdns.lua" ]; then
        [ -e "$RUN/mdns.pid" ] && { mdns_stop; log "speaker discovery from the IoT network off"; }
        return 0
    fi
    m_lan="$($UCI -q get network.lan.ipaddr)"; m_lan="${m_lan:-192.168.0.1}"
    m_sig="$GW $m_lan|$m_ips|$m_svc|$(md5sum < "$UI_SRC/helpers/mdns.lua" | cut -c1-12)"   # a new release restarts it
    if ! mdns_running || [ "$m_sig" != "$(cat "$RUN/mdns.sig" 2>/dev/null)" ]; then
        was=""; [ -e "$RUN/mdns.pid" ] && was=1
        mdns_stop
        $LUA "$UI_SRC/helpers/mdns.lua" "$GW" "$m_lan" "$m_ips" "$m_svc" "$RUN/mdns.stat" >/dev/null 2>&1 &
        pid_save "$RUN/mdns.pid" $!; echo "$m_sig" > "$RUN/mdns.sig"
        log "speaker discovery ${was:+re}started: home devices see $m_svc of $m_ips"
    fi
}
