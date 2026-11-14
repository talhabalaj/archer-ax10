# ==== src/65-alerts.sh: alerts over MQTT (for Home Assistant)
# With iot_mqtt_host set, each watcher pass looks for:
#   - the internet connection going down, and coming back (with how long it was gone)
#   - a device this router hasn't seen before joining the home, guest or IoT network
#   - the home allow list dropping or kicking out an unlisted device
#   - a mesh satellite going offline, and coming back
#   - the router having started (once per boot)
# and sends each as an event on ax10/event (JSON: event_type, message, details) to that
# MQTT broker. Home Assistant finds them through MQTT discovery, as the device "Archer
# AX10": an event entity (Alert), two connectivity sensors (Internet, Mesh satellite;
# ax10/internet, ax10/satellite) and the time it last started (ax10/boot).
# The broker is usually on the home network, so an internet outage is reported while
# it lasts. Messages wait in a queue in RAM while the broker can't be reached (at most
# MQ_MAX; tried again every minute), so a broker restart loses nothing.
#   ax10.sh set mqtt_host 192.168.0.5; ax10.sh set mqtt_port 1883
#   ax10.sh set mqtt_user ax10; ax10.sh set mqtt_pass <password>   (if the broker wants a login)
#   ax10.sh alert-test   sends a test event now
MQ_Q="$RUN/alerts.q"                # events waiting to be sent
MQ_RET="$RUN/alerts.ret"            # retained messages (discovery, sensor states): the latest per topic
MQ_MAX=100
MQ_VER=1                           # bump when the discovery messages change
PING="${PING:-ping}"
BOOT_GRACE="${BOOT_GRACE:-600}"    # "router started" only within this long after boot
alerts_on() { [ -n "$(cfg mqtt_host '')" ]; }
# A value made safe to put inside a JSON string: no quotes, backslashes or control
# characters (device names are chosen by their owners), and at most N bytes (default
# 60), cut between characters, never inside one: a UTF-8 character the cut leaves
# incomplete (its lead byte promises more bytes than are left) is dropped whole.
# (All in awk: BusyBox 1.19's tr gets octal ranges wrong and lets control characters through.)
mq_clean() {
    LC_ALL=C awk -v n="${1:-60}" 'BEGIN { RS = "\001" } { s = $0; gsub(/["\\\001-\037]/, "", s)
        if (length(s) > n) {
            s = substr(s, 1, n); i = n
            while (i > 0) { c = substr(s, i, 1); if (c < "\200" || c >= "\300") break; i-- }
            if (i > 0 && c >= "\300") {
                need = (c >= "\360") ? 4 : ((c >= "\340") ? 3 : 2)
                if (n - i + 1 < need) s = substr(s, 1, i - 1)
            }
        }
        printf "%s", s; exit }'
}
# mq_put <retain 0|1> <topic> <payload>. An event joins the queue (the newest MQ_MAX are
# kept). A retained message replaces that topic's line in MQ_RET, and if it changed,
# all of MQ_RET is sent with the next flush (MQ_RET.dirty): a burst of events can't
# push a sensor's state out, and whatever the broker missed is sent again whole.
mq_put() {
    mkdir -p "$RUN"
    if [ "$1" = 1 ]; then
        mq_line="$(printf '%s\t%s' "$2" "$3")"
        has_line "$MQ_RET" "$mq_line" && return 0
        { [ -f "$MQ_RET" ] && awk -F '\t' -v t="$2" '$1 != t' "$MQ_RET"; printf '%s\n' "$mq_line"; } > "$MQ_RET.t"
        mv "$MQ_RET.t" "$MQ_RET"; : > "$MQ_RET.dirty"
        return 0
    fi
    printf '0\t%s\t%s\n' "$2" "$3" >> "$MQ_Q"
    [ "$(wc -l < "$MQ_Q")" -gt "$MQ_MAX" ] && { tail -n "$MQ_MAX" "$MQ_Q" > "$MQ_Q.t"; mv "$MQ_Q.t" "$MQ_Q"; }
    return 0
}
mq_waiting() { [ -s "$MQ_Q" ] || [ -f "$MQ_RET.dirty" ]; }
# alert <event type> <message> [extra JSON fields]: queue an event (when alerts are on).
alert() {
    alerts_on || return 0
    al_t="$(epoch)"
    mq_put 0 ax10/event "{\"event_type\":\"$1\",\"message\":\"$(printf '%s' "$2" | mq_clean 200)\"${3:+,$3}${al_t:+,\"time\":$al_t}}"
    log "alert: $2"
}
dur() {   # dur <seconds>: "2 h 5 min", "12 min", "40 s"
    if [ "$1" -ge 3600 ]; then echo "$(($1 / 3600)) h $(($1 % 3600 / 60)) min"
    elif [ "$1" -ge 60 ]; then echo "$(($1 / 60)) min"; else echo "$1 s"; fi
}

