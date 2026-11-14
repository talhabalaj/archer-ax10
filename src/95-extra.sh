# ==== src/95-extra.sh: the parts of ax10.sh that come with the downloaded files
# ax10.sh is kept small enough to be saved in flash (src/75-saved-copy.sh; the settings
# partition is shared with TP-Link's own settings). What isn't needed until the release
# has downloaded lives in src/extra/ and is built into extra.sh, which comes in
# ax10-files.tar.gz (signed with the release key, like ax10.sh; the web UI and the
# helpers come the same way):
#   - the speaker relay (24-iot-mdns) and MQTT alerts (65-alerts): their helpers
#     (mdns.lua, mqtt.lua) are in those files anyway;
#   - data usage (60-usage) and the router load log (61-load): nothing to count before
#     the internet is up, and the dashboard that shows them comes with the files.
# extra.sh is loaded only if it was built with this ax10.sh (the same stamp), so the
# copy in flash never runs with another release's extras. Without it (a boot from that
# copy, before anything is downloaded) the stand-ins below do nothing, and everything
# else runs as usual.
AX10_BUILD="@@BUILD@@"
EXTRA="$UI_SRC/extra.sh"
extra_matches() { [ "$(sed -n '2s/^# ax10-build: //p' "$EXTRA" 2>/dev/null)" = "$AX10_BUILD" ]; }
# Files there but from another build (ax10.sh replaced, or a release published between
# the two downloads): fetched again by the watcher, every 10 minutes at most. (No files
# at all is the boot's to fetch, or the copy in flash waiting for the release.)
extra_retry() {
    [ -n "$EXTRA_LOADED" ] && return 0
    [ -f "$UI_SRC/web/ax10.lua" ] || return 0
    t="$(now_s)"; last="$(cat "$RUN/extra.retry" 2>/dev/null)"
    [ -n "$last" ] && [ "$t" -ge "$last" ] && [ $((t - last)) -lt 600 ] && return 0
    echo "$t" > "$RUN/extra.retry"
    ui_install && extra_matches && log "files of this build fetched; extras load from the next pass"
}

# Kept here, not in extra.sh, because the rest of ax10.sh must get them right with or
# without it: the firewall's mDNS rule and the IoT teardown (a firewall built without
# them would keep counting as up to date once extra.sh loads), and saving the usage log
# before a reboot (hours of counting would be lost).
mdns_ips() {     # "all", or the listed IoT addresses that are valid and on the IoT network
    for a in $(cfg mdns ''); do [ "$a" = all ] && { echo all; return; }; done
    for a in $(cfg mdns ''); do valid_ip4 "$a" && case "$a" in "$PREFIX".*) echo "$a" ;; esac; done
}
mdns_running() { pid_live "$RUN/mdns.pid" mdns.lua; }
mdns_stop() { pid_kill "$RUN/mdns.pid" mdns.lua; rm -f "$RUN/mdns.sig" "$RUN/mdns.stat"; }
# Saved as UCI lists, one short entry each: TP-Link's startup cuts any single saved
# value to 2465 characters, and the devices of two months in one value would pass that.
usage_save() {   # $RUN/usage -> flash, in whole MB (nothing without a log in RAM: never an empty save)
    [ -s "$RUN/usage" ] || return 0
    for k in days:T: months:M: devs:D:; do
        key="$SEC.iot_usage_${k%%:*}"; p="${k#*:}"
        $UCI -q delete "$key"
        awk -v p="$p" 'index($1, p) == 1 { printf "%s=%.0f/%.0f\n", substr($1, 3), $2 / 1048576, $3 / 1048576 }' "$RUN/usage" |
            while read -r e; do $UCI add_list "$key=$e"; done
    done
    commit_cfg >/dev/null
}
usage_on() { [ "$(cfg usage_on 1)" = 1 ]; }       # counting is on unless iot_usage_on=0

# Stand-ins for what the rest of ax10.sh calls (extra.sh defines the real ones).
mdns_sync() { :; }
usage_sync() { :; }
load_guard() { :; }
alerts_on() { return 1; }
alerts_sync() { :; }
alerts_discovery() { :; }
alerts_flush() { :; }
alert() { :; }
alert_blocked() { :; }
mq_waiting() { return 1; }
EXTRA_LOADED=""
if extra_matches; then . "$EXTRA" && EXTRA_LOADED=1; fi
