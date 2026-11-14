# ==== src/75-saved-copy.sh: the copy of ax10.sh in flash that the boot hook starts first
# A copy of ax10.sh in flash, started by the boot hook before anything is downloaded,
# so the home allow list and the IoT network are up within seconds of every boot,
# with or without internet. The router keeps no files
# across a reboot, only its settings (a 128 KB flash partition, shared with TP-Link's),
# so the copy is a setting: ax10.sh gzipped and base64'd (about 58 KB; what waits for
# the download anyway is in extra.sh, see 95-extra), in chunks of
# 1000 characters, with the release's own signature. (TP-Link's startup cuts every
# list value to 2465 characters as it loads the settings: 4000-character chunks came
# back cut short after a reboot, and the copy no longer verified. Seen on the router.) The boot hook (scripts/signed-hook.sh) checks that
# signature with the release key before it runs the copy. Written only when
# the release changed, since each write rewrites the settings in flash; skipped if it
# would fill the partition past ~90 KB (TP-Link's own format adds ~8%), and read
# back before it is trusted.
save_copy() {    # save_copy <ax10.sh> <ax10.sh.sig>: under the run lock (ax10.sh boot, with SAVE_COPY_SIG)
    C="${CACHE_UCI:-/sbin/uci}"; K=openvpn.archer_boot
    [ -s "$1" ] && [ -s "$2" ] || return 0
    sum="$(md5sum < "$1" | cut -d' ' -f1)"
    [ "$($C -q get $K.cache_iot_sum)" = "$sum" ] && return 0
    gz="$(gzip -9c < "$1" | /usr/bin/openssl base64 -A)"
    rest="$(for f in "${CACHE_CONF:-/etc/config}"/*; do if [ "${f##*/}" = openvpn ]; then grep -v cache_iot "$f"; else cat "$f"; fi; done 2>/dev/null | gzip -9 | wc -c)"
    if [ $((rest + ${#gz})) -ge 90000 ]; then echo "offline copy of ax10.sh not saved: it would fill the settings partition"; return 0; fi
    $C -q delete $K.cache_iot
    echo "$gz" | awk '{ for (i = 1; i <= length($0); i += 1000) print substr($0, i, 1000) }' |
        while read -r c; do $C add_list "$K.cache_iot=$c"; done
    $C set "$K.cache_iot_sig=$(/usr/bin/openssl base64 -A < "$2")"
    $C set "$K.cache_iot_sum=$sum"
    if [ "$($C -q get $K.cache_iot | tr -d ' \n' | /usr/bin/openssl base64 -d -A | gzip -dc | md5sum | cut -d' ' -f1)" != "$sum" ]; then
        echo "offline copy of ax10.sh did not read back intact; not saved"
        $C revert openvpn 2>/dev/null || { $C -q delete $K.cache_iot; $C -q delete $K.cache_iot_sig; $C -q delete $K.cache_iot_sum; }
        return 0
    fi
    if [ -x "${CACHE_COMMIT:-/sbin/uci_commit_flash}" ]; then "${CACHE_COMMIT:-/sbin/uci_commit_flash}" openvpn; else $C commit openvpn; fi ||
        { echo "offline copy of ax10.sh not saved: the settings could not be written"
          # nothing staged may stay behind (the next commit would write it), and no
          # checksum may claim this release is saved, so the next boot tries again
          $C revert openvpn 2>/dev/null || { $C -q delete $K.cache_iot; $C -q delete $K.cache_iot_sig; $C -q delete $K.cache_iot_sum; }
          return 1; }
    echo "offline copy of ax10.sh saved to flash"
}
