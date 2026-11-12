# ==== src/70-ui.sh: stock web UI and dashboard install
# ------------------------------------------------------------- stock web UI
# The UI lives on the read-only squashfs. Copy the few directories we touch into
# RAM, add our files, and bind-mount the copies over the originals. Gone on reboot;
# `ax10.sh boot` puts them back.
WWW="${WWW:-/www/webpages}"
WWW_ROOT="${WWW_ROOT:-${WWW%/*}}"
LUCI_CTL="${LUCI_CTL:-/usr/lib/lua/luci/controller/admin}"
UI_SRC="$RUN/ui"
OV="$RUN/overlay"
UI_VER=iot6
mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }
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
    [ -f "$UI_SRC/iot_net.lua" ] && return 0
    mkdir -p "$UI_SRC"
    curl -4 -L -k -fs -m 60 "$SRC/iot-ui.tar.gz" -o "$RUN/iot-ui.tgz" || return 1
    if [ -s "$SIGN_PUB" ]; then
        curl -4 -L -k -fs -m 30 "$SRC/iot-ui.tar.gz.sig" -o "$RUN/iot-ui.tgz.sig" &&
            openssl dgst -sha256 -verify "$SIGN_PUB" -signature "$RUN/iot-ui.tgz.sig" "$RUN/iot-ui.tgz" >/dev/null 2>&1 ||
            { log "iot-ui.tar.gz: signature check failed, not installing"; rm -f "$RUN/iot-ui.tgz"*; return 1; }
    fi
    gzip -dc "$RUN/iot-ui.tgz" | tar xf - -C "$UI_SRC" && rm -f "$RUN/iot-ui.tgz"*
}
# In-place sed without sed's -i flag (its syntax differs between busybox/GNU and BSD).
sed_in() { sed "$1" "$2" > "$2.new" && cat "$2.new" > "$2"; rm -f "$2.new"; }   # sed_in <script> <file>
ui_install() {
    ui_fetch || { log "could not fetch iot-ui"; return 1; }
    ctl="$(overlay "$LUCI_CTL" luci-ctl)" || return 1
    cp "$UI_SRC/iot_net.lua" "$ctl/iot_net.lua"; chmod 644 "$ctl/iot_net.lua"
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

    w="$(overlay "$WWW/modules/advanced/wireless" wireless)" || return 1
    for m in iotNetwork guestSpeed; do
        rm -rf "$w/$m"; cp -a "$UI_SRC/$m" "$w/$m"; chmod -R a+rX "$w/$m"
    done

    c="$(overlay "$WWW/config" config)" || return 1
    grep -q '"iotNetwork"' "$c/navigator.json" ||
        sed_in 's/{"name":"guestNetworkAdv","text":"GUEST_NETWORK"}/&,{"name":"iotNetwork","text":"IOT_NETWORK"}/' "$c/navigator.json"
    grep -q '"guestSpeed"' "$c/navigator.json" ||
        sed_in 's/{"name":"guestNetworkAdv","text":"GUEST_NETWORK"}/&,{"name":"guestSpeed","text":"GUEST_SPEED"}/' "$c/navigator.json"
    # (Re)register the module; the ?t= version makes browsers fetch updated files.
    for m in iotNetwork guestSpeed; do
        grep -q "$m/script.js?t=$UI_VER\"" "$c/modules.json" && continue
        sed_in "s#\"$m\":{[^}]*},##" "$c/modules.json"
        sed_in "1s#^{#{\"$m\":{\"controller\":\"./modules/advanced/wireless/$m/script.js?t=$UI_VER\",\"view\":\"./modules/advanced/wireless/$m/view.html?t=$UI_VER\"},#" "$c/modules.json"
    done

    lang="$($UCI -q get locale.sysinfo.locale)"; lang="${lang:-en_US}"
    [ -f "$WWW/locale/$lang/lan.js" ] || lang=en_US
    l="$(overlay "$WWW/locale/$lang" "locale-$lang")" || return 1
    # Replace our labels line (it starts with ;$.su.CHAR.MENU_ITEMS_NAME.IOT_NETWORK).
    if ! grep -qF "$(cat "$UI_SRC/locale.js")" "$l/lan.js"; then
        grep -v '^;\$\.su\.CHAR\.MENU_ITEMS_NAME\.IOT_NETWORK' "$l/lan.js" > "$l/lan.js.new"
        { echo; cat "$UI_SRC/locale.js"; } >> "$l/lan.js.new"; cat "$l/lan.js.new" > "$l/lan.js"; rm -f "$l/lan.js.new"
    fi
    # Theme: the per-language stylesheet loads after the stock ones, so our rules go at
    # its end (from the marker to end of file is ours; replaced on every install).
    if [ -f "$UI_SRC/theme.css" ]; then
        touch "$l/lan.css"
        sed '/ax10-theme-begin/,$d' "$l/lan.css" > "$l/lan.css.new"
        { echo '/* ax10-theme-begin */'; cat "$UI_SRC/theme.css"; } >> "$l/lan.css.new"
        cat "$l/lan.css.new" > "$l/lan.css"; rm -f "$l/lan.css.new"
    fi
    # Dashboard at /: our page over the stock root redirect, and over /webpages/login.html,
    # where plain-HTTP visits are sent. The stock UI stays at /webpages/index.html.
    chmod -R a+rX "$UI_SRC/dash" 2>/dev/null
    bind_file "$UI_SRC/dash/index.html" "$WWW_ROOT/index.html"
    bind_file "$UI_SRC/dash/login.html" "$WWW/login.html"
    log "web UI installed: dashboard at /, stock pages and theme (Advanced > Wireless > IoT Network, Guest Speed)"
}
ui_remove() {
    for d in "$WWW_ROOT/index.html" "$WWW/login.html" "$LUCI_CTL" "$WWW/modules/advanced/wireless" "$WWW/config" "$WWW"/locale/*; do
        mounted "$d" && $UMOUNT "$d"
    done
    rm -rf "$OV" /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
    log "web UI page removed"
}
