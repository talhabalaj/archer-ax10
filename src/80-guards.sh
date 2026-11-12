# ==== src/80-guards.sh: SSH lifeline and IPv6 client guards
# Keep boot.sh's SSH lifeline alive: if it is gone, start it again the same way
# boot.sh does, and log it (the log tells us what killed it).
LIFELINE_BIN="${LIFELINE_BIN:-/tmp/dropbear_vanilla}"
LIFELINE_PID="${LIFELINE_PID:-/tmp/archer-boot-ssh-2222.pid}"
# TP-Link's WAN IPv6 client (dhcp6c) can abort as the PPPoE link comes up at boot
# (seen 2026-11-12: a core dump one minute after boot, before any of our code ran).
# Nothing restarts it, and the router is left without an IPv6 default route or a
# prefix for the LAN until the next reconnect: IPv6 is simply dead in the house.
# If its config is in place (TP-Link removes it when the link goes down) and it is
# not running on two checks in a row, start it the way /lib/netifd/pppshare-up does.
DHCP6C_DIR="${DHCP6C_DIR:-/tmp/dhcp6c}"
DHCP6C_BIN="${DHCP6C_BIN:-/usr/sbin/dhcp6c}"
PIDOF="${PIDOF:-pidof}"
# TP-Link starts the client itself whenever the link comes up, so this must never add
# a second one next to it:
#   - the config must be the same file on both checks (TP-Link rewrites it on every
#     connect, so a changed one means a connect is in progress: start over);
#   - it is looked for again right before starting, and again two seconds after: if
#     TP-Link's own has appeared in the meantime, ours is the one that goes;
#   - after a restart that did not hold, the next try waits longer each time (2, 4,
#     8 ... 64 minutes), so a client that keeps crashing is not restarted in a loop.
d6_state() {   # D6_TRIES (0..6) and D6_UNTIL from $RUN/dhcp6c.tries; anything else in there is thrown away
    D6_TRIES=0; D6_UNTIL=0
    [ -f "$RUN/dhcp6c.tries" ] || return 0
    read -r D6_TRIES D6_UNTIL _rest < "$RUN/dhcp6c.tries"
    case "$D6_TRIES" in ''|*[!0-9]*) D6_TRIES=bad ;; esac
    case "$D6_UNTIL" in ''|*[!0-9]*) D6_TRIES=bad ;; esac
    if [ "$D6_TRIES" = bad ] || [ "${#D6_TRIES}" -gt 2 ] || [ "${#D6_UNTIL}" -gt 12 ]; then D6_TRIES=0; D6_UNTIL=0; rm -f "$RUN/dhcp6c.tries"; return 0; fi
    [ "$D6_TRIES" -le 6 ] || D6_TRIES=6
}
ipv6_guard() {
    c="$DHCP6C_DIR/dhcp6c.conf"
    if [ ! -f "$c" ] || [ ! -x "$DHCP6C_BIN" ]; then rm -f "$RUN/dhcp6c.miss"; return 0; fi
    if $PIDOF dhcp6c >/dev/null 2>&1; then
        rm -f "$RUN/dhcp6c.miss"
        # running for a while since our last restart: that one held
        d6_state; [ "$D6_TRIES" -gt 0 ] && [ "$(now_s)" -ge "$D6_UNTIL" ] && rm -f "$RUN/dhcp6c.tries"
        return 0
    fi
    id="$(ls -li "$c" 2>/dev/null | awk '{print $1, $6, $7, $8, $9}') $(cksum < "$c" 2>/dev/null)"
    if [ "$(cat "$RUN/dhcp6c.miss" 2>/dev/null)" != "$id" ]; then echo "$id" > "$RUN/dhcp6c.miss"; return 0; fi   # first miss with this config
    d6_state
    [ "$(now_s)" -ge "$D6_UNTIL" ] || return 0                               # still backing off
    rm -f "$RUN/dhcp6c.miss"
    [ "$($UCI -q get network.wan.type)" = bridge ] && return 0              # IPTV bridge mode uses another port; leave it
    ifn="$(sed -n 's/^interface \([^ ]*\) {.*/\1/p' "$c" | head -n1)"
    wif="$($UCI -q get network.wan.ifname)"
    [ -n "$ifn" ] && [ -n "$wif" ] && [ -d "$NET/$ifn" ] || return 0
    $PIDOF dhcp6c >/dev/null 2>&1 && return 0                               # it has just been started for us
    [ -f "$c" ] || return 0
    "$DHCP6C_BIN" -f -p "$DHCP6C_DIR/dhcp6c.pid" -c "$c" -I "$wif" -t internet "$ifn" >/dev/null 2>&1 &
    ours=$!; ours_start="$(lock_start "$ours")"
    tries=$((D6_TRIES + 1)); [ "$tries" -le 6 ] || tries=6
    echo "$tries $(( $(now_s) + 60 * (1 << tries) ))" > "$RUN/dhcp6c.tries"
    sleep "${DHCP6C_SETTLE:-2}"
    if [ "$($PIDOF dhcp6c 2>/dev/null | wc -w)" -gt 1 ]; then
        # only if that pid is still the process we started
        [ "$(lock_start "$ours")" = "$ours_start" ] && kill "$ours" 2>/dev/null
        log "the router started its own IPv6 client while ours was starting; left it to that one"
    else
        log "the router's IPv6 client (dhcp6c) was not running; restarted it (try $tries)"
    fi
}
lifeline_guard() {
    [ -x "$LIFELINE_BIN" ] || return 0
    p="$(cat "$LIFELINE_PID" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
    lan="$($UCI -q get network.lan.ipaddr)"; [ -n "$lan" ] || return 0
    k=""; [ -s /tmp/archer-boot-host.key ] && k="-r /tmp/archer-boot-host.key"
    "$LIFELINE_BIN" -p "$lan:2222" -P "$LIFELINE_PID" $k -R -E </dev/null >/dev/null 2>&1 &
    log "SSH lifeline was not running; restarted it"
}
