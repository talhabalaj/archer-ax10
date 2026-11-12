# ==== src/99-main.sh: commands
# Every command that can change the router or the saved settings runs holding the run
# lock: it runs itself again through with_lock (src/10-lock.sh), unless it holds it
# already. `status` only reads. `kick` leaves its note before it waits (see kick_run).
# The watcher holds a lock of its own for as long as it runs, so only one runs; a
# second one waits 15 s before it exits, so init does not start it again in a tight loop.
case "$1" in
    status|"") ;;
    watch) holds "$RUN/watch.lock" || { AX10_BUSY_SLEEP="${WATCH_BUSY_SLEEP:-15}"; export AX10_BUSY_SLEEP; with_lock "$RUN/watch.lock" 0 "$@"; } ;;
    kick) holds "$RUNLOCK" || { mkdir -p "$RUN"; : > "$RUN/sync.want"; with_lock "$RUNLOCK" "${LOCK_WAIT}" "$@"; } ;;
    *) holds "$RUNLOCK" || with_lock "$RUNLOCK" "${LOCK_WAIT}" "$@" ;;
esac

case "$1" in
    apply) mkdir -p "$RUN"; rm -f "$RUN/iot.stopped"; apply ;;   # asked for by hand: a manual stop no longer holds
    watch)   # the watcher: a pass every INTERVAL seconds, each in its own process holding the run lock
        unset AX10_BUSY_SLEEP
        while :; do
            sh "$0" pass >/dev/null 2>&1
            sleep "${INTERVAL:-15}"
        done ;;
    pass)
        rm -f "$RUN/sync.want"          # this pass applies whatever was asked for up to now
        run_all
        lifeline_guard
        ipv6_guard
        load_guard
        trim_log ;;
    start)
        self_install; watcher_stop_wait
        rm -f "$RUN/iot.stopped"
        run_all; inittab_add; watcher_restart >/dev/null; log "watcher registered" ;;
    stop)
        # Taken down by hand while the setting still says "on": stay down (see iot_on).
        mkdir -p "$RUN"; [ "$(cfg enabled 0)" = 1 ] && : > "$RUN/iot.stopped"
        stop
        shape_sync          # speed limits stay; this clears them only if none are set
        # The home allow list is not part of the IoT network: keep it (and a watcher) running.
        if [ "$(cfg home_lock 0)" = 1 ]; then home_sync
        else home_load; home_unlock; portal_clear; rm -f "$RUN/portal_macs"; fi
        # Local names and DNS over HTTPS are not part of the IoT network either.
        if [ "$(cfg dns_on 0)" = 1 ]; then names_sync; else doh_stop; fi
        watcher_sync ;;
    open|close)
        load; mkdir -p "$RUN"
        if [ "$1" = open ]; then
            s="${2:-600}"; case "$s" in ''|*[!0-9]*) s=600 ;; esac
            echo $(( $(now_s) + s )) > "$RUN/open_until"
            log "new IoT devices allowed for ${s}s"
        else rm -f "$RUN/open_until"; fi
        # "later": the caller asks for the sync itself (the dashboard: it records the
        # window before it answers, so two clicks can't end up in the wrong order).
        case " $2 $3 " in *" later "*) ;; *) : > "$RUN/sync.want"; kick_run ;; esac ;;
    home-open|home-close)
        mkdir -p "$RUN"
        if [ "$1" = home-open ]; then
            s="${2:-600}"; case "$s" in ''|*[!0-9]*) s=600 ;; esac
            echo $(( $(now_s) + s )) > "$RUN/home_open_until"; log "new home devices allowed for ${s}s"
        else rm -f "$RUN/home_open_until"; fi
        case " $2 $3 " in *" later "*) ;; *) : > "$RUN/sync.want"; kick_run ;; esac ;;
    home-allow) home_edit "$2" "$3" || exit 1 ;;
    forget-device) forget_devices "$2" || exit 1 ;;
    entry) entry_set "$2" "$3" "$4" || exit 1 ;;
    sync) run_all; watcher_sync ;;
    kick)   # kick [up]: apply what is saved, soon (see kick_run). "up": the IoT network was switched on in the settings.
        [ "$2" = up ] && rm -f "$RUN/iot.stopped"
        kick_run ;;
    forget)   # forget <mac>: drop an IoT device's fixed address; autopin won't re-pin it
        load; mac="$(echo "$2" | tr A-F- a-f:)"
        echo "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || { echo "ax10.sh: bad MAC '$2'" >&2; exit 1; }
        st=""; for e in $STATIC; do [ "$(echo "${e%%,*}" | tr A-F a-f)" = "$mac" ] || st="$st $e"; done
        fg="$(cfg forget '' | tr A-F a-f)"; case " $fg " in *" $mac "*) ;; *) fg="$fg $mac" ;; esac
        $UCI set "$SEC.iot_static=$(echo $st)"; $UCI set "$SEC.iot_forget=$(echo $fg)"
        commit_cfg >/dev/null; log "forgot IoT device $mac" ;;
    home-set) home_set "$2" "$3" || exit 1 ;;   # `sync` (run lock) registers or drops the watcher
    home)
        home_sync
        echo "home lock: $([ "$H_LOCK" = 1 ] && { home_open_now && echo "on, open to new devices" || echo on; } || echo off)"
        echo "radios:    $H_IFS"
        echo "allowed:   $H_ALLOW"
        echo "always:    ${H_KEEP:-none}"
        echo "dropped:   $(cat "$RUN/home_drop" 2>/dev/null)"
        echo "join page: $(cat "$RUN/portal_macs" 2>/dev/null)$(portal_running && echo " (server up)")"
        echo "expire:    $([ "$H_EXPIRE" -gt 0 ] 2>/dev/null && echo "$H_EXPIRE days" || echo off)" ;;
    guest|shape)
        shape_sync; watcher_sync; shape_load
        echo "whole connection: $([ "$WS_ON" = 1 ] && echo "${WS_DOWN}/${WS_UP} Mbps$([ "$WS_AUTO" = 1 ] && echo ", automatic: $(cat "$RUN/autorate.stat" 2>/dev/null)")" || echo off)"
        echo "priority lane: $([ "$PRIO" = 1 ] && { [ "$WS_ON" = 1 ] && echo on || echo "on, but needs the whole-connection cap"; } || echo off)"
        echo "guests last: $([ "$GLOW" = 1 ] && { [ "$WS_ON" = 1 ] && echo on || echo "on, but needs the whole-connection cap"; } || echo off)"
        echo "guest limit: $GL_ON  ${GL_DOWN}/${GL_UP} Mbps  full-speed: ${GL_FAST:-none}"
        echo "capped (mac down up):"; shape_list | sort -u ;;
    ui) self_install; watcher_stop_wait; ui_install; watcher_sync ;;
    ui-remove) ui_remove ;;
    boot)
        # Take over from whatever watcher runs now (the saved copy's, or an older
        # version's that doesn't use this lock) before touching anything. The new file
        # goes in place first: init restarts a stopped watcher at once, from $SELF.
        self_install
        watcher_stop_wait
        # Downloaded by boot.sh: keep it as the copy in flash for the next boot.
        [ -n "$SAVE_COPY_SIG" ] && save_copy "$SELF" "$SAVE_COPY_SIG"
        # SAVED_COPY=1: the boot hook started the copy of ax10.sh saved in flash (see
        # src/75-saved-copy.sh), before anything is downloaded. Everything ax10.sh does
        # by itself runs: the IoT network, the home allow list, speed limits, local
        # names. The web UI waits for the release (its files come from it), and so do
        # DNS over HTTPS and the automatic speed limit, whose scripts are part of the
        # web UI; until then DNS goes to the plain servers and the limit stays at the
        # usual speeds. Once the release downloads, boot.sh runs this again in full.
        if [ "$SAVED_COPY" = 1 ]; then log "started from the copy of ax10.sh saved in flash; the web UI follows once the release downloads"
        else ui_install; fi
        # In-process, not "$0 start": the fetched file is not executable.
        run_all; watcher_sync
        lifeline_guard ;;
    status) status ;;
    guard) mkdir -p "$RUN"; lifeline_guard; ipv6_guard ;;   # what the watcher checks besides the rules
    load)    # a load reading now (two, 2 s apart, on a first run), then the last few
        load_guard; [ -f "$RUN/load.log" ] || { sleep 2; load_guard; }
        echo "uptime   busy  network  load   down kbit/s  up kbit/s"
        tail -n "${2:-8}" "$RUN/load.log" 2>/dev/null | awk '{ printf "%-8s %3d%%  %5d%%  %5s  %11d  %9d\n", $1, $2, $3, $4, $5, $6 }' ;;
    usage)   # count up to now, then show the log: days, months, devices this month
        usage_sync
        awk '{ printf "%-34s %9.2f GB down %9.2f GB up\n", $1, $2 / 1073741824, $3 / 1073741824 }' "$RUN/usage" ;;
    set)
        [ -n "$2" ] || { echo "usage: ax10.sh set <key> <value>" >&2; exit 1; }
        k="${2#iot_}"
        # /etc is ramfs: plain `uci commit` is lost on reboot. TP-Link's uci_commit_flash
        # goes through its patched luci.model.uci, which also writes the config to flash.
        $UCI set "$SEC.iot_$k=$3" || exit 1
        commit_cfg && echo "saved iot_$k" ;;
    *) sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
