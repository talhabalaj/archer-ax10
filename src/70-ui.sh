# ==== src/70-ui.sh: the dashboard's install (TP-Link's own web UI is left as it is)
# --------------------------------------------------------------------- web UI
# Our files come from the release next to ax10.sh (ax10-files.tar.gz, signed):
#   web/dashboard.html   the dashboard, served at / (https://192.168.0.1/)
#   web/ax10.lua         its backend, a LuCI controller at /admin/ax10
#   helpers/             DNS over HTTPS, the automatic speed limit, CA certificates
# The web root is on the read-only squashfs, so the dashboard is bind-mounted over
# the stock root page (a redirect to /webpages/index.html), and the controller goes
# into a RAM copy of the controller directory. Nothing else of TP-Link's UI is
# touched: its pages, menu, language files and login stay stock, at
# /webpages/index.html. (Earlier versions added pages and a theme to it; ui_install
# takes those down.) Gone on reboot; `ax10.sh boot` puts them back.
WWW="${WWW:-/www/webpages}"
WWW_ROOT="${WWW_ROOT:-${WWW%/*}}"
LUCI_CTL="${LUCI_CTL:-/usr/lib/lua/luci/controller/admin}"
UI_SRC="$RUN/files"
OV="$RUN/overlay"
PROC_MOUNTS="${PROC_MOUNTS:-/proc/mounts}"
mounted() { grep -q " $1 " "$PROC_MOUNTS" 2>/dev/null; }
overlay() {   # overlay <dir> <name>: bind a writable RAM copy over <dir>, echo the copy's path
    if ! mounted "$1"; then
        rm -rf "$OV/$2"; mkdir -p "$OV"
        cp -a "$1" "$OV/$2" && $MOUNT --bind "$OV/$2" "$1" || return 1
    fi
    echo "$1"
}
bind_file() {   # bind_file <src> <dst>: show <src> at existing file <dst> (re-bound, so updates show)
    [ -f "$1" ] && [ -f "$2" ] || return 0
    mounted "$2" && $UMOUNT "$2"
    $MOUNT --bind "$1" "$2"
}
# The boot hook leaves the release public key here; when present, downloads must
# carry a valid signature (see boot.sh).
SIGN_PUB="${SIGN_PUB:-/tmp/archer-sign.pub}"
ui_fetch() {
    [ -f "$UI_SRC/web/ax10.lua" ] && return 0
    mkdir -p "$UI_SRC"
    curl -4 -L -k -fs -m 60 "$SRC/ax10-files.tar.gz" -o "$RUN/files.tgz" || return 1
    if [ -s "$SIGN_PUB" ]; then
        curl -4 -L -k -fs -m 30 "$SRC/ax10-files.tar.gz.sig" -o "$RUN/files.tgz.sig" &&
            openssl dgst -sha256 -verify "$SIGN_PUB" -signature "$RUN/files.tgz.sig" "$RUN/files.tgz" >/dev/null 2>&1 ||
            { log "ax10-files.tar.gz: signature check failed, not installing"; rm -f "$RUN/files.tgz"*; return 1; }
    fi
    gzip -dc "$RUN/files.tgz" | tar xf - -C "$UI_SRC" && rm -f "$RUN/files.tgz"*
}
# What earlier versions changed in TP-Link's UI: its Advanced > Wireless pages, menu,
# module list and language files (overlays), and its login page (a redirect to us).
UI_LEGACY_DIRS="modules/advanced/wireless config"
ui_legacy_remove() {
    gone=""
    for d in $UI_LEGACY_DIRS; do mounted "$WWW/$d" && $UMOUNT "$WWW/$d" && gone=1; done
    for d in "$WWW"/locale/*; do mounted "$d" && $UMOUNT "$d" && gone=1; done
    mounted "$WWW/login.html" && $UMOUNT "$WWW/login.html" && gone=1
    rm -rf "$OV/wireless" "$OV/config" "$OV"/locale-* "$RUN/ui" 2>/dev/null
    [ -n "$gone" ] && log "TP-Link's own web UI is back to stock (pages, menu, theme and login redirect removed)"
    return 0
}
ui_install() {
    ui_fetch || { log "could not fetch ax10-files"; return 1; }
    ui_legacy_remove
    ctl="$(overlay "$LUCI_CTL" luci-ctl)" || return 1
    cp "$UI_SRC/web/ax10.lua" "$ctl/ax10.lua"; chmod 644 "$ctl/ax10.lua"
    rm -f "$ctl/iot_net.lua"                       # the controller's old name
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
    chmod -R a+rX "$UI_SRC/web" 2>/dev/null
    bind_file "$UI_SRC/web/dashboard.html" "$WWW_ROOT/index.html"
    log "web UI installed: dashboard at / (TP-Link's own UI untouched, at /webpages/index.html)"
}
ui_remove() {
    ui_legacy_remove
    for d in "$WWW_ROOT/index.html" "$LUCI_CTL"; do mounted "$d" && $UMOUNT "$d"; done
    rm -rf "$OV" /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
    log "web UI removed"
}
