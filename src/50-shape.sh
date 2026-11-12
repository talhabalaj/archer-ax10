# ==== src/50-shape.sh: speed limits, automatic speed
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
# controller does not have to load all of ax10.sh once a second.
rate_script() {   # rate_script <prio 0|1> <low 0|1>
    cat > "$RUN/rate.sh.new" <<EOF
#!/bin/sh
# Written by ax10.sh shape_sync. rate.sh <down kbit> <up kbit>
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
