# ==== src/32-devices.sh: forgetting devices, per-device settings
# Devices forgotten on the dashboard are listed in iot_hidden_devices and stay off
# its lists while offline. (iot_hidden is something else: "hide the IoT network name".)
valid_mac() { echo "$1" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; }
# forget_devices <mac>[,<mac>...]: drop everything we keep for those devices: allow
# list entry and pin, speed cap, internet/speed/IoT-access settings, IoT fixed
# address (and block re-pinning), last seen. Checked as a whole before anything is
# written, saved with one commit. Custom names are cleared by the dashboard backend.
forget_devices() {
    macs=""
    for m in $(echo "$1" | tr ',A-F-' ' a-f:'); do
        valid_mac "$m" || { echo "ax10.sh: bad MAC '$m'" >&2; return 1; }
        macs="$macs $m"
    done
    [ -n "$macs" ] || { echo "usage: ax10.sh forget-device <mac>[,<mac>...]" >&2; return 1; }
    home_load
    a=""; for m in $H_ALLOW; do case " $macs " in *" $m "*) ;; *) a="$a $m" ;; esac; done
    k=""; for m in $H_KEEP; do case " $macs " in *" $m "*) ;; *) k="$k $m" ;; esac; done
    if [ "$H_LOCK" = 1 ] && [ -z "$(echo $a $k)" ]; then
        echo "ax10.sh: that would empty the home allow list; turn the lock off first" >&2; return 1
    fi
    $UCI set "$SEC.iot_home_allow=$(echo $a)" && $UCI set "$SEC.iot_home_keep=$(echo $k)" || return 1
    # Space-separated lists whose entries start with the MAC ("mac", "mac=...", "mac,...").
    pinned=""
    for key in caps noinet guest_fast lan_allow lan_open static; do
        v="$(cfg "$key" '')"; [ -n "$v" ] || continue
        out=""; for e in $v; do
            em="$(echo "${e%%[=,]*}" | tr 'A-F-' 'a-f:')"
            case " $macs " in *" $em "*) [ "$key" = static ] && pinned="$pinned $em"; continue ;; esac
            out="$out $e"
        done
        $UCI set "$SEC.iot_$key=$(echo $out)" || return 1
    done
    fg="$(cfg forget '' | tr 'A-F-' 'a-f:')"
    for m in $pinned; do case " $fg " in *" $m "*) ;; *) fg="$fg $m" ;; esac; done
    [ -n "$pinned" ] && $UCI set "$SEC.iot_forget=$(echo $fg)"
    hd="$(cfg hidden_devices '' | tr 'A-F-' 'a-f:')"
    for m in $macs; do case " $hd " in *" $m "*) ;; *) hd="$hd $m" ;; esac; done
    $UCI set "$SEC.iot_hidden_devices=$(echo $hd)" || return 1
    sed_seen_del $macs
    commit_cfg >/dev/null || { echo "ax10.sh: could not save" >&2; return 1; }
    log "forgot device(s):$macs"
}
# unhide <connected macs>: a forgotten device that is back is an ordinary device again.
unhide() {
    hd="$(cfg hidden_devices '' | tr 'A-F-' 'a-f:')"; [ -n "$hd" ] || return 0
    out=""; back=""
    for m in $hd; do case " $1 " in *" $m "*) back="$back $m" ;; *) out="$out $m" ;; esac; done
    [ -n "$back" ] || return 0
    $UCI set "$SEC.iot_hidden_devices=$(echo $out)" && commit_cfg >/dev/null
    log "forgotten device(s) back on the network:$back"
}
# entry_set <caps|noinet|guest_fast|lan_allow|lan_open> <mac> <value|on|off>: change one
# device's entry in a per-device list, under the run lock, so the dashboard never
# writes a stale copy of the list. caps takes "down/up" in Mbps, or off.
entry_set() {
    case "$1" in caps|noinet|guest_fast|lan_allow|lan_open) ;; *) echo "ax10.sh: entry caps|noinet|guest_fast|lan_allow|lan_open <mac> <value|on|off>" >&2; return 1 ;; esac
    mac="$(echo "$2" | tr 'A-F-' 'a-f:')"; valid_mac "$mac" || { echo "ax10.sh: bad MAC '$2'" >&2; return 1; }
    new=""
    case "$1:$3" in
        *:off) ;;
        caps:*) echo "$3" | grep -Eq '^[0-9]{1,4}/[0-9]{1,4}$' || { echo "ax10.sh: cap is down/up in Mbps" >&2; return 1; }
                [ "$3" = 0/0 ] || new="$mac=$3" ;;
        *:on) new="$mac" ;;
        *) return 1 ;;
    esac
    out=""; for e in $(cfg "$1" ''); do
        [ "$(echo "${e%%[=,]*}" | tr 'A-F-' 'a-f:')" = "$mac" ] || out="$out $e"
    done
    $UCI set "$SEC.iot_$1=$(echo $out $new)" || return 1
    # Giving a forgotten device a setting brings it back onto the lists.
    hd=""; for m in $(cfg hidden_devices '' | tr 'A-F-' 'a-f:'); do [ "$m" = "$mac" ] || hd="$hd $m"; done
    $UCI set "$SEC.iot_hidden_devices=$(echo $hd)"
    commit_cfg >/dev/null || return 1
}
