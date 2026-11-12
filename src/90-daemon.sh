# ==== src/90-daemon.sh: the watcher: run_all, the apply-soon worker, init registration
# "Apply what is saved, soon": what the dashboard asks for after every change.
# A request leaves a note ($RUN/sync.want) and waits for the run lock. Whoever holds
# it to apply notes goes on until none is left, and a request that gets the lock and
# finds its note already taken is done. So a burst of changes is one or two passes,
# and none is lost: a note left after the holder's last look belongs to a request that
# is still waiting for the lock, and that request applies it. If it gives up waiting,
# the note stays, and the watcher's next pass applies it.
kick_run() {   # kick_run: under the run lock
    while [ -e "$RUN/sync.want" ]; do
        rm -f "$RUN/sync.want"
        [ -n "$KICK_COUNT" ] && echo pass >> "$KICK_COUNT"     # the offline tests count the passes
        run_all; watcher_sync
    done
}
# The watcher is what makes saved settings take effect and keeps them in place, and
# the fallback for every "apply soon" request that did not get through (one that gave
# up waiting for the lock, or was killed): it always runs. With every feature off a pass is
# a few settings read and nothing else.
watcher_wanted() { return 0; }
# Everything the watcher keeps in place, each part only while it is switched on.
# Local names and DNS over HTTPS don't need the IoT network: apply() covers them
# when it runs, names_sync when it doesn't.
# Speed limits, the home allow list and the usage log are not part of the IoT
# network either: they run whether it is on or off.
run_all() {
    if iot_on; then apply
    else
        # Switched off in the settings while it is still up: take it down here, so
        # "off" needs no command of its own (the dashboard only saves and asks for a sync).
        # "Still up" is read off the router itself (the slot sitting in the IoT bridge),
        # not only off our own note, which a killed run may never have written.
        load
        if [ -s "$RUN/orig_bridge" ] || [ "$(bridge_of "$VIF")" = "$BR" ]; then iot_teardown; fi
        names_sync
    fi
    shape_sync
    home_sync
    usage_sync
}
shaping_wanted() { [ "$(cfg wan_shape 0)" = 1 ] || [ "$(cfg guest_limit 0)" = 1 ] || [ -n "$(cfg caps '')" ]; }
# The watcher is registered exactly while something needs it. Only under the run lock.
# The entry must name this file: one left from the old name (or another path) is
# rewritten, and the watcher it started is stopped, since init no longer looks after
# it and it would hold the watcher lock for good; init then starts the new entry.
watcher_sync() {
    if watcher_wanted; then
        grep -qF "::respawn:/bin/sh $SELF watch # $TAG" "$INITTAB" 2>/dev/null && return 0
        grep -q "$TAG" "$INITTAB" 2>/dev/null && ws_old=1 || ws_old=""
        inittab_add
        if [ -n "$ws_old" ]; then watcher_restart >/dev/null; log "watcher entry updated to $SELF"; else log "watcher registered"; fi
    else inittab_del; fi
}

# busybox-init respawn supervision (same approach as ax10-svc; the stock inittab's
# last line has no trailing newline, so rebuild through grep).
TAG="ax10-iot-watch"
# inittab is rewritten in place (cat > it), so two writers at once could leave it
# empty: only commands holding the run lock call these, and each uses its own temp file.
inittab_add() {
    { grep -v "$TAG" "$INITTAB" 2>/dev/null; echo "::respawn:/bin/sh $SELF watch # $TAG"; } > "$INITTAB.new.$$"
    [ -s "$INITTAB.new.$$" ] && cat "$INITTAB.new.$$" > "$INITTAB"; rm -f "$INITTAB.new.$$"; $INIT_HUP 2>/dev/null
}
# A running watcher keeps the functions it loaded at start; after ax10.sh is
# replaced on disk, kill it so init respawns it with the new code.
watcher_restart() {   # prints the pids it stopped (watchers started as $SELF or by the old name)
    for d in /proc/[0-9]*; do
        [ "${d#/proc/}" = "$$" ] && continue
        case "$( { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null)" in
            *"$SELF watch"*|*"$LEGACY_SELF watch"*) kill "${d#/proc/}" 2>/dev/null && echo "${d#/proc/}" ;;
        esac
    done
}
# Stop the running watchers and make sure they are gone before going on. boot, start
# and ui do this right after self_install, before they take over: after an update, the watcher still running may
# be an older version's, which doesn't know this lock. A watcher that hasn't gone in
# 10 s is killed outright; then a moment for commands it had started (an iptables or
# tc call outlives the shell that ran it) to finish. (init starts a new watcher at once,
# from the new file; its passes wait for the lock the caller holds.)
watcher_stop_wait() {
    ws_p="$(watcher_restart)"; ws_i=0
    [ -n "$ws_p" ] || return 0
    while :; do
        ws_l=""; for p in $ws_p; do kill -0 "$p" 2>/dev/null && ws_l="$ws_l $p"; done
        ws_p="$ws_l"; [ -n "$ws_p" ] || break
        if [ "$ws_i" -ge 10 ]; then for p in $ws_p; do kill -9 "$p" 2>/dev/null; done; sleep 1; break; fi
        sleep 1; ws_i=$((ws_i + 1))
    done
    sleep 2
}
# Put this file in place as $SELF: copied aside, made executable, then renamed over the
# old one, so a watcher starting a pass at that moment runs either the old file or the
# new one whole, never half of one.
self_install() {
    if [ "$0" != "$SELF" ]; then
        cp "$0" "$SELF.new.$$" 2>/dev/null && chmod 755 "$SELF.new.$$" && mv -f "$SELF.new.$$" "$SELF" ||
            { rm -f "$SELF.new.$$"; log "could not install $0 as $SELF"; return 1; }
    fi
    # The old name points here, so anything still calling it runs this. (A shell
    # running the old file keeps reading it: replacing the name doesn't touch that.)
    [ -n "$LEGACY_SELF" ] && [ "$LEGACY_SELF" != "$SELF" ] && [ "$(readlink "$LEGACY_SELF" 2>/dev/null)" != "$SELF" ] &&
        ln -sf "$SELF" "$LEGACY_SELF" 2>/dev/null
    return 0
}
inittab_del() {
    grep -q "$TAG" "$INITTAB" 2>/dev/null || return 0
    grep -v "$TAG" "$INITTAB" > "$INITTAB.new.$$"; cat "$INITTAB.new.$$" > "$INITTAB"; rm -f "$INITTAB.new.$$"
    $INIT_HUP 2>/dev/null
    for d in /proc/[0-9]*; do
        [ "${d#/proc/}" = "$$" ] && continue
        case "$( { tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null)" in *"$SELF watch"*) kill "${d#/proc/}" 2>/dev/null;; esac
    done
}
