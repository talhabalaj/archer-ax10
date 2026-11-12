# ==== src/21-iot-devices.sh: IoT network: DHCP block, pinned devices, lock
# ---------------------------------------------------------------------- DHCP
# The stock dnsmasq owns port 67 on 0.0.0.0, so a second DHCP server cannot bind.
# Instead, add the IoT range to /etc/dnsmasq.conf, which TP-Link's generated
# /var/etc/dnsmasq.conf includes via conf-file= and never rewrites. /etc is in RAM,
# so the block disappears on reboot and boot.sh adds it again.
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.conf}"
DNSMASQ_INIT="${DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
MARK_BEGIN="# ax10-iot begin"; MARK_END="# ax10-iot end"
# ------------------------------------------------------------ known devices
# Every IoT device keeps its address: each pass pins new IoT leases into iot_static.
# Lock (iot_lock=1): only pinned devices may join the IoT Wi-Fi (Broadcom MAC allow
# list, macmode 2), and unknown ones already connected are dropped. `ax10.sh open`
# lets new devices join for a while; they are pinned as they get an address.
commit_cfg() {   # commit_cfg [config]; /etc is ramfs: TP-Link's uci_commit_flash also writes flash
    if [ -x "${COMMIT_FLASH:-/sbin/uci_commit_flash}" ]; then "${COMMIT_FLASH:-/sbin/uci_commit_flash}" "${1:-openvpn}"
    else $UCI commit "${1:-openvpn}"; fi
}
# Devices removed with "Forget" (iot_forget) are not pinned again from their old
# lease; only the "allow new devices" window takes them back.
autopin() {
    [ -f "$LEASES" ] || return 0
    STATIC="$(cfg static '')"            # fresh: the dashboard may have changed it
    autopin_locked
}
autopin_locked() {
    new=""; back=""; forget="$(cfg forget '' | tr A-F a-f)"
    while read -r _exp mac ip _rest; do
        case "$ip" in "$PREFIX".*) ;; *) continue ;; esac
        mac="$(echo "$mac" | tr A-F a-f)"
        case " $STATIC $new " in *" $mac,"*) continue ;; esac
        case " $forget " in *" $mac "*) lock_open || continue; back="$back $mac" ;; esac
        new="$new $mac,$ip"
    done < "$LEASES"
    [ -n "$new" ] || return 0
    STATIC="$(echo $STATIC $new)"
    $UCI set "$SEC.iot_static=$STATIC"
    if [ -n "$back" ]; then
        f=""; for m in $forget; do case " $back " in *" $m "*) ;; *) f="$f $m" ;; esac; done
        $UCI set "$SEC.iot_forget=$(echo $f)"
    fi
    commit_cfg >/dev/null
    log "fixed address for new IoT device(s):$new"
}
known_macs() { for s in $STATIC; do echo "${s%%,*}"; done | tr a-f A-F | sort | tr '\n' ' '; }
now_s() { if [ -r /proc/uptime ]; then cut -d. -f1 /proc/uptime; else date +%s; fi; }   # seconds since boot
lock_open() {    # is the "allow new devices" window open?
    u="$(cat "$RUN/open_until" 2>/dev/null)"
    [ -n "$u" ] && [ "$(now_s)" -lt "$u" ] 2>/dev/null
}
lock_sync() {
    [ -d "$NET/$VIF" ] || return 0
    if [ "$(cfg lock 0)" = 1 ] && ! lock_open; then
        want="$(known_macs)"
        have="$($WL -i "$VIF" mac 2>/dev/null | awk '{print toupper($2)}' | sort | tr '\n' ' ')"
        if [ "$want" != "$have" ]; then
            $WL -i "$VIF" mac none 2>/dev/null
            [ -n "$want" ] && $WL -i "$VIF" mac $want
        fi
        if [ "$($WL -i "$VIF" macmode 2>/dev/null)" != 2 ]; then
            $WL -i "$VIF" macmode 2
            log "IoT network locked to $(echo $want | wc -w) known device(s)"
        fi
        for m in $($WL -i "$VIF" assoclist 2>/dev/null | awk '{print toupper($2)}'); do
            case " $want " in *" $m "*) ;; *) $WL -i "$VIF" deauthenticate "$m" 2>/dev/null; log "removed unknown device $m from the IoT network" ;; esac
        done
    elif [ "$($WL -i "$VIF" macmode 2>/dev/null)" = 2 ]; then
        $WL -i "$VIF" macmode 0
        log "IoT network open to new devices"
    fi
}
