# ==== src/30-home.sh: home allow list, TP-Link Access Control compatibility
# ------------------------------------------------------------- home allow list
# Our own allow list for the home network (TP-Link's Access Control stays off; its
# guest exemption needs a firewall match this kernel lacks). Two layers:
#   - the home Wi-Fi radios (iot_home_ifs, default wl0.1 wl1.1) take only listed
#     MACs (wl macmode 2), and unlisted devices already on them are disconnected;
#   - devices the radios can't see (behind the mesh satellite, or wired) are dropped
#     in the raw table by MAC once TP-Link's client list shows them as home clients.
#     Only listed-as-client MACs are dropped, so guests on the same bridge and the
#     satellite's own radios are never caught.
# `ax10.sh home-open [s]` lets new devices in for a while; they are added as they show
# up. Last-seen times are kept in RAM and saved to flash once a day; with
# iot_home_expire=N, entries not seen for N days are removed (iot_home_keep never).
CH_HOME=AX10_HOME
home_load() {
    H_LOCK="$(cfg home_lock 0)"
    H_ALLOW="$(cfg home_allow '' | tr 'A-F-' 'a-f:')"
    H_KEEP="$(cfg home_keep '' | tr 'A-F-' 'a-f:')"
    H_EXPIRE="$(cfg home_expire 0)"
    H_IFS=""; for i in $(cfg home_ifs 'wl0.1 wl1.1'); do [ -d "$NET/$i" ] && H_IFS="$H_IFS $i"; done
}
home_listed() { case " $H_ALLOW $H_KEEP " in *" $1 "*) return 0 ;; esac; return 1; }
home_open_now() { u="$(cat "$RUN/home_open_until" 2>/dev/null)"; [ -n "$u" ] && [ "$(now_s)" -lt "$u" ] 2>/dev/null; }
home_clients() {   # home devices connected now: on our home radios, or TP-Link's client list (non-guest)
    for i in $H_IFS; do $WL -i "$i" assoclist 2>/dev/null | awk '{print tolower($2)}'; done
    [ -f "$CLIENTS" ] && tr '{' '\n' < "$CLIENTS" | grep '"guest":"NON_GUEST"' | grep '"connect_status":1' |
        sed -n 's/.*"mac":"\([0-9A-Fa-f-]*\)".*/\1/p' | tr 'A-F-' 'a-f:'
}
# Forget last-seen times, so a re-added device starts a fresh clock. Also in the saved
# copy (the caller commits), so a reboot can't bring the old time back.
sed_seen_del() {
    if [ -f "$RUN/home_seen" ]; then
        for m in "$@"; do grep -v "^$m " "$RUN/home_seen" > "$RUN/home_seen.new"; mv "$RUN/home_seen.new" "$RUN/home_seen"; done
    fi
    v=""; for e in $(cfg home_seen ''); do case " $* " in *" ${e%%=*} "*) ;; *) v="$v $e" ;; esac; done
    $UCI set "$SEC.iot_home_seen=$(echo $v)"
}
home_save_allow() { $UCI set "$SEC.iot_home_allow=$(echo $H_ALLOW)" && commit_cfg >/dev/null; }
epoch() { d="$(date +%s 2>/dev/null)"; [ "${d:-0}" -gt 1700000000 ] 2>/dev/null && echo "$d"; }   # empty until NTP has set the clock
home_seen_sync() {   # home_seen_sync <connected macs>
    now="$(epoch)"; [ -n "$now" ] || return 0
    f="$RUN/home_seen"
    [ -f "$f" ] || for e in $(cfg home_seen ''); do echo "${e%%=*} ${e#*=}"; done > "$f"
    { for m in $1; do echo "$m $now"; done
      for m in $H_ALLOW; do grep -q "^$m " "$f" || echo "$m $now"; done   # first sight starts the clock
      cat "$f"; } | sort -k1,1 -k2,2nr | awk '!s[$1]++' > "$f.new" && mv "$f.new" "$f"
    # Expire entries not seen for H_EXPIRE days.
    # Only while the lock is on: with it off the list is not in use, and a list
    # nobody is using must not shrink behind the owner's back.
    if [ "$H_LOCK" = 1 ] && [ "$H_EXPIRE" -gt 0 ] 2>/dev/null; then
        old=""; for m in $H_ALLOW; do
            case " $H_KEEP " in *" $m "*) continue ;; esac
            t="$(awk -v m="$m" '$1==m{print $2}' "$f")"
            [ -n "$t" ] && [ $((now - t)) -gt $((H_EXPIRE * 86400)) ] && old="$old $m"
        done
        new=""; for m in $H_ALLOW; do case " $old " in *" $m "*) ;; *) new="$new $m" ;; esac; done
        # Never expire the list down to nothing: that would leave the lock with no one on it.
        [ -z "$(echo $new $H_KEEP)" ] && old=""
        if [ -n "$old" ]; then
            H_ALLOW="$(echo $new)"; sed_seen_del $old; home_save_allow
            log "removed from the home allow list after $H_EXPIRE days unseen:$old"
        fi
    fi
    # Save to flash once a day.
    last="$(cat "$RUN/home_seen.saved" 2>/dev/null)"
    if [ $((now - ${last:-0})) -gt 86400 ]; then
        $UCI set "$SEC.iot_home_seen=$(awk '{printf "%s=%s ", $1, $2}' "$f" | sed 's/ $//')" && commit_cfg >/dev/null
        echo "$now" > "$RUN/home_seen.saved"
    fi
}
# Open the home radios again, but only the ones we locked (home_owned): a filter
# TP-Link or someone else set is left alone.
home_unlock() {
    for i in $(cat "$RUN/home_owned" 2>/dev/null); do
        [ "$($WL -i "$i" macmode 2>/dev/null)" = 2 ] && { $WL -i "$i" macmode 0; log "home Wi-Fi ($i) open to any device${1:+ ($1)}"; }
    done
    rm -f "$RUN/home_owned"
    home_fw_clear
}
home_fw_clear() {
    for t in "$IPT" "$IPT6"; do
        while $t -t raw -D PREROUTING -i "$LANBR" -j $CH_HOME 2>/dev/null; do :; done
        $t -t raw -F $CH_HOME 2>/dev/null; $t -t raw -X $CH_HOME 2>/dev/null
    done
}
home_sync() { home_sync_lists; portal_sync; }
home_sync_lists() {
    mkdir -p "$RUN"
    # The watcher's own list changes (last seen, expiry, un-hiding, enrollment), on
    # the lists as saved now (the caller holds the run lock, so nothing else writes).
    home_load
    conn="$(home_clients | sort -u | tr '\n' ' ')"
    gnow="$(guest_macs | sort -u | tr '\n' ' ')"
    home_seen_sync "$conn $gnow"
    unhide "$conn $gnow $(load 2>/dev/null; $WL -i "$VIF" assoclist 2>/dev/null | awk '{print tolower($2)}' | tr '\n' ' ')"
    if [ "$H_LOCK" = 1 ] && home_open_now; then
        new=""; for m in $conn; do home_listed "$m" || case " $gnow " in *" $m "*) ;; *) new="$new $m" ;; esac; done
        if [ -n "$new" ]; then H_ALLOW="$(echo $H_ALLOW $new)"; sed_seen_del $new; home_save_allow; log "added to the home allow list:$new"; fi
    fi
    [ "$H_LOCK" = 1 ] || { home_unlock; return 0; }
    if home_open_now; then home_unlock "window open"; return 0; fi
    # On with an empty list would lock out everyone, including whoever manages it.
    if [ -z "$(echo $H_ALLOW $H_KEEP)" ]; then home_unlock "the allow list is empty"; return 0; fi
    want="$(echo $H_ALLOW $H_KEEP | tr ' ' '\n' | tr a-f A-F | sort -u | tr '\n' ' ')"
    for i in $H_IFS; do
        have="$($WL -i "$i" mac 2>/dev/null | awk '{print toupper($2)}' | sort | tr '\n' ' ')"
        [ "$want" = "$have" ] || { $WL -i "$i" mac none 2>/dev/null; $WL -i "$i" mac $want; }
        [ "$($WL -i "$i" macmode 2>/dev/null)" = 2 ] || { $WL -i "$i" macmode 2; log "home Wi-Fi ($i) locked to $(echo $want | wc -w) device(s)"; }
        grep -qx "$i" "$RUN/home_owned" 2>/dev/null || echo "$i" >> "$RUN/home_owned"
        for m in $($WL -i "$i" assoclist 2>/dev/null | awk '{print toupper($2)}'); do
            case " $want " in *" $m "*) ;; *) $WL -i "$i" deauthenticate "$m" 2>/dev/null; log "removed unlisted device $m from the home Wi-Fi ($i)" ;; esac
        done
    done
    # Devices behind the satellite or wired: drop unlisted home clients by MAC.
    # A MAC stays dropped once seen (it vanishes from the client list when cut off),
    # until it is listed or shows up on the guest Wi-Fi: guests are never dropped.
    g=" $(guest_macs | sort -u | tr '\n' ' ') "
    drop="$(cat "$RUN/home_drop" 2>/dev/null)"
    for m in $conn; do drop="$drop $m"; done
    keep=""; for m in $drop; do
        home_listed "$m" && continue
        case "$g" in *" $m "*) continue ;; esac
        case " $keep " in *" $m "*) ;; *) keep="$keep $m" ;; esac
    done
    drop="$(echo $keep)"; echo "$drop" > "$RUN/home_drop"
    for t in "$IPT" "$IPT6"; do
        $t -t raw -N $CH_HOME 2>/dev/null
        $t -t raw -C PREROUTING -i "$LANBR" -j $CH_HOME 2>/dev/null || $t -t raw -I PREROUTING 1 -i "$LANBR" -j $CH_HOME
        w="$(echo $drop | tr ' ' '\n' | tr a-f A-F | sort | tr '\n' ' ')"
        h="$($t -t raw -S $CH_HOME 2>/dev/null | sed -n 's/.*--mac-source \([^ ]*\).*/\1/p' | tr a-f A-F | sort | tr '\n' ' ')"
        [ "$w" = "$h" ] && continue
        $t -t raw -F $CH_HOME
        for m in $drop; do $t -t raw -A $CH_HOME -m mac --mac-source "$m" -j DROP; done
        [ "$t" = "$IPT" ] && [ -n "$drop" ] && log "home network: dropping unlisted device(s) $drop"
        flush=1
    done
    # Accelerated (Broadcom flow cache) connections skip netfilter: drop them so the
    # new rules apply to connections already open.
    [ -n "$flush" ] && command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
    flush=""
}
# Change the list or settings under the run lock, so the watcher and the dashboard
# never write from stale copies. home_edit <add|remove|keep|unkeep> <mac>
home_edit() {
    mac="$(echo "$2" | tr A-F- a-f:)"
    echo "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || { echo "ax10.sh: bad MAC '$2'" >&2; return 1; }
    home_load; a=""; k=""
    for m in $H_ALLOW; do [ "$m" = "$mac" ] || a="$a $m"; done
    for m in $H_KEEP; do [ "$m" = "$mac" ] || k="$k $m"; done
    was_keep=0; case " $H_KEEP " in *" $mac "*) was_keep=1 ;; esac
    case "$1" in
        add) a="$a $mac"; [ "$was_keep" = 1 ] && k="$k $mac" ;;
        keep) a="$a $mac"; k="$k $mac" ;;
        unkeep) a="$a $mac" ;;
        remove) ;;
        *) echo "ax10.sh: home-allow add|remove|keep|unkeep <mac>" >&2; return 1 ;;
    esac
    if [ "$1" = remove ] && [ "$H_LOCK" = 1 ] && [ -z "$(echo $a $k)" ]; then
        echo "ax10.sh: that is the last device on the list; turn the lock off instead" >&2; return 1
    fi
    $UCI set "$SEC.iot_home_allow=$(echo $a)"; $UCI set "$SEC.iot_home_keep=$(echo $k)"
    case "$1" in add|keep|remove) sed_seen_del "$mac" ;; esac
    commit_cfg >/dev/null
    log "home allow list: $1 $mac"
}
home_set() {   # home_set <lock|expire> <value>
    home_load
    case "$1" in
        lock) case "$2" in 0|1) ;; *) return 1 ;; esac
              if [ "$2" = 1 ] && [ -z "$(echo $H_ALLOW $H_KEEP)" ]; then echo "ax10.sh: the allow list is empty" >&2; return 1; fi ;;
        expire) case "$2" in ''|*[!0-9]*) return 1 ;; esac ;;
        *) return 1 ;;
    esac
    $UCI set "$SEC.iot_home_$1=$2" && commit_cfg >/dev/null
    log "home allow list: $1 = $2"
}
# TP-Link's Access Control in allow-list mode is meant for the home Wi-Fi, but it
# catches guests twice:
#   - its Wi-Fi MAC filter goes on the guest interfaces too, so strangers can't join;
#   - its firewall chain (raw table, access_control) drops every MAC not on the list.
#     With guest_enable=off it means to let guests through with "-m physdev
#     --physdev-in <guest if>" rules, but this kernel has no physdev match, so those
#     rules fail silently and guests get no address and no internet.
# Keep the guest interfaces open, and accept each connected guest by MAC in our own
# chain at the top of TP-Link's (rebuilt on every firewall reload; checked every run).
# Block-list mode is left as TP-Link has it.
GUEST_AC=ax10_guest_ac
guest_wifi_open() {
    on=0
    [ "$($UCI -q get access_control.settings.enable)" = on ] &&
        [ "$($UCI -q get access_control.settings.access_mode)" = white ] && on=1
    if [ "$on" = 1 ]; then
        for i in $(guest_ifs); do
            [ "$($WL -i "$i" macmode 2>/dev/null)" = 0 ] && continue
            $WL -i "$i" macmode 0 && log "kept the guest Wi-Fi ($i) open: TP-Link's allow list is for the home Wi-Fi"
        done
    fi
    macs="$(guest_macs | sort -u | tr '\n' ' ')"
    for t in "$IPT" "$IPT6"; do
        $t -t raw -S access_control >/dev/null 2>&1 || continue      # Access Control off: no chain
        $t -t raw -N "$GUEST_AC" 2>/dev/null
        if [ "$on" != 1 ]; then
            $t -t raw -D access_control -j "$GUEST_AC" 2>/dev/null
            $t -t raw -F "$GUEST_AC"; continue
        fi
        $t -t raw -C access_control -j "$GUEST_AC" 2>/dev/null || $t -t raw -I access_control 1 -j "$GUEST_AC"
        want="$(echo $macs | tr ' ' '\n' | tr a-f A-F | sort | tr '\n' ' ')"
        have="$($t -t raw -S "$GUEST_AC" 2>/dev/null | sed -n 's/.*--mac-source \([^ ]*\).*/\1/p' | tr a-f A-F | sort | tr '\n' ' ')"
        [ "$want" = "$have" ] && continue
        $t -t raw -F "$GUEST_AC"
        for m in $macs; do $t -t raw -A "$GUEST_AC" -m mac --mac-source "$m" -j ACCEPT; done
    done
}
