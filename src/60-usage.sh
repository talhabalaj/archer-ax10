# ==== src/60-usage.sh: data usage log
# ------------------------------------------------------------- data usage
# How much data the household uses: per day and per month in total (from the
# internet connection's own counters, so every device counts), and per device per
# month from two sources:
#   - devices on the main router's Wi-Fi: the radio's counters (all their traffic,
#     IPv6 included, and traffic between devices at home);
#   - every other device (on the mesh satellite, a cable, or one the radios don't
#     list right now): TP-Link's own per-device statistics (tfstats), which count
#     internet traffic by IPv4 address only, and only what passes through Linux:
#     with the whole-connection limit on, that is all of it; with it off, the
#     hardware fast path carries most traffic past these counters. What they miss
#     (IPv6 above all) is left over in the totals as "not matched to a device".
# tfstats keeps counting a device while it is on our Wi-Fi too, so its readings are
# taken every run and only added for devices the radios don't list: nothing is
# counted twice when a device moves between the router and the satellite.
# The log lives in $RUN/usage as lines "<key> <down bytes> <up bytes>":
#   T:2026-11-12        a day's total        (kept 62 days)
#   M:2026-11           a month's total      (kept 24 months)
#   D:2026-11:<mac>     a device in a month  (this month and the last)
# and is saved to flash every 4 hours (in MB, iot_usage_*; USAGE_SAVE_EVERY seconds),
# so a power cut loses at most the last 4 hours. (Each save rewrites the router's
# settings in flash, which wears with writes: 6 a day is plenty.) Counters restart on a reboot or reconnect; a reading lower than the
# last one is taken as a fresh count.
# The first reading after a start needs care, because the "last readings" file is in
# RAM. If it is missing and this is a new boot (iot_usage_boot in flash names another
# one), the counters began with the boot and all of it is new usage. If it is missing
# for any other reason (the feature's very first run on a router that has been up for
# days, or the file was lost), the counters hold history that was never ours or was
# counted already: that reading only sets the baseline.
WAN_DEV="${WAN_DEV:-}"
usage_wan() {
    [ -n "$WAN_DEV" ] && { echo "$WAN_DEV"; return; }
    ubus call network.interface.internet status 2>/dev/null | sed -n 's/.*"l3_device": "\([^"]*\)".*/\1/p'
}
UBUS="${UBUS:-ubus}"
usage_tf() {     # TP-Link's per-device internet counters: "<mac> <down bytes> <up bytes>"
    # rx is what the device received (a camera shows mostly tx). Only private
    # addresses: the list also has the router's own WAN address.
    $UBUS call tfstats get '{"page":0,"pagesize":200}' 2>/dev/null | awk -F'[":, ]+' '
        /"ip"/ { ip = $3 } /"mac"/ { m = tolower($3); gsub("-", ":", m) }
        /"total_rx_byte"/ { r = $3 }
        /"total_tx_byte"/ { if (m ~ /^[0-9a-f:]+$/ && (ip ~ /^(10|192\.168)\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./)) { d[m] += r; u[m] += $3 } }
        END { for (m in d) printf "%s %.0f %.0f\n", m, d[m], u[m] }'
}
usage_load() {   # the log as saved in flash -> $RUN/usage (bytes)
    { for e in $(cfg usage_days ''); do echo "T:${e%%=*} ${e#*=}"; done
      for e in $(cfg usage_months ''); do echo "M:${e%%=*} ${e#*=}"; done
      for e in $(cfg usage_devs ''); do echo "D:${e%%=*} ${e#*=}"; done
    } | awk '{ split($2, v, "/"); if (v[1] ~ /^[0-9]+$/ && v[2] ~ /^[0-9]+$/) printf "%s %.0f %.0f\n", $1, v[1] * 1048576, v[2] * 1048576 }' > "$RUN/usage"
}
usage_save() {   # $RUN/usage -> flash, in whole MB
    pick() { awk -v p="$1" 'index($1, p) == 1 { printf "%s=%.0f/%.0f ", substr($1, 3), $2 / 1048576, $3 / 1048576 }' "$RUN/usage" | sed 's/ $//'; }
    $UCI set "$SEC.iot_usage_days=$(pick T:)"; $UCI set "$SEC.iot_usage_months=$(pick M:)"; $UCI set "$SEC.iot_usage_devs=$(pick D:)"
    commit_cfg >/dev/null
}
usage_on() { [ "$(cfg usage_on 1)" = 1 ]; }       # counting is on unless iot_usage_on=0
usage_sync() {
    usage_on || return 0
    [ -n "$(epoch)" ] || return 0                 # no clock yet: nothing to file a reading under
    mkdir -p "$RUN"; [ -f "$RUN/usage" ] || usage_load
    day="${USAGE_DAY:-$(date +%Y-%m-%d)}"; wd="$(usage_wan)"
    { [ -n "$wd" ] && [ -r "$NET/$wd/statistics/rx_bytes" ] &&
          echo "C wan $(cat "$NET/$wd/statistics/rx_bytes") $(cat "$NET/$wd/statistics/tx_bytes")"
      # the home, guest and IoT radios' clients: bytes sent to them / received from them
      for i in $(cfg home_ifs 'wl0.1 wl1.1') $(guest_ifs) "$(cfg vif wl1.4)"; do
          [ -d "$NET/$i" ] || continue
          for m in $($WL -i "$i" assoclist 2>/dev/null | awk '{print $2}'); do
              $WL -i "$i" sta_info "$m" 2>/dev/null | awk -v m="$m" '/tx total bytes:/ {t=$4} /rx data bytes:/ {r=$4} END { if (t != "" && r != "") printf "C %s %.0f %.0f\n", tolower(m), t, r }'
          done
      done
      # everyone, from TP-Link's statistics (after the radios: see the awk below)
      usage_tf | awk '{ printf "C t:%s %s %s\n", $1, $2, $3 }'
    } > "$RUN/usage.cur"
    base=0; boot="${USAGE_BOOT:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)}"
    if [ ! -f "$RUN/usage.last" ]; then
        : > "$RUN/usage.last"
        was="$(cfg usage_boot '')"
        # a new boot only if an earlier one was recorded and it is not this one
        if [ -z "$was" ] || [ -z "$boot" ] || [ "$was" = "$boot" ]; then base=1; fi
        [ "$was" = "$boot" ] || { $UCI set "$SEC.iot_usage_boot=$boot" && commit_cfg >/dev/null; }
    fi
    # Counting is under way in this boot: make sure flash says so (written once per boot).
    [ "$base" = 0 ] && [ -n "$boot" ] && [ "$(cfg usage_boot '')" != "$boot" ] && { $UCI set "$SEC.iot_usage_boot=$boot" && commit_cfg >/dev/null; }
    awk -v day="$day" -v base="$base" -v lastf="$RUN/usage.last" -v curf="$RUN/usage.cur" '
        BEGIN {
            month = substr(day, 1, 7)
            while ((getline l < lastf) > 0) {
                split(l, a, " "); ld[a[1]] = a[2]; lu[a[1]] = a[3]; seen[a[1]] = 1
                if (a[1] ~ /^t:/) hast = 1; else if (a[1] != "wan") hasdev = 1
            }
            # Readings from before tfstats was counted here (an update in the middle of
            # a boot): its counters hold this boot so far, which was never ours to add.
            tbase = base || (hasdev && !hast)
            while ((getline l < curf) > 0) {
                split(l, a, " "); id = a[2]; d = a[3] + 0; u = a[4] + 0
                t = (id ~ /^t:/)
                # known reading: the growth, or all of it if the counter restarted.
                # unknown: all of it (a device that has just connected), unless this
                # run only sets baselines.
                dd = seen[id] ? (d >= ld[id] ? d - ld[id] : d) : ((t ? tbase : base) ? 0 : d)
                du = seen[id] ? (u >= lu[id] ? u - lu[id] : u) : ((t ? tbase : base) ? 0 : u)
                ld[id] = d; lu[id] = u; seen[id] = 1
                if (id == "wan") { add("T:" day, dd, du); add("M:" month, dd, du) }
                else if (!t) { radio[id] = 1; add("D:" month ":" id, dd, du) }
                else if (!(substr(id, 3) in radio)) add("D:" month ":" substr(id, 3), dd, du)
            }
            for (id in seen) printf "%s %.0f %.0f\n", id, ld[id], lu[id] > (lastf ".new")
        }
        function add(k, d, u) { if (d > 0 || u > 0 || k !~ /^D:/) { nd[k] += d; nu[k] += u } }   # no rows for devices that used nothing
        { k = $1; if (!(k in out)) order[++n] = k; out[k] = 1; D[k] = $2 + nd[k]; U[k] = $3 + nu[k]; delete nd[k]; delete nu[k] }
        END {
            for (k in nd) { order[++n] = k; D[k] = nd[k]; U[k] = nu[k] }
            for (i = 1; i <= n; i++) printf "%s %.0f %.0f\n", order[i], D[order[i]], U[order[i]]
        }' "$RUN/usage" > "$RUN/usage.new" && mv "$RUN/usage.new" "$RUN/usage" && mv "$RUN/usage.last.new" "$RUN/usage.last"
    # Keep 62 days, 24 months, and devices for this month and the last.
    now="$(epoch)"
    dcut="$(date -d "@$((now - 62 * 86400))" +%Y-%m-%d 2>/dev/null)"; mcut="$(date -d "@$((now - 730 * 86400))" +%Y-%m 2>/dev/null)"
    uy="${day%%-*}"; um="${day#*-}"; um="${um%%-*}"; um=$((1$um - 100))      # "03" -> 3 (no octal surprises)
    if [ "$um" = 1 ]; then pm="$((uy - 1))-12"; else pm="$(printf '%04d-%02d' "$uy" "$((um - 1))")"; fi
    if [ -n "$dcut" ] && [ -n "$mcut" ] && [ -n "$pm" ]; then
        awk -v dcut="T:$dcut" -v mcut="M:$mcut" -v m1="D:${day%-*}:" -v m2="D:$pm:" '
            /^T:/ { if ($1 >= dcut) print; next } /^M:/ { if ($1 >= mcut) print; next }
            /^D:/ { if (index($1, m1) == 1 || index($1, m2) == 1) print; next }' "$RUN/usage" | sort > "$RUN/usage.new" && mv "$RUN/usage.new" "$RUN/usage"
    fi
    # To flash every few hours.
    last="$(cat "$RUN/usage.saved" 2>/dev/null)"
    if [ $((now - ${last:-0})) -ge "${USAGE_SAVE_EVERY:-14400}" ]; then usage_save; echo "$now" > "$RUN/usage.saved"; fi
}