# ---------------------------------------------------------- Home Assistant discovery
MQ_DEV='"device":{"identifiers":["ax10_router"],"name":"Archer AX10","manufacturer":"TP-Link","model":"Archer AX10"}'
MQ_EVENTS='"internet_down","internet_up","new_device","blocked_device","satellite_offline","satellite_online","router_started","test"'
mq_discovery() {
    mq_put 1 homeassistant/event/ax10/alert/config "{\"name\":\"Alert\",\"unique_id\":\"ax10_alert\",\"state_topic\":\"ax10/event\",\"event_types\":[$MQ_EVENTS],$MQ_DEV}"
    mq_put 1 homeassistant/binary_sensor/ax10/internet/config "{\"name\":\"Internet\",\"unique_id\":\"ax10_internet\",\"device_class\":\"connectivity\",\"state_topic\":\"ax10/internet\",$MQ_DEV}"
    mq_put 1 homeassistant/binary_sensor/ax10/satellite/config "{\"name\":\"Mesh satellite\",\"unique_id\":\"ax10_satellite\",\"device_class\":\"connectivity\",\"state_topic\":\"ax10/satellite\",$MQ_DEV}"
    mq_put 1 homeassistant/sensor/ax10/last_boot/config "{\"name\":\"Last start\",\"unique_id\":\"ax10_last_boot\",\"device_class\":\"timestamp\",\"state_topic\":\"ax10/boot\",$MQ_DEV}"
}
# Sent again whenever the broker or the messages change, and every 6 hours (retained,
# so Home Assistant has them even if it starts later; again in case the broker lost them).
alerts_discovery() {
    sig="$MQ_VER|$(cfg mqtt_host '')|$(cfg mqtt_port 1883)"; t="$(now_s)"
    o_sig=""; o_t=0; [ -f "$RUN/alerts.disc" ] && read -r o_sig o_t < "$RUN/alerts.disc"
    [ "$o_sig" = "$sig" ] && [ $((t - ${o_t:-0})) -lt 21600 ] && return 0
    # Everything retained goes again (states too): a new broker has none of it.
    mq_discovery; : > "$RUN/alerts.ret.dirty"; echo "$sig $t" > "$RUN/alerts.disc"
}

# ---------------------------------------------------------------- the router started
alerts_boot() {
    if [ ! -f "$RUN/alerts.boot" ]; then
        : > "$RUN/alerts.boot"
        up="$(now_s)"
        # Only right after a boot: alerts switched on later, or a new version taking
        # over, is not a restart.
        [ "$up" -lt "$BOOT_GRACE" ] 2>/dev/null && alert router_started "Router started" "\"uptime\":$up"
    fi
    # Its start time, once the clock is set (NTP comes a little after boot).
    if [ ! -f "$RUN/alerts.bootts" ]; then
        e="$(epoch)"; [ -n "$e" ] || return 0
        ts="$(date -u -d "@$((e - $(now_s)))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
        [ -n "$ts" ] && mq_put 1 ax10/boot "$ts"
        : > "$RUN/alerts.bootts"
    fi
}

