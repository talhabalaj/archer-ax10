# ==== src/61-load.sh: router load watcher
# ------------------------------------------------------------- router load
# Is the router itself keeping up? Each watcher pass (about every 15 s) records, since
# the pass before: how busy the processor was (all 3 cores together), how much of it
# was network processing (softirq: forwarding, the speed limit, Wi-Fi), the load
# average, and what went over the internet connection:
#   $RUN/load.log    "<uptime s> <busy %> <softirq %> <load avg> <down kbit/s> <up kbit/s>",
#                    the last 24 hours (read by the dashboard)
#   $RUN/load.prev   the counters at the last pass
# The speed limit and device caps take traffic off the hardware fast path, so a busy
# processor is where a slow router shows first. When it stays at LOAD_FULL % or more
# for about a minute, the log says so once, with what was moving and the busiest
# processes. Processes go by name only: command lines can hold secrets (the PPPoE
# login is in pppd's).
LOAD_FULL="${LOAD_FULL:-90}"
PROC="${PROC:-/proc}"
load_top() {     # the busiest processes over one second: "name 35%, name 12%"
    snap() { cat "$PROC"/[0-9]*/stat 2>/dev/null | awk '{ o = index($0, "("); c = index($0, ") "); if (!o || !c) next
        n = substr($0, o + 1, c - o - 1); split(substr($0, c + 2), f, " "); gsub(/[^A-Za-z0-9._\/-]/, "_", n); print $1, n, f[12] + f[13] }'; }
    snap > "$RUN/load.top1"; sleep 1; snap > "$RUN/load.top2"
    awk 'NR == FNR { t[$1] = $3; next } ($1 in t) && $3 - t[$1] >= 2 { printf "%d %s\n", $3 - t[$1], $2 }' "$RUN/load.top1" "$RUN/load.top2" |
        sort -rn | head -n 4 | awk '{ printf "%s%s %d%%", (NR > 1 ? ", " : ""), $2, $1 }'
    rm -f "$RUN/load.top1" "$RUN/load.top2"
}
load_guard() {
    mkdir -p "$RUN"
    set -- $(head -n 1 "$PROC/stat" 2>/dev/null)     # cpu user nice system idle iowait irq softirq steal
    [ "$1" = cpu ] && [ -n "$8" ] || return 0
    tot=$(( $2 + $3 + $4 + $5 + $6 + $7 + $8 + ${9:-0} )); idle=$(( $5 + $6 )); sirq=$8
    up="$(cut -d' ' -f1 "$PROC/uptime" 2>/dev/null)"; up="${up%%.*}"
    la="$(cut -d' ' -f1 "$PROC/loadavg" 2>/dev/null)"
    wd="$(usage_wan)"; rx=0; tx=0
    if [ -n "$wd" ] && [ -r "$NET/$wd/statistics/rx_bytes" ]; then
        rx="$(cat "$NET/$wd/statistics/rx_bytes")"; tx="$(cat "$NET/$wd/statistics/tx_bytes")"
    fi
    prev="$(cat "$RUN/load.prev" 2>/dev/null)"
    echo "$up $tot $idle $sirq $rx $tx" > "$RUN/load.prev"
    set -- $prev
    [ "$#" = 6 ] || return 0
    dt=$(( up - $1 )); dtot=$(( tot - $2 ))
    [ "$dt" -gt 0 ] && [ "$dt" -lt 600 ] && [ "$dtot" -gt 0 ] || return 0
    busy=$(( (dtot - (idle - $3)) * 100 / dtot )); sq=$(( (sirq - $4) * 100 / dtot ))
    [ "$busy" -ge 0 ] || busy=0; [ "$busy" -le 100 ] || busy=100; [ "$sq" -ge 0 ] || sq=0
    # a reconnect restarts the connection's counters: no reading for this pass
    dn=0; un=0; [ "$rx" -ge "$5" ] && dn=$(( (rx - $5) * 8 / 1000 / dt )); [ "$tx" -ge "$6" ] && un=$(( (tx - $6) * 8 / 1000 / dt ))
    echo "$up $busy $sq ${la:-0} $dn $un" >> "$RUN/load.log"
    [ "$(wc -c < "$RUN/load.log")" -gt 200000 ] && { tail -n 5760 "$RUN/load.log" > "$RUN/load.log.new"; mv "$RUN/load.log.new" "$RUN/load.log"; }
    # Nearly full for about a minute (4 passes): say so once, until it has eased off.
    n="$(cat "$RUN/load.full" 2>/dev/null)"; n="${n:-0}"
    if [ "$busy" -ge "$LOAD_FULL" ]; then
        n=$((n + 1))
        if [ "$n" = 4 ]; then
            log "router processor ${busy}% busy for about a minute (network ${sq}%, load $la) while moving $((dn / 1000))/$((un / 1000)) Mbps; busiest: $(load_top)"
        fi
    elif [ "$busy" -lt $((LOAD_FULL - 20)) ]; then n=0
    elif [ "$n" -lt 4 ]; then n=0; fi
    echo "$n" > "$RUN/load.full"
}
