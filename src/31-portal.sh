# ==== src/31-portal.sh: join-home page
# ------------------------------------------------------------- join-home page
# A device on the home allow list that connects to the guest Wi-Fi gets no internet
# there: its web requests go to a page on the router with the home Wi-Fi name,
# password and a QR code. It ends by itself once the device leaves the guest Wi-Fi.
# The standard captive-portal way, for those devices only:
#   - DNS (udp 53, redirected to PORTAL_DNS) answers every name with the router's
#     IPv4 address and no IPv6 answers; DNS over IPv6 to the router is refused, so
#     the phone falls back to IPv4;
#   - HTTP (tcp 80, redirected to PORTAL_PORT) gets "302 Found" to the page, so the
#     phone's captive-network check (captive.apple.com, connectivitycheck...) fails
#     and it opens its sign-in sheet;
#   - HTTPS to the router is reset at once (no stock-admin certificate warning);
#   - everything else is rejected (no internet), IPv4 and IPv6.
# One small Lua process serves both (a second uhttpd can't start: TP-Link's build
# registers a fixed ubus object). Only those devices can reach it: the page shows
# the home password.
CH_PORTAL=AX10_PORTAL; CH_PORTAL_IN=AX10_PORTAL_IN; CH_PORTAL_NAT=AX10_PORTAL_NAT
PORTAL_PORT="${PORTAL_PORT:-8081}"
PORTAL_DNS="${PORTAL_DNS:-5354}"
CH_PORTAL_IN6=AX10_PORTAL_IN6
LUA="${LUA:-/usr/bin/lua}"
PORTAL="$RUN/portal"
html_esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'"; s/'/\\&#39;/g"; }
portal_page() {
    sec="$(cfg home_wifi wl03)"
    ssid="$($UCI -q get "wireless.$sec.ssid")"; key="$($UCI -q get "wireless.$sec.psk_key")"
    [ -n "$ssid" ] || { log "join-home page: no SSID in wireless.$sec"; return 1; }
    mkdir -p "$PORTAL"
    for f in jquery.min.js jquery.qrcode.min.js; do [ -f "$PORTAL/$f" ] || cp "$WWW/js/libs/$f" "$PORTAL/$f" 2>/dev/null; done
    es="$(printf '%s' "$ssid" | html_esc)"; ek="$(printf '%s' "$key" | html_esc)"
    cat > "$PORTAL/index.html.new" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Join the home Wi-Fi</title>
<style>
:root{color-scheme:light dark;--bg:#f6f7f9;--card:#fff;--ink:#14181f;--muted:#5b6472;--line:#e3e6eb;--accent:#0f9d8a}
@media (prefers-color-scheme:dark){:root{--bg:#0d1014;--card:#161a20;--ink:#eef1f5;--muted:#9aa3b0;--line:#262c35;--accent:#2dd4bf}}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,system-ui,sans-serif}
main{max-width:420px;margin:0 auto;padding:28px 16px}
h1{font-size:24px;margin:0 0 6px}p{color:var(--muted);margin:0 0 18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;margin-bottom:14px}
.k{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.v{display:flex;align-items:center;gap:10px;font:600 20px/1.3 ui-monospace,Menlo,monospace;word-break:break-all;margin-top:2px}
.btn{display:block;text-align:center;background:var(--accent);color:#fff;text-decoration:none;font-weight:700;padding:13px;border-radius:11px}
button{margin-left:auto;flex:none;border:1px solid var(--line);background:transparent;color:var(--ink);border-radius:9px;padding:6px 12px;font:600 14px system-ui}
#qr{display:flex;justify-content:center;padding:8px 0}#qr canvas{background:#fff;padding:10px;border-radius:10px}
ol{color:var(--muted);padding-left:20px;margin:0}
</style></head><body><main>
<h1>You're on the home Wi-Fi list</h1>
<p>This device can now use the home network, so the guest Wi-Fi no longer gives it internet. Switch networks:</p>
<div class="card"><div class="k">Network</div><div class="v"><span id="s">$es</span></div></div>
<div class="card"><div class="k">Password</div><div class="v"><span id="p">$ek</span><button id="c" type="button">Copy</button></div></div>
<div class="card" id="apple" hidden><a class="btn" href="/home.mobileconfig">Join automatically</a>
<p style="margin:10px 0 0;font-size:14px">Downloads a Wi-Fi profile. Then open Settings, tap <b>Profile Downloaded</b>, and Install: the device joins <b>$es</b> by itself. If nothing downloads here, open Safari, visit any http:// site and tap this again.</p></div>
<div class="card"><ol><li>Copy the password.</li><li>Open Settings, then Wi-Fi.</li><li>Choose <b>$es</b> and paste the password.</li></ol></div>
<div class="card"><div class="k">Or scan from another phone</div><div id="qr"></div></div>
</main>
<script src="/jquery.min.js"></script><script src="/jquery.qrcode.min.js"></script>
<script>
var s=document.getElementById("s").textContent,p=document.getElementById("p").textContent;
if(/iPhone|iPad|iPod|Macintosh/.test(navigator.userAgent))document.getElementById("apple").hidden=false;
var q=function(x){return x.replace(/([\\\;,:"])/g,"\\\\\$1")};
try{jQuery("#qr").qrcode({width:200,height:200,text:unescape(encodeURIComponent("WIFI:T:WPA;S:"+q(s)+";P:"+q(p)+";;"))})}catch(e){document.getElementById("qr").textContent="QR code unavailable."}
document.getElementById("c").onclick=function(){var b=this;var done=function(){b.textContent="Copied"};
if(navigator.clipboard){navigator.clipboard.writeText(p).then(done,function(){sel()})}else sel();
function sel(){var r=document.createRange();r.selectNodeContents(document.getElementById("p"));var w=getSelection();w.removeAllRanges();w.addRange(r);try{document.execCommand("copy");done()}catch(e){}}};
</script></body></html>
EOF
    mv "$PORTAL/index.html.new" "$PORTAL/index.html"
    # Apple Wi-Fi profile: installing it joins the home network with the password saved.
    u1="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 7d1c4e2a-0b5f-4c4e-9a51-2f6d8e1b3a01)"
    u2="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 3e9b0f6c-8d2a-4f17-b6c4-5a0e7d9c1b02)"
    cat > "$PORTAL/home.mobileconfig" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PayloadContent</key><array><dict>
<key>PayloadType</key><string>com.apple.wifi.managed</string><key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>ax10.home.wifi.$u2</string><key>PayloadUUID</key><string>$u2</string>
<key>PayloadDisplayName</key><string>Home Wi-Fi ($es)</string>
<key>SSID_STR</key><string>$es</string><key>Password</key><string>$ek</string>
<key>EncryptionType</key><string>WPA3</string><key>AutoJoin</key><true/><key>HIDDEN_NETWORK</key><false/>
</dict></array>
<key>PayloadType</key><string>Configuration</string><key>PayloadVersion</key><integer>1</integer>
<key>PayloadIdentifier</key><string>ax10.home.$u1</string><key>PayloadUUID</key><string>$u1</string>
<key>PayloadDisplayName</key><string>Home Wi-Fi</string>
<key>PayloadDescription</key><string>Joins the home Wi-Fi ($es).</string>
<key>PayloadRemovalDisallowed</key><false/>
</dict></plist>
EOF
    cat > "$PORTAL/server.lua" <<'EOF'
-- server.lua <root> <addr> <http port> <dns port>: captive-portal DNS + HTTP.
local socket = require "socket"
local root, addr, hport, dport = arg[1], arg[2], tonumber(arg[3]), tonumber(arg[4])
local home = "http://" .. addr .. ":" .. hport .. "/"
local http = assert(socket.bind(addr, hport))
local dns = assert(socket.udp()); assert(dns:setsockname(addr, dport))
http:settimeout(0); dns:settimeout(0)
local ip4 = string.char(addr:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$"))
local function read(p) local f = io.open(p, "rb"); if not f then return nil end; local d = f:read("*a"); f:close(); return d end
-- Every A query gets the router; other types get an empty answer (so no IPv6).
local function answer(q)
    if #q < 17 then return nil end
    local i = 13
    while i <= #q do local n = q:byte(i); if n == 0 then break end; i = i + n + 1 end
    if i + 4 > #q then return nil end
    local qtype = q:byte(i + 1) * 256 + q:byte(i + 2)
    local question = q:sub(13, i + 4)
    local a = qtype == 1
    local r = q:sub(1, 2) .. "\129\128\0\1\0" .. (a and "\1" or "\0") .. "\0\0\0\0" .. question
    if a then r = r .. "\192\12\0\1\0\1\0\0\0\10\0\4" .. ip4 end
    return r
end
local function serve(c)
    c:settimeout(5)
    local path = (c:receive("*l") or ""):match("^%u+%s+(%S+)") or "/"
    local host = ""
    repeat local h = c:receive("*l"); if h then host = h:match("^[Hh]ost:%s*(%S+)") or host end until not h or h == ""
    local ours = host == addr .. ":" .. hport
    local js = ours and path:match("^/(jquery[%w.]*%.js)$")
    local body, head
    if ours and path == "/home.mobileconfig" then
        body = read(root .. "/home.mobileconfig") or ""
        head = "200 OK\r\nContent-Type: application/x-apple-aspen-config\r\nContent-Disposition: attachment; filename=home.mobileconfig"
    elseif js then body = read(root .. "/" .. js) or ""; head = "200 OK\r\nContent-Type: application/javascript"
    elseif ours then body = read(root .. "/index.html") or ""; head = "200 OK\r\nContent-Type: text/html; charset=utf-8"
    else body = '<a href="' .. home .. '">Join the home Wi-Fi</a>'; head = "302 Found\r\nLocation: " .. home .. "\r\nContent-Type: text/html" end
    c:send("HTTP/1.0 " .. head .. "\r\nCache-Control: no-store\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
    c:close()
end
while true do
    local ready = socket.select({ http, dns }, nil, 60)
    for _, s in ipairs(ready or {}) do
        if s == dns then
            local q, ip, port = dns:receivefrom()
            local r = q and answer(q)
            if r then dns:sendto(r, ip, port) end
        else
            local c = http:accept()
            if c then pcall(serve, c) end
        end
    end
end
EOF
}
portal_running() { pid_live "$RUN/portal.pid" portal/server.lua; }
portal_clear() {
    while $IPT -D FORWARD -i "$LANBR" -j $CH_PORTAL 2>/dev/null; do :; done
    while $IPT6 -D FORWARD -i "$LANBR" -j $CH_PORTAL 2>/dev/null; do :; done
    while $IPT -t nat -D PREROUTING -i "$LANBR" -j $CH_PORTAL_NAT 2>/dev/null; do :; done
    while $IPT -D INPUT -i "$LANBR" -j $CH_PORTAL_IN 2>/dev/null; do :; done
    while $IPT6 -D INPUT -i "$LANBR" -j $CH_PORTAL_IN6 2>/dev/null; do :; done
    $IPT -F $CH_PORTAL 2>/dev/null; $IPT -X $CH_PORTAL 2>/dev/null
    $IPT6 -F $CH_PORTAL 2>/dev/null; $IPT6 -X $CH_PORTAL 2>/dev/null
    $IPT -t nat -F $CH_PORTAL_NAT 2>/dev/null; $IPT -t nat -X $CH_PORTAL_NAT 2>/dev/null
    $IPT -F $CH_PORTAL_IN 2>/dev/null; $IPT -X $CH_PORTAL_IN 2>/dev/null
    $IPT6 -F $CH_PORTAL_IN6 2>/dev/null; $IPT6 -X $CH_PORTAL_IN6 2>/dev/null
    pid_kill "$RUN/portal.pid" portal/server.lua
}
# A phone checks for a captive portal only right after it joins. The watcher sees a
# new guest up to 15 s later, by when the check has passed and the phone thinks the
# network works. So a device newly given the page is disconnected from the guest
# Wi-Fi once: it rejoins at once, with the rules in place, and its check finds the
# page. A device that was on the page in the last PORTAL_GRACE seconds keeps it
# while it rejoins.
PORTAL_GRACE="${PORTAL_GRACE:-60}"
portal_sync() {
    pm=""; now="$(now_s)"
    if [ "$H_LOCK" = 1 ]; then
        g=" $(guest_macs | sort -u | tr '\n' ' ') "
        for m in $H_ALLOW $H_KEEP; do
            case "$g" in *" $m "*) case " $pm " in *" $m "*) ;; *) pm="$pm $m" ;; esac ;; esac
        done
        # Grace: listed devices seen on the page recently (they may be rejoining).
        if [ -f "$RUN/portal_seen" ]; then
            while read -r m t; do
                [ $((now - t)) -le "$PORTAL_GRACE" ] 2>/dev/null || continue
                home_listed "$m" || continue
                case " $pm " in *" $m "*) ;; *) pm="$pm $m" ;; esac
            done < "$RUN/portal_seen"
        fi
        { for m in $pm; do case "$g" in *" $m "*) echo "$m $now" ;; esac; done
          [ -f "$RUN/portal_seen" ] && cat "$RUN/portal_seen"; } | awk '!s[$1]++' > "$RUN/portal_seen.new"
        mv "$RUN/portal_seen.new" "$RUN/portal_seen"
    fi
    pm="$(echo $pm)"
    prev=" $(cat "$RUN/portal_macs" 2>/dev/null) "
    if [ -z "$pm" ]; then
        [ -s "$RUN/portal_macs" ] && log "join-home page off"
        [ -e "$RUN/portal_macs" ] && { portal_clear; rm -f "$RUN/portal_macs"; }
        return 0
    fi
    if [ "$pm" = "$(cat "$RUN/portal_macs" 2>/dev/null)" ] && portal_running &&
       $IPT -C FORWARD -i "$LANBR" -j $CH_PORTAL 2>/dev/null &&
       $IPT -t nat -C PREROUTING -i "$LANBR" -j $CH_PORTAL_NAT 2>/dev/null; then return 0; fi
    portal_clear
    portal_page || return 0
    lan="$($UCI -q get network.lan.ipaddr)"; lan="${lan:-192.168.0.1}"
    $IPT -N $CH_PORTAL 2>/dev/null; $IPT6 -N $CH_PORTAL 2>/dev/null
    $IPT -t nat -N $CH_PORTAL_NAT 2>/dev/null; $IPT -N $CH_PORTAL_IN 2>/dev/null; $IPT6 -N $CH_PORTAL_IN6 2>/dev/null
    for m in $pm; do
        $IPT -A $CH_PORTAL -m mac --mac-source "$m" -p tcp -j REJECT --reject-with tcp-reset
        $IPT -A $CH_PORTAL -m mac --mac-source "$m" -j REJECT
        $IPT6 -A $CH_PORTAL -m mac --mac-source "$m" -j REJECT
        $IPT -t nat -A $CH_PORTAL_NAT -m mac --mac-source "$m" -p tcp --dport 80 -j DNAT --to-destination "$lan:$PORTAL_PORT"
        $IPT -t nat -A $CH_PORTAL_NAT -m mac --mac-source "$m" -p udp --dport 53 -j DNAT --to-destination "$lan:$PORTAL_DNS"
        $IPT -A $CH_PORTAL_IN -m mac --mac-source "$m" -p tcp --dport "$PORTAL_PORT" -j ACCEPT
        $IPT -A $CH_PORTAL_IN -m mac --mac-source "$m" -p udp --dport "$PORTAL_DNS" -j ACCEPT
        $IPT -A $CH_PORTAL_IN -m mac --mac-source "$m" -p tcp --dport 53 -j REJECT --reject-with tcp-reset
        $IPT -A $CH_PORTAL_IN -m mac --mac-source "$m" -p tcp --dport 443 -j REJECT --reject-with tcp-reset
        $IPT6 -A $CH_PORTAL_IN6 -m mac --mac-source "$m" -p udp --dport 53 -j REJECT
        $IPT6 -A $CH_PORTAL_IN6 -m mac --mac-source "$m" -p tcp -j REJECT --reject-with tcp-reset
    done
    $IPT -A $CH_PORTAL_IN -p tcp --dport "$PORTAL_PORT" -j DROP
    $IPT -A $CH_PORTAL_IN -p udp --dport "$PORTAL_DNS" -j DROP
    $IPT -I FORWARD 1 -i "$LANBR" -j $CH_PORTAL; $IPT6 -I FORWARD 1 -i "$LANBR" -j $CH_PORTAL
    $IPT -t nat -I PREROUTING 1 -i "$LANBR" -j $CH_PORTAL_NAT
    $IPT -I INPUT 1 -i "$LANBR" -j $CH_PORTAL_IN; $IPT6 -I INPUT 1 -i "$LANBR" -j $CH_PORTAL_IN6
    $LUA "$PORTAL/server.lua" "$PORTAL" "$lan" "$PORTAL_PORT" "$PORTAL_DNS" >/dev/null 2>&1 &
    pid_save "$RUN/portal.pid" $!
    echo "$pm" > "$RUN/portal_macs"
    command -v fcctl >/dev/null 2>&1 && fcctl flush >/dev/null 2>&1
    log "guest Wi-Fi: showing the join-home page to $pm"
    # Newly added: make them rejoin so their captive-portal check sees the page.
    for m in $pm; do
        case "$prev" in *" $m "*) continue ;; esac
        for i in $(guest_ifs); do
            $WL -i "$i" assoclist 2>/dev/null | grep -qi "$m" && $WL -i "$i" deauthenticate "$(echo "$m" | tr a-f A-F)" 2>/dev/null
        done
    done
}