# ------------------------------------------------------------------------- internet
inet_now() {   # 1 if the internet connection works now, else 0
    $UBUS call network.interface.internet status 2>/dev/null | grep -q '"up": true' || { echo 0; return; }
    if $PING -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || $PING -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then echo 1; else echo 0; fi
}
# State in $RUN/alerts.inet: "<1|0> <since, seconds after boot> <misses in a row>".
# Down takes two misses in a row (a single lost ping is not an outage); up, one answer.
alerts_inet() {
    t="$(now_s)"; s=""; since="$t"; miss=0
    [ -f "$RUN/alerts.inet" ] && read -r s since miss < "$RUN/alerts.inet"
    if [ "$(inet_now)" = 1 ]; then miss=0; new=1
    else miss=$((${miss:-0} + 1)); if [ "$miss" -ge 2 ]; then new=0; else new="${s:-1}"; fi
    fi
    if [ "$new" != "$s" ]; then
        if [ "$new" = 0 ] && [ -n "$s" ]; then alert internet_down "Internet connection down"
        elif [ "$new" = 1 ] && [ "$s" = 0 ]; then
            alert internet_up "Internet connection back after $(dur $((t - since)))" "\"down_seconds\":$((t - since))"
        fi
        since="$t"
        if [ "$new" = 1 ]; then mq_put 1 ax10/internet ON; else mq_put 1 ax10/internet OFF; fi
    fi
    echo "$new $since $miss" > "$RUN/alerts.inet"
}

# --------------------------------------------------------------------- mesh satellites
# "<mac> <1 connected|0> <model>" for each satellite in TP-Link's EasyMesh list (its
# "device" objects only; see mesh_macs).
mesh_states() {
    [ -f "$MESH_LIST" ] || return 0
    awk 'BEGIN { RS = "\001" }
    function field(d, k,   v) {
        if (!match(d, "\"" k "\"[ \t\r\n]*:[ \t\r\n]*\"[^\"]*\"")) return ""
        v = substr(d, RSTART, RLENGTH); sub(/^"[^"]*"[ \t\r\n]*:[ \t\r\n]*"/, "", v); sub(/"$/, "", v); return v
    }
    { s = $0
      while (match(s, /"device"[ \t\r\n]*:[ \t\r\n]*\{[^{}]*\}/)) {
          d = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          m = tolower(field(d, "mac")); gsub(/-/, ":", m)
          if (m !~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])$/) continue
          n = field(d, "product_name"); gsub(/[^A-Za-z0-9 ._-]/, "", n); gsub(/ /, "_", n)
          print m, (field(d, "status") == "CONNECTED" ? 1 : 0), (n == "" ? "satellite" : n)
      } }' "$MESH_LIST"
}
# Known satellites in $RUN/alerts.mesh ("<mac> <1|0> <model> <misses>"). Offline takes
# two looks in a row without it connected (missing from the list counts: TP-Link
# rewrites the file, and one empty or half-written read is not an outage); back, one
# look. The first look only learns, and a satellite first seen in the boot grace time
# is just noted (it is joining after a boot).
alerts_mesh() {
    f="$RUN/alerts.mesh"; up="$(now_s)"
    if [ ! -f "$f" ]; then mesh_states | awk 'NF >= 3 { print $1, $2, $3, 0 }' > "$f"; mesh_sensor; return 0; fi
    { awk '{ print "K", $0 }' "$f"; mesh_states | awk 'NF >= 3 { print "C", $0 }'; } |
    awk -v up="$up" -v grace="$BOOT_GRACE" '
        $1 == "K" { k[$2] = 1; st[$2] = $3; nm[$2] = $4; miss[$2] = $5 + 0; next }
        $1 == "C" { c[$2] = $3; cn[$2] = $4 }
        END {
            for (m in c) if (!(m in k)) {
                k[m] = 1; st[m] = c[m]; nm[m] = cn[m]; miss[m] = 0
                if (c[m] == 1 && up + 0 >= grace + 0) print "E satellite_online connected", m, nm[m]
            } else if (c[m] == 1) { if (st[m] == 0) print "E satellite_online back", m, nm[m]; st[m] = 1; miss[m] = 0 }
            for (m in k) if (!(m in c) || c[m] != 1) {
                if (m in c) nm[m] = cn[m]
                miss[m]++
                if (miss[m] >= 2) { if (st[m] == 1) print "E satellite_offline offline", m, nm[m]; st[m] = 0 }
            }
            for (m in k) print "S", m, st[m], nm[m], miss[m]
        }' > "$f.out"
    grep '^S ' "$f.out" | cut -c3- | sort > "$f"
    grep '^E ' "$f.out" | while read -r _ type how m nm; do
        alert "$type" "Mesh satellite $how: $nm ($m)" "\"mac\":\"$m\""
    done
    rm -f "$f.out"
    mesh_sensor
}
# Connectivity sensor: on while every known satellite is connected (none known: none sent).
mesh_sensor() {
    ms="$(awk '$2 == 1 { on++ } END { if (NR) print (on == NR ? "ON" : "OFF") }' "$RUN/alerts.mesh" 2>/dev/null)"
    [ -n "$ms" ] && mq_put 1 ax10/satellite "$ms"
    return 0
}

