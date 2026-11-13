# ==== src/22-iot-firewall.sh: IoT network: firewall
# ------------------------------------------------------------------ firewall
# IPv6 on the IoT network: off. Everything below is IPv4, and the IoT subnet is
# IPv4-only by design, so IPv6 must not be a way around it. disable_ipv6 makes
# the kernel ignore IPv6 arriving on the bridge (to the router or forwarded);
# the ip6tables chain is a second layer in case something re-enables it.
v6_off() {
    f="$SYS6/$BR/disable_ipv6"
    [ -f "$f" ] || return 0
    [ "$(cat "$f" 2>/dev/null)" = 1 ] && return 0
    echo 1 > "$f" 2>/dev/null && log "IPv6 disabled on $BR"
}
V6_HOOKS="INPUT:-i FORWARD:-i FORWARD:-o"      # chain:direction for the jumps
v6_firewall() {
    $IPT6 -N $CH_IOT6 2>/dev/null; $IPT6 -F $CH_IOT6
    $IPT6 -A $CH_IOT6 -j DROP
    for h in $V6_HOOKS; do
        $IPT6 -C "${h%%:*}" "${h#*:}" $BR -j $CH_IOT6 2>/dev/null ||
            $IPT6 -I "${h%%:*}" 1 "${h#*:}" $BR -j $CH_IOT6
    done
}
v6_firewall_ok() {
    # No working ip6tables on this box: nothing to check (v6_off still applies).
    $IPT6 -L INPUT -n >/dev/null 2>&1 || return 0
    $IPT6 -C $CH_IOT6 -j DROP 2>/dev/null || return 1
    for h in $V6_HOOKS; do
        $IPT6 -C "${h%%:*}" "${h#*:}" $BR -j $CH_IOT6 2>/dev/null || return 1
    done
}
v6_firewall_remove() {
    for h in $V6_HOOKS; do
        while $IPT6 -D "${h%%:*}" "${h#*:}" $BR -j $CH_IOT6 2>/dev/null; do :; done
    done
    $IPT6 -F $CH_IOT6 2>/dev/null; $IPT6 -X $CH_IOT6 2>/dev/null
}

