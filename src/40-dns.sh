# ==== src/40-dns.sh: local names, DNS over HTTPS
# ------------------------------------------------------------- local names
# Names for the router and the devices under a private suffix (iot_dns_domain,
# default "home"), served by the router's own dnsmasq, the way Pi-hole does it:
#   router.home         the router (iot_dns_router, several names allowed)
#   <hostname>.home     every device, by the name it gave DHCP (dnsmasq does this
#                       itself once it has a domain)
#   <dashboard name>.home, and custom records (iot_dns_hosts "name=ip ...")
# For any of it to resolve, devices must ask the router: DHCP hands out the router
# as DNS server (the stock setting dhcp.lan.dhcp_option, also shown in TP-Link's
# DHCP page), and the IPv6 DNS servers TP-Link advertises over DHCPv6 are withdrawn
# (a device would ask those first and never see a local name). The router forwards
# everything else to iot_dns_upstream. Not ".local": that suffix belongs to mDNS and
# Apple devices never ask a DNS server for it.
DHCP6S_CONF="${DHCP6S_CONF:-/etc/dhcp6s.conf}"
DHCP6S_INIT="${DHCP6S_INIT:-/etc/init.d/dhcp6s}"
NL='
'
dns_load() {
    DNS_ON="$(cfg dns_on 0)"
    # Whatever is saved, dnsmasq only ever gets a clean suffix and IPv4 upstream
    # servers: a line it can't parse stops it, and with it DNS for the whole house.
    DNS_DOMAIN="$(dns_label "$(cfg dns_domain home)")"
    case "$DNS_DOMAIN" in ''|local) DNS_DOMAIN=home ;; esac
    DNS_ROUTER="$(cfg dns_router router)"
    DNS_HOSTS="$(cfg dns_hosts '')"
    DNS_UP=""; for u in $(cfg dns_upstream '1.1.1.1 1.0.0.1'); do
        valid_ip4 "$u" && DNS_UP="$DNS_UP $u"
    done; DNS_UP="$(echo $DNS_UP)"
    LAN_IP="$($UCI -q get network.lan.ipaddr)"; LAN_IP="${LAN_IP:-192.168.0.1}"
}
# A name as a DNS label: lower case, letters digits and dashes.
# (Line breaks go first: sed and cut work line by line and would pass them through.)
dns_label() { printf '%s' "$1" | tr -d '\n\r' | tr 'A-Z _.' 'a-z---' | sed 's/[^a-z0-9-]//g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-63; }
valid_ip4() {   # four numbers 0-255, nothing else
    case "$1" in *[!0-9.]*|'') return 1 ;; esac
    echo "$1" | awk -F. 'NF != 4 { exit 1 } { for (i = 1; i <= 4; i++) if ($i == "" || $i > 255) exit 1 }'
}
dns_hosts() {   # the hosts file: router names, custom records, dashboard names of devices with a lease
    for n in $DNS_ROUTER; do l="$(dns_label "$n")"; [ -n "$l" ] && echo "$LAN_IP $l.$DNS_DOMAIN"; done
    for e in $DNS_HOSTS; do
        l="$(dns_label "${e%%=*}")"; ip="${e#*=}"
        valid_ip4 "$ip" && [ -n "$l" ] && echo "$ip $l.$DNS_DOMAIN"
    done
    [ -f "$LEASES" ] || return 0
    $UCI -q -d "$NL" get "$SEC.iot_names" 2>/dev/null | while IFS= read -r e; do
        mac="$(echo "${e%%=*}" | tr 'A-F-' 'a-f:')"; l="$(dns_label "${e#*=}")"; [ -n "$l" ] || continue
        ip="$(awk -v m="$mac" 'tolower($2)==m {print $3; exit}' "$LEASES")"
        valid_ip4 "$ip" && echo "$ip $l.$DNS_DOMAIN"
    done
}
dns_block() {   # dnsmasq lines, inside our block in dnsmasq.conf
    [ "$DNS_ON" = 1 ] || return 0
    echo "domain=$DNS_DOMAIN"
    echo "local=/$DNS_DOMAIN/"
    echo "addn-hosts=$RUN/hosts"
    if [ -e "$RUN/doh.ok" ]; then echo "no-resolv"; echo "server=127.0.0.1#$DOH_PORT"
    elif [ -n "$DNS_UP" ]; then echo "no-resolv"; for u in $DNS_UP; do echo "server=$u"; done; fi
}
# DNS over HTTPS (iot_dns_doh=1, needs local names on): the router's upstream lookups
# go through iot-ui/doh.lua, a small forwarder on 127.0.0.1:$DOH_PORT that sends them
# encrypted to one provider, with the server's certificate and name verified. While
# the forwarder answers, dnsmasq uses only it; while it doesn't (no internet yet, the
# clock not set at boot so certificates look invalid, provider down), dnsmasq falls
# back to the plain servers, so the house never loses DNS because of this.
DOH_PORT="${DOH_PORT:-5053}"
doh_provider() {   # "<ip> <name>" of the chosen provider
    case "$(cfg dns_doh_provider cloudflare)" in
        google) echo "8.8.8.8 dns.google" ;;
        quad9)  echo "9.9.9.9 dns.quad9.net" ;;
        *)      echo "1.1.1.1 cloudflare-dns.com" ;;
    esac
}
doh_running() { pid_live "$RUN/doh.pid" doh.lua; }
doh_stop() {
    # Its TLS connections (openssl children) end by themselves when it does: they
    # run with -no_ign_eof and their input is a pipe from it.
    pid_kill "$RUN/doh.pid" doh.lua
    rm -f "$RUN/doh.ok" "$RUN/doh.sig" "$RUN/doh.stat"
}
doh_sync() {
    if [ "$DNS_ON" != 1 ] || [ "$(cfg dns_doh 0)" != 1 ] || [ ! -f "$UI_SRC/doh.lua" ] || [ ! -f "$UI_SRC/cacert.pem" ]; then
        [ -e "$RUN/doh.pid" ] && { doh_stop; log "DNS over HTTPS off"; }
        return 0
    fi
    set -- $(doh_provider)
    if ! doh_running || [ "$1 $2" != "$(cat "$RUN/doh.sig" 2>/dev/null)" ]; then
        doh_stop
        $LUA "$UI_SRC/doh.lua" "$DOH_PORT" "$1" "$2" "$UI_SRC/cacert.pem" "$RUN/doh.stat" >/dev/null 2>&1 &
        pid_save "$RUN/doh.pid" $!; echo "$1 $2" > "$RUN/doh.sig"
        sleep "${DOH_WARMUP:-2}"
    fi
    if $LUA "$UI_SRC/doh.lua" check "$DOH_PORT" >/dev/null 2>&1; then
        [ -e "$RUN/doh.ok" ] || { : > "$RUN/doh.ok"; log "DNS over HTTPS working ($2)"; }
    elif [ -e "$RUN/doh.ok" ]; then
        rm -f "$RUN/doh.ok"; log "DNS over HTTPS not answering; using the plain DNS servers until it does"
    fi
}
dns_sync() {
    dns_load; mkdir -p "$RUN"
    doh_sync
    # Which DNS server DHCP hands out: the router while this is on; the upstream
    # servers again when it is switched off (only if it still points at the router).
    cur="$($UCI -q get dhcp.lan.dhcp_option)"; six=""; rest=""
    for o in $cur; do case "$o" in 6,*) six="$o" ;; *) rest="$rest $o" ;; esac; done
    # What was there before is kept in iot_dns_prev6 ("none" if no DNS option was
    # set) and put back on switching off, if the setting still points at the router.
    want="$six"; prev="$(cfg dns_prev6 '')"
    if [ "$DNS_ON" = 1 ]; then
        want="6,$LAN_IP"
        if [ "$six" != "$want" ]; then $UCI set "$SEC.iot_dns_prev6=${six:-none}" && commit_cfg >/dev/null; fi
    elif [ "$six" = "6,$LAN_IP" ] && [ -n "$prev" ]; then
        case "$prev" in none) want="" ;; 6,*) want="$prev" ;; esac
    fi
    if [ "$want" != "$six" ]; then
        $UCI set "dhcp.lan.dhcp_option=$(echo $rest $want)" && commit_cfg dhcp >/dev/null
        [ "$DNS_ON" = 1 ] || { $UCI set "$SEC.iot_dns_prev6=" && commit_cfg >/dev/null; }
        dnsmasq_restart
        log "DHCP now hands out ${want:+${want#6,} as }${want:-no particular} DNS server"
    fi
    # IPv6: withdraw the DNS servers handed out over DHCPv6 while this is on.
    if [ -f "$DHCP6S_CONF" ]; then
        if [ "$DNS_ON" = 1 ] && grep -q '^option domain-name-servers' "$DHCP6S_CONF"; then
            grep -v '^option domain-name-servers' "$DHCP6S_CONF" > "$RUN/dhcp6s.new"; cat "$RUN/dhcp6s.new" > "$DHCP6S_CONF"; rm -f "$RUN/dhcp6s.new"
            : > "$RUN/dhcp6s.stripped"
            p6="$(cat /var/run/dhcp6s.pid 2>/dev/null)"
            if [ -n "$p6" ] && kill "$p6" 2>/dev/null; then sleep 1; /usr/sbin/dhcp6s -c "$DHCP6S_CONF" -P /var/run/dhcp6s.pid "$LANBR" >/dev/null 2>&1; fi
            log "IPv6 DNS servers no longer advertised: devices ask the router"
        elif [ "$DNS_ON" != 1 ] && [ -e "$RUN/dhcp6s.stripped" ]; then
            rm -f "$RUN/dhcp6s.stripped"
            [ -x "$DHCP6S_INIT" ] && "$DHCP6S_INIT" restart >/dev/null 2>&1
            log "IPv6 DNS servers advertised again"
        fi
    fi
    # TP-Link's "dnsproxy" does not proxy: its nat chain prerouting_rule_dns sends
    # every query addressed to the router on to the ISP's DNS server, so dnsmasq never
    # sees one from the LAN and no local name could resolve. An ACCEPT at the top of
    # that chain ends NAT for those packets, and they reach dnsmasq. (TP-Link rebuilds
    # the chain when the internet connection changes; checked every run.)
    for pr in udp tcp; do
        if [ "$DNS_ON" = 1 ]; then
            $IPT -t nat -C prerouting_rule_dns -i "$LANBR" -d "$LAN_IP" -p $pr --dport 53 -j ACCEPT 2>/dev/null ||
                { $IPT -t nat -I prerouting_rule_dns 1 -i "$LANBR" -d "$LAN_IP" -p $pr --dport 53 -j ACCEPT 2>/dev/null && dnsfix=1; }
        else
            while $IPT -t nat -D prerouting_rule_dns -i "$LANBR" -d "$LAN_IP" -p $pr --dport 53 -j ACCEPT 2>/dev/null; do dnsfix=1; done
        fi
    done
    if [ -n "$dnsfix" ]; then
        dnsfix=""; command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
        [ "$DNS_ON" = 1 ] && log "DNS queries from the home network now reach the router's own DNS"
    fi
    # The hosts file; dnsmasq re-reads it on SIGHUP.
    if [ "$DNS_ON" = 1 ]; then
        dns_hosts | sort -u > "$RUN/hosts.new"
        if cmp -s "$RUN/hosts.new" "$RUN/hosts" 2>/dev/null; then rm -f "$RUN/hosts.new"
        else mv "$RUN/hosts.new" "$RUN/hosts"; ${DNSMASQ_HUP:-killall -HUP dnsmasq} 2>/dev/null; fi
    fi
}
dhcp_block() {
    echo "$MARK_BEGIN"
    if iot_on; then
        echo "dhcp-range=set:iot,$START,$END,255.255.255.0,12h"
        echo "dhcp-option=tag:iot,3,$GW"
        echo "dhcp-option=tag:iot,6,$(echo $DNS | tr ' ' ',')"
        for s in $STATIC; do echo "dhcp-host=${s%%,*},${s#*,}"; done
    fi
    dns_block
    echo "$MARK_END"
}
# Local names and DNS over HTTPS without the IoT network: the same two steps apply() does.
names_sync() { load; dns_sync; dhcp_sync; }
dhcp_strip() { sed "/^$MARK_BEGIN\$/,/^$MARK_END\$/d" "$DNSMASQ_CONF"; }
dnsmasq_restart() {
    if [ -x "$DNSMASQ_INIT" ]; then "$DNSMASQ_INIT" restart >/dev/null 2>&1
    else
        killall dnsmasq 2>/dev/null; sleep 1
        /usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf
    fi
}
# Make the block match the current settings; restart dnsmasq only if it changed.
# dnsmasq checks the result first (--test): a line it can't read would stop it, and
# with it DHCP and DNS for the whole house, so such a block is never left in place.
DNSMASQ_BIN="${DNSMASQ_BIN:-/usr/sbin/dnsmasq}"
DNSMASQ_MAIN="${DNSMASQ_MAIN:-/var/etc/dnsmasq.conf}"
dnsmasq_ok() { [ -x "$DNSMASQ_BIN" ] || return 0; "$DNSMASQ_BIN" --test -C "$DNSMASQ_MAIN" >/dev/null 2>&1; }
dhcp_sync() {
    want="$(dhcp_block)"
    have="$(sed -n "/^$MARK_BEGIN\$/,/^$MARK_END\$/p" "$DNSMASQ_CONF" 2>/dev/null)"
    [ "$want" = "$have" ] && return 0
    # Nothing to say: no block at all. Not there: leave the file alone. There: take it out.
    if [ "$want" = "$MARK_BEGIN$NL$MARK_END" ]; then
        [ -z "$have" ] && return 0
        dhcp_remove; log "dnsmasq settings removed"; return 0
    fi
    [ "$want" = "$(cat "$RUN/dnsmasq.bad" 2>/dev/null)" ] && return 0     # already refused, said so once
    cat "$DNSMASQ_CONF" > "$RUN/dnsmasq.conf.old" 2>/dev/null
    { dhcp_strip; echo "$want"; } > "$RUN/dnsmasq.conf.new" && cat "$RUN/dnsmasq.conf.new" > "$DNSMASQ_CONF"
    rm -f "$RUN/dnsmasq.conf.new"
    if ! dnsmasq_ok; then
        cat "$RUN/dnsmasq.conf.old" > "$DNSMASQ_CONF"; rm -f "$RUN/dnsmasq.conf.old"
        echo "$want" > "$RUN/dnsmasq.bad"
        log "dnsmasq refused the new settings; kept the old ones (check the local-names and IoT address settings)"
        return 1
    fi
    rm -f "$RUN/dnsmasq.conf.old" "$RUN/dnsmasq.bad"
    dnsmasq_restart && log "dnsmasq settings updated$(iot_on && echo " (IoT addresses $START-$END)")"
}
dhcp_remove() {
    grep -q "^$MARK_BEGIN\$" "$DNSMASQ_CONF" 2>/dev/null || return 0
    dhcp_strip > "$RUN/dnsmasq.conf.new" && cat "$RUN/dnsmasq.conf.new" > "$DNSMASQ_CONF"
    rm -f "$RUN/dnsmasq.conf.new"; dnsmasq_restart
}