# ---------------------------------------------------------------------- new devices
# "<mac> <home|guest|iot> <ip or -> <name>" for each device connected now: TP-Link's
# client list, and IoT devices by their lease (TP-Link doesn't see that network).
dev_current() {
    p="$(cfg ip 192.168.50.1)"; p="${p%.*}."
    [ -f "$CLIENTS" ] && tr '{' '\n' < "$CLIENTS" | grep '"connect_status":1' | awk -v p="$p" '
        function field(k,   v) {
            if (!match($0, "\"" k "\":\"[^\"]*\"")) return ""
            v = substr($0, RSTART, RLENGTH); sub(/^"[^"]*":"/, "", v); sub(/"$/, "", v); return v
        }
        { m = tolower(field("mac")); gsub(/-/, ":", m); if (m !~ /^[0-9a-f:]+$/ || length(m) != 17) next
          ip = field("ip"); nm = field("name"); if (nm == "") nm = field("hostname")
          net = (index(ip, p) == 1) ? "iot" : (field("guest") == "GUEST" ? "guest" : "home")
          print m, net, (ip == "" ? "-" : ip), nm }'
    awk -v p="$p" 'index($3, p) == 1 { m = tolower($2); print m, "iot", $3, ($4 == "*" ? "" : $4) }' "$LEASES" 2>/dev/null
}
# Every MAC this router already knows: TP-Link's client list (offline ones too), the
# leases, our settings, the neighbour table. What the "new device" check starts from.
dev_history() {
    { [ -f "$CLIENTS" ] && tr '{' '\n' < "$CLIENTS" | sed -n 's/.*"mac":"\([0-9A-Fa-f-]*\)".*/\1/p'
      awk '{ print $2 }' "$LEASES" 2>/dev/null
      for k in static home_allow home_keep home_seen hidden_devices caps noinet guest_fast lan_allow lan_open; do
          for e in $(cfg "$k" ''); do echo "${e%%[=,]*}"; done
      done
      $UCI -q -d "$NL" get "$SEC.iot_names" 2>/dev/null | sed 's/=.*//'
      awk 'NR > 1 { print $4 }' "$ARP" 2>/dev/null
    } | tr 'A-F-' 'a-f:' | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | sort -u
}
alerts_devices() {
    k="$RUN/alerts.known"
    cur="$(dev_current | sort -u -k1,1)"
    if [ ! -f "$k" ]; then { dev_history; echo "$cur" | awk 'NF { print $1 }'; } | sort -u > "$k"; return 0; fi
    echo "$cur" | while read -r m net ip nm; do
        [ -n "$m" ] || continue
        has_line "$k" "$m" && continue
        echo "$m" >> "$k"
        nm="$(printf '%s' "$nm" | mq_clean)"; [ "$ip" = - ] && ip=""
        case "$net" in iot) w="IoT network" ;; guest) w="guest Wi-Fi" ;; *) w="home network" ;; esac
        alert new_device "New device on the $w: ${nm:-unnamed} (${ip:+$ip, }$m)" \
            "\"mac\":\"$m\",\"network\":\"$net\"${ip:+,\"ip\":\"$ip\"}${nm:+,\"name\":\"$nm\"}"
    done
}
# A device the home allow list drops or kicks off (once per device per boot).
alert_blocked() {   # alert_blocked <mac> <how>
    alerts_on || return 0
    has_line "$RUN/alerts.blocked" "$1" && return 0
    echo "$1" >> "$RUN/alerts.blocked"
    ab_n="$(dev_current | awk -v m="$1" '$1 == m { $1 = $2 = $3 = ""; sub(/^ +/, ""); print; exit }' | mq_clean)"
    alert blocked_device "Unlisted device $2: ${ab_n:-unnamed} ($1)" "\"mac\":\"$1\"${ab_n:+,\"name\":\"$ab_n\"}"
}