# Bump when the rules built by firewall() change, so a running router rebuilds.
FW_VER=3
# Our chains exactly as iptables lists them, in order. firewall() saves
# this after a rebuild and firewall_ok() compares, so a missing, extra or
# reordered rule triggers a rebuild. If this iptables has no -S, both sides
# are empty and the -C checks below still apply.
# One IoT -> home rule: what [@from] [>to], written by the dashboard's IoT tab.
#   what: "tcp:port", "tcp:first-last" (or udp), or "any" for every port and protocol
#   from: the IoT address it applies to (none: every IoT device)
#   to:   the home address it may reach (none: every home device)
# e.g. tcp:8123@192.168.50.137>192.168.0.20. Sets AR_P (tcp, udp, or empty for any),
# AR_D (the port, or first:last as iptables takes a range), AR_S and AR_T (the
# addresses, or empty).
allow_rule() {
    w="$1"; AR_S=""; AR_T=""; AR_P=""; AR_D=""
    case "$w" in *">"*) AR_T="${w#*>}"; w="${w%%>*}"; valid_ip4 "$AR_T" || return 1 ;; esac
    r="${w%%@*}"
    if [ "$r" != "$w" ]; then AR_S="${w#*@}"; valid_ip4 "$AR_S" || return 1; fi
    [ "$r" = any ] && return 0
    AR_P="${r%%:*}"; AR_D="$(echo "${r#*:}" | tr - :)"
    case "$AR_P" in tcp|udp) ;; *) return 1 ;; esac
    case "$AR_D" in ''|*[!0-9:]*|*:*:*|:*|*:) return 1 ;; esac
    for n in $(echo "$AR_D" | tr : ' '); do [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le 65535 ] || return 1; done
    case "$AR_D" in *:*) [ "${AR_D%:*}" -le "${AR_D#*:}" ] || return 1 ;; esac
}
fw_dump() { $IPT -S $CH_FWD 2>/dev/null; $IPT -S $CH_IN 2>/dev/null; $IPT -t nat -S $CH_NAT 2>/dev/null; $IPT6 -S $CH_IOT6 2>/dev/null; }
firewall() {
    # filter: chains are flushed and refilled, jumps added once.
    $IPT -N $CH_FWD 2>/dev/null; $IPT -F $CH_FWD
    # Home -> IoT: every home device, or only allowlisted MACs (mode "selected").
    if [ "$LAN_MODE" = selected ]; then
        for m in $LAN_ALLOW; do $IPT -A $CH_FWD -i br-lan -o $BR -m mac --mac-source "$m" -j ACCEPT; done
    else
        $IPT -A $CH_FWD -i br-lan -o $BR -j ACCEPT
    fi
    $IPT -A $CH_FWD -o $BR -m state --state ESTABLISHED,RELATED -j ACCEPT
    $IPT -A $CH_FWD -o $BR -j DROP
    # Replies from IoT to home devices only. Internet-bound packets, even of an
    # open connection, must reach the no-inet drops below, so that switching a
    # device's Internet off also cuts what it already has open.
    $IPT -A $CH_FWD -i $BR -o br+ -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Narrow IoT -> LAN exceptions (see allow_rule), e.g. tcp:8899@192.168.50.10 for
    # the inverter-link logger callback. One that doesn't parse is skipped, never
    # passed to iptables half-understood.
    for a in $ALLOW_LAN; do
        allow_rule "$a" || { log "IoT -> home rule skipped, not tcp|udp:port[-port] or any, [@ip] [>ip]: $a"; continue; }
        $IPT -A $CH_FWD -i $BR -o br-lan ${AR_S:+-s "$AR_S"} ${AR_T:+-d "$AR_T"} ${AR_P:+-p "$AR_P" --dport "$AR_D"} -j ACCEPT
    done
    # IoT devices switched to "can reach home devices": any port, any home device (by
    # MAC, so it holds without a fixed address). Still not the router (CH_IN).
    for m in $LAN_OPEN; do $IPT -A $CH_FWD -i $BR -o br-lan -m mac --mac-source "$m" -j ACCEPT; done
    $IPT -A $CH_FWD -i $BR -o br+ -j DROP
    for m in $NOINET; do $IPT -A $CH_FWD -i $BR -m mac --mac-source "$m" -j DROP; done
    $IPT -A $CH_FWD -i $BR -j ACCEPT
    for d in "-i $BR" "-o $BR"; do
        $IPT -C FORWARD $d -j $CH_FWD 2>/dev/null || $IPT -I FORWARD 1 $d -j $CH_FWD
    done

    $IPT -N $CH_IN 2>/dev/null; $IPT -F $CH_IN
    $IPT -A $CH_IN -m state --state ESTABLISHED,RELATED -j ACCEPT
    $IPT -A $CH_IN -p udp --dport 67 -j ACCEPT
    $IPT -A $CH_IN -p udp --dport 53 -j ACCEPT
    $IPT -A $CH_IN -p tcp --dport 53 -j ACCEPT
    $IPT -A $CH_IN -p icmp -j ACCEPT
    # mDNS from the devices whose speakers home devices see (24-iot-mdns.sh).
    for a in $(mdns_ips); do
        if [ "$a" = all ]; then $IPT -A $CH_IN -p udp --dport 5353 -j ACCEPT
        else $IPT -A $CH_IN -s "$a" -p udp --dport 5353 -j ACCEPT; fi
    done
    $IPT -A $CH_IN -j DROP
    $IPT -C INPUT -i $BR -j $CH_IN 2>/dev/null || $IPT -I INPUT 1 -i $BR -j $CH_IN

    # nat: masquerade IoT traffic leaving through any non-bridge (WAN, ppp0, ...).
    $IPT -t nat -N $CH_NAT 2>/dev/null; $IPT -t nat -F $CH_NAT
    $IPT -t nat -A $CH_NAT -s "$PREFIX.0/24" ! -o br+ -j MASQUERADE
    $IPT -t nat -C POSTROUTING -j $CH_NAT 2>/dev/null || $IPT -t nat -I POSTROUTING 1 -j $CH_NAT

    v6_firewall

    # Broadcom flow cache can keep forwarding already-accelerated flows.
    command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
    echo "$FW_VER|$NOINET|$ALLOW_LAN|$LAN_MODE|$LAN_ALLOW|$LAN_OPEN|$MDNS" > "$RUN/fw.sig"
    fw_dump > "$RUN/fw.snap"
}
firewall_ok() {
    [ "$(cat "$RUN/fw.sig" 2>/dev/null)" = "$FW_VER|$NOINET|$ALLOW_LAN|$LAN_MODE|$LAN_ALLOW|$LAN_OPEN|$MDNS" ] &&
    $IPT -C FORWARD -i $BR -j $CH_FWD 2>/dev/null &&
    $IPT -C FORWARD -o $BR -j $CH_FWD 2>/dev/null &&
    $IPT -C $CH_FWD -i $BR -j ACCEPT 2>/dev/null &&
    $IPT -C INPUT -i $BR -j $CH_IN 2>/dev/null &&
    $IPT -C $CH_IN -j DROP 2>/dev/null &&
    $IPT -t nat -C POSTROUTING -j $CH_NAT 2>/dev/null &&
    $IPT -t nat -C $CH_NAT -s "$PREFIX.0/24" ! -o br+ -j MASQUERADE 2>/dev/null &&
    v6_firewall_ok &&
    [ "$(fw_dump)" = "$(cat "$RUN/fw.snap" 2>/dev/null)" ]
}
firewall_remove() {
    for d in "-i $BR" "-o $BR"; do while $IPT -D FORWARD $d -j $CH_FWD 2>/dev/null; do :; done; done
    while $IPT -D INPUT -i $BR -j $CH_IN 2>/dev/null; do :; done
    while $IPT -t nat -D POSTROUTING -j $CH_NAT 2>/dev/null; do :; done
    $IPT -F $CH_FWD 2>/dev/null; $IPT -X $CH_FWD 2>/dev/null
    $IPT -F $CH_IN 2>/dev/null; $IPT -X $CH_IN 2>/dev/null
    $IPT -t nat -F $CH_NAT 2>/dev/null; $IPT -t nat -X $CH_NAT 2>/dev/null
    v6_firewall_remove
    rm -f "$RUN/fw.sig" "$RUN/fw.snap"
}