# ------------------------------------------------------------------------- sending
alerts_flush() {
    mq_waiting || return 0
    t="$(now_s)"; last="$(cat "$RUN/alerts.fail" 2>/dev/null)"
    [ -n "$1" ] || { [ -n "$last" ] && [ $((t - last)) -lt 60 ] && [ "$t" -ge "$last" ] && return 0; }
    # Retained messages first when any changed or went unsent (discovery before the
    # states it describes), then events.
    ret=""; [ -f "$MQ_RET.dirty" ] && ret=1
    rm -f "$MQ_RET.dirty"; mv "$MQ_Q" "$MQ_Q.out" 2>/dev/null || : > "$MQ_Q.out"
    { [ -n "$ret" ] && awk '{ print "1\t" $0 }' "$MQ_RET" 2>/dev/null; cat "$MQ_Q.out"; } > "$MQ_Q.send"
    if MQTT_USER="$(cfg mqtt_user '')" MQTT_PASS="$(cfg mqtt_pass '')" \
        $LUA "$UI_SRC/helpers/mqtt.lua" "$(cfg mqtt_host '')" "$(cfg mqtt_port 1883)" ax10-router "$MQ_Q.send" 2> "$RUN/alerts.err"; then
        rm -f "$MQ_Q.out" "$MQ_Q.send" "$RUN/alerts.err"
        [ -f "$RUN/alerts.fail" ] && log "alerts: MQTT broker reachable again"
        rm -f "$RUN/alerts.fail"
    else
        # Events back in front of any queued meanwhile, oldest first, the newest MQ_MAX
        # kept; the retained ones all go again next time.
        { cat "$MQ_Q.out"; cat "$MQ_Q" 2>/dev/null; } | tail -n "$MQ_MAX" > "$MQ_Q.t"; mv "$MQ_Q.t" "$MQ_Q"
        [ -s "$MQ_Q" ] || rm -f "$MQ_Q"
        rm -f "$MQ_Q.out" "$MQ_Q.send"; [ -n "$ret" ] && : > "$MQ_RET.dirty"
        [ -f "$RUN/alerts.fail" ] || log "alerts: can't send to the MQTT broker: $(head -c 200 "$RUN/alerts.err" 2>/dev/null)"
        echo "$t" > "$RUN/alerts.fail"
    fi
}
alerts_sync() {
    if ! alerts_on; then
        rm -f "$MQ_Q" "$MQ_Q.out" "$MQ_Q.send" "$MQ_RET" "$MQ_RET.dirty" "$RUN/alerts.disc" "$RUN/alerts.known" \
              "$RUN/alerts.inet" "$RUN/alerts.mesh" "$RUN/alerts.blocked" "$RUN/alerts.fail" "$RUN/alerts.err" "$RUN/alerts.bootts"
        return 0
    fi
    mkdir -p "$RUN"
    alerts_discovery
    alerts_boot
    alerts_inet
    alerts_mesh
    alerts_devices
    alerts_flush
}
