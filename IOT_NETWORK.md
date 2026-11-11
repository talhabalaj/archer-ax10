# Isolated IoT Wi-Fi on the stock AX10 firmware

`iot.sh` adds a separate 2.4 GHz Wi-Fi network for smart devices (the inverter's
Wi-Fi logger, cameras) to the stock TP-Link firmware, with a settings page in the
stock web UI. It needs no reflash and no opkg: `boot.sh` fetches it each boot.

Status (2026-11-10): tested live with an iPhone, an Apple Watch and the inverter
logger. Reboot test with release `v21-personal` passed: after a reboot the
network, the web page and the SSH lifeline all came back without manual steps
(about 10 s after the boot hook started).

## What it does

```
br-lan  192.168.0.1/24   home: "wifi", guest networks, LAN ports, mesh satellite
br-iot  192.168.50.1/24  IoT:  wl1.4 (the IoT SSID)
```

| From → to | Result |
| --- | --- |
| Home LAN → IoT | allowed (apps, inverter-link) |
| IoT → home LAN | blocked, except replies and `iot_allow_lan` exceptions |
| IoT → router | DHCP, DNS and ping only (no web UI, no SSH) |
| IoT → internet | allowed, except MACs in `iot_noinet` (switching a device off also cuts its open connections) |
| IoT, IPv6 | off: disabled on `br-iot` and dropped by `ip6tables` (`AX10_IOT6`); the IoT network is IPv4-only |

- **Wi-Fi:** the spare 2.4 GHz slot `wl1.4` becomes the IoT SSID (name,
  password and hidden flag set through hostapd and `wl`).
- **Bridge:** `wl1.4` is moved from `br-lan` into its own bridge, `br-iot`.
- **DHCP:** a block in `/etc/dnsmasq.conf` makes the stock dnsmasq serve
  `192.168.50.100–200`, plus static leases.
- **Firewall:** the chains `AX10_IOT_FWD`, `AX10_IOT_IN` and `AX10_IOT_NAT`
  (masquerade out any non-bridge interface).
- **Watcher:** busybox-init `respawn` runs `iot.sh watch`, which re-applies every
  15 s whatever TP-Link undoes.
- **Web page:** Advanced → Wireless → IoT Network (enable, SSID, password, hide,
  IoT → home exceptions, per-device Internet switch).
- **Dashboard:** `https://192.168.0.1/` opens our own dark dashboard (see
  [Dashboard](#dashboard-at-)); the stock UI stays at `/webpages/index.html`.

## Usage

```sh
sh /tmp/iot.sh set ssid "wifi-iot"
sh /tmp/iot.sh set key  "<8-63 chars>"
sh /tmp/iot.sh set static "ec:64:c9:d9:e0:b7,192.168.50.10"   # inverter logger
sh /tmp/iot.sh set allow_lan "tcp:8899@192.168.50.10"          # inverter-link callback
sh /tmp/iot.sh set noinet "<camera-mac>"                       # optional
sh /tmp/iot.sh set enabled 1
sh /tmp/iot.sh ui      # install the web page
sh /tmp/iot.sh start   # apply + register the watcher
sh /tmp/iot.sh status
sh /tmp/iot.sh stop    # undo everything, give wl1.4 back to TP-Link
```

Settings are UCI options `openvpn.archer_boot.iot_*`, saved with
`uci_commit_flash`. `boot.sh` runs `iot.sh boot` whenever `iot_enabled` exists
(0 or 1): that installs the page, and starts the network if the value is 1.
Release assets: `iot.sh`, `iot-ui.tar.gz`. The offline test is `sh tests/iot.sh`;
CI runs it before publishing.

inverter-link: the phone is on another subnet, so automatic discovery won't find
the logger. Add it by IP (192.168.50.10). The logger connects back to the phone
on TCP 8899, which is what the `allow_lan` exception permits.

## Home allow list and join-home page

Our own allow list for the home network, run by the watcher (`iot.sh home`), edited on
the dashboard's Wi-Fi tab. TP-Link's Access Control stays off: in allow-list mode it
also filters the guest Wi-Fi, and its guest exemption uses `-m physdev`, which this
kernel lacks, so guests silently lose internet.

- Home radios (`iot_home_ifs`, default `wl0.1 wl1.1`) take only listed MACs
  (`wl macmode 2`); unlisted clients are disconnected.
- Unlisted home clients the radios can't see (behind the mesh satellite, wired) are
  dropped by MAC in the raw table (`AX10_HOME`). Guests are never dropped.
- `iot.sh home-open [s]` lets new devices in for a while; they are added as they appear.
- Last-seen times are saved daily; `iot_home_expire=N` removes entries unseen for N
  days, except pinned ones (`iot_home_keep`).
- Edits go through `iot.sh home-allow` / `home-set` under the run lock. Turning the
  lock on pins the requesting device (resolved on the router), and refuses an empty list.
- A listed device that joins the guest Wi-Fi gets the join-home page instead of
  internet: its DNS answers every name with the router (no IPv6), HTTP gets a 302 to
  the page (so the phone's captive-network check opens it), HTTPS is reset. A small Lua
  server serves it (a second uhttpd can't start on TP-Link's build).
- Apple devices change their private MAC when the network's security changes (e.g.
  WPA2/WPA3 to WPA3-only): add the new MACs before such a change, or they are locked out.

## What we learned about this router

### Storage and persistence
- The root filesystem is read-only squashfs. `/etc` is **ramfs**, `/tmp` is
  tmpfs, and nothing in them survives a reboot.
- `uci commit` writes only to RAM. TP-Link's `/sbin/uci_commit_flash <config>`
  (its patched `luci.model.uci`; plain commit is `commit_without_write_flash`)
  writes the config to flash. That's how `openvpn.archer_boot.*` persists.
- Read-only files can be changed for the current boot with a RAM copy plus
  `mount --bind` (works for directories and single files). Network namespaces and
  veth pairs are not supported.

### Network layout
- `br-lan` holds `eth1–eth4` (LAN ports) and every Wi-Fi interface. The WAN is
  PPPoE (`pppoe-internet` over `eth0`).
- Wi-Fi interfaces: `wl0` = 5 GHz radio, `wl1` = 2.4 GHz radio. Each has
  virtual APs `.1–.4`:

  | Slot | Role |
  | --- | --- |
  | `wlX.1` | main SSID ("wifi") |
  | `wlX.2` | hidden EasyMesh backhaul (the existing satellite uses it; don't touch) |
  | `wlX.3` | guest network |
  | `wlX.4` | OneMesh/EasyMesh **config (onboarding) slot**: hidden, down, random SSID |

- One hostapd per radio (`/tmp/wl1.1_hapd.conf`, `/tmp/wl0.1_hapd.conf`) serves
  every BSS on that radio. hostapd 2.9 accepts runtime `set ssid`/`set
  wpa_passphrase`, and `reload_wpa_psk` re-derives one BSS's key without
  kicking other clients.
- `wl -i <if> ssid/bss/closed/assoclist/sta_info` is the Broadcom driver CLI.
  The 2.4 GHz channel is auto-selected and moved from 6 to 8 during this
  session.

### Things that blocked the IoT network
1. **Second DHCP server:** the stock dnsmasq binds `0.0.0.0:67` without
   `SO_REUSEADDR`, so busybox `udhcpd` fails with "Address in use". It runs as
   `dnsmasq -C /var/etc/dnsmasq.conf`, which TP-Link regenerates but which
   includes `/etc/dnsmasq.conf` (never regenerated). Adding a tagged
   `dhcp-range` there works.
2. **Mesh flags on `wl1.4`:** TP-Link's script sets `wl1.4_map=3` (EasyMesh
   backhaul + fronthaul) and `wl1.4_dwds=1`.
   - Effect: the driver creates a `wds1.4.N` interface per client, and TP-Link
     bridges it into **br-lan**, so an IoT device would land on the home network.
   - Fix: `wl -i wl1.4 dwds 0; wl -i wl1.4 map 0`. Both return `Not down` unless
     the whole radio is down (`wl -i wl1 down … up`), which briefly drops that
     band; all clients and the mesh satellite reconnected.
   - The values come from `/lib/wifi/tplink_brcm.sh` (`${CONFIG_WIFI}_map="3"`,
     `${RTORCFG_WIFI}_dwds="1"`).
   - `/sbin/wifi up wl1` does nothing here (the `brcmwifi` enable/disable hooks
     are empty stubs). The real rebuild is `wifi reload`, which restarts both
     radios.
3. **`br-filter` (TP-Link guest isolation, `/lib/modules/iplatform/br-filter.ko`):**
   - It drops all *forwarded* traffic from interfaces listed in
     `/proc/bridge_filter/deny_all`. Traffic to the router itself (DHCP) still
     works, so clients get an address but no internet, and iOS says "No Internet
     Connection".
   - `/etc/init.d/br-filter` (OneMesh v2) puts `wl1.4 wl0.4 wds1.4 wds0.4`
     there; `device_list` holds the guest slots (`wl1.3 wl0.3`).
   - It's invisible to iptables. Packets passed raw, mangle and nat PREROUTING,
     then vanished with no error counters. Found by unloading suspect modules
     one at a time.
   - Fix: rewrite `deny_all` without `wl1.4`/`wds1.4`.
4. **Hardware acceleration:** Broadcom Archer and the flow cache (`archerctl`,
   `fcctl`) are active. `fcctl flush` after firewall changes keeps
   already-accelerated flows from bypassing new rules.

### Other stock pieces
- TP-Link "Device Isolation" (`iotctl`, `iot_security` controller) isolates
  chosen clients in **both** directions, so the phone couldn't reach the
  inverter; not useful here.
- Modules `domain_dns`/`domain_redirect` (tplinkwifi.net DNS hijack, replies
  sent out `br-lan`) and `wportal` (guest captive portal) were suspects but not
  the cause.
- The IPTV/VLAN page (Bridge mode) only maps wired LAN ports to the WAN side.
  It can't isolate Wi-Fi devices.
- `vlanctl`, `bcmvlan` and `ethswctl`-style switch tooling exist (Broadcom
  `bcm_enet` impl7 with an SF2 switch, one netdev per port), but weren't needed
  for Wi-Fi isolation.

### Stock web UI
- **Front end:** a JS app on TP-Link's `$.su` framework under `/www/webpages`.
  `config/navigator.json` is the menu tree. `config/modules.json` maps a module
  name to its `script.js`/`view.html`. Menu labels come from
  `$.su.CHAR.MENU_ITEMS_NAME` in `locale/<lang>/lan.js`.
- **Pages:** a page is `$.su.moduleManager.define(name, {models, stores, views,
  listeners: {ev_on_launch}, init})`. Models and stores take
  `proxy: {url: $.su.url("/admin/<controller>?form=<form>")}`, and the
  framework handles the encrypted request format. The global Save button
  submits models that have changed.
  - Field validation: `allowBlank`, `minLength`/`maxLength`,
    `vtype: "psk_password"`.
  - Widgets: `panel`, `checkbox`, `textbox`, `password`, `displaylabel`, `grid`,
    `switch`.
- **Back end:** compiled Lua controllers in `/usr/lib/lua/luci/controller/admin`.
  A plain-source controller loads fine:

  ```lua
  module("luci.controller.admin.x", package.seeall)
  local ctl = require "luci.model.controller"
  local tbl = { form = { read = {cb=f}, write = {cb=g}, load = {cb=h}, update = {cb=u} } }
  function dispatch(http_form) return ctl.dispatch(tbl, http_form) end
  function _index() return ctl._index(dispatch) end
  function index() entry({"admin","x"}, call("_index")).leaf = true end
  ```

  Delete `/tmp/luci-indexcache` after adding a controller.

### SSH lifeline at boot
- Twice, after a reboot with the IoT network enabled (v20), the dropbear
  lifeline on :2222 was not running even though `boot.sh` starts it before the
  IoT step; the cause was not visible without a shell. On the v21 reboot the
  original process survived. As a safeguard, `boot.sh` re-checks the lifeline
  after the IoT step and the watcher restarts it within 15 s, logging
  `SSH lifeline was not running; restarted it` to `/tmp/ax10-iot/iot.log`.
- Only the RSA host key persists (`openvpn.archer_boot.host_key`); dropbear's
  ECDSA key is regenerated each boot (`-R`). Pin the RSA key in known_hosts
  and connect with `-o HostKeyAlgorithms=ssh-rsa` to avoid host-key warnings.

### Speed limits (dashboard Speed tab; Advanced → Wireless → Guest Speed)
- Three optional caps, all applied by `iot.sh shape` and kept in sync by the
  watcher: per device (`iot_caps`, `mac=down/up` in Mbps, 0 = no cap that way),
  guests (`iot_guest_limit`, `iot_guest_down`/`iot_guest_up` per device; MACs in
  `iot_guest_fast` exempt; a per-device cap wins), and the whole connection
  (`iot_wan_shape`, `iot_wan_down`/`iot_wan_up`). Guests are the devices on our
  guest Wi-Fi plus those TP-Link's client list (`/tmp/client_list.json`) marks
  `GUEST` and connected, which covers guests behind the mesh satellite.
- Matched by **MAC**, so a cap covers IPv4 and IPv6 and survives a new IP.
  Download: `htb` on `br-lan`'s egress (routed traffic into the home bridge;
  traffic between home devices is bridged and never passes there), one class per
  device, `u32 match ether dst`. Upload: `br-lan` ingress → `mirred` redirect to
  `ifb0` → `htb` class per device, `u32 match ether src`. Leaves are `sfq`. The IoT
  bridge is never shaped.
- Broadcom acceleration bypasses Linux queues. Capped devices' connections get
  conntrack bit `0x1000000` in mangle PREROUTING (`-m mac --mac-source`, iptables
  and ip6tables) and `BLOGSKIP` in mangle FORWARD by that bit; with the whole
  connection capped, everything forwarded gets `BLOGSKIP`. Packet marks are left
  alone: TP-Link's VPN client saves its mark bit `0x40000` into the conntrack mark.
- Measured (MacBook on 5 GHz, Cloudflare speed test): a 5/2 Mbps cap gave
  3.1–4.6 / 1.5–1.9 Mbps over IPv4 and 3.6–4.6 / 1.7–1.9 over IPv6; removed,
  17–23 / 65–72. The non-accelerated path carries the full line (whole connection
  capped at 100: 18–23 Mbps down, same as accelerated).
- Whole connection: this line showed no bufferbloat (ping 19–20 ms idle and
  under full download or upload load), so the cap is off by default. With it at
  18/60, one device got 8–17 Mbps, depending on what the rest of the house was
  using.
- **Lanes** (need the whole-connection cap). Priority (`iot_prio=1`, class 1:2,
  htb prio 0, 40% guaranteed): Zoom 8801–8810, STUN/TURN 3478–3481, Meet
  19302–19309, Teams 50000–50059 (u32 port blocks are mask-aligned, so a few
  neighbours ride along), UDP packets under 512 bytes (games, voice; bulk QUIC
  and torrents use full-size packets), ICMP, DSCP EF/AF41. IPv4 filters use u32
  prio 2 and IPv6 prio 3 (filters sharing a prio must share a protocol). Guests
  last (`iot_guest_low=1`): class 1:3 (prio 2, 10%) holds guests' own cap classes
  and leaf 1:4 for the rest of their traffic, matched by MAC at prio 1 after the
  cap filters. Normal traffic is 1:10 (prio 1). Measured: with the line saturated,
  ping and DNS stayed at idle levels with or without the priority lane (sfq already
  keeps sparse flows ahead); the lane's value is bandwidth for calls when many bulk
  flows compete. A Meet call was seen on UDP 19305 over IPv6, in the lane.
- **Per-device stats** (dashboard device details): byte counters, signal per
  antenna, noise, link rate, MCS/streams/width, security and retries from
  `wl sta_info` (exact, Wi-Fi clients of this router; read in the cached probe);
  live speed is the difference between two readings. Wired devices fall back to
  `ubus call tfstats get` (marked approximate: it misses most accelerated
  traffic); devices behind the mesh satellite have no counters here. Connections
  come from `/proc/net/nf_conntrack` (the device as original source or
  destination; IPv6 is printed zero-padded there).
- htb's default burst (a few KB) under-delivers here, so classes get ~20 ms of
  traffic at their rate (at least 15 KB). Queue limits: `sfq limit` = 3 packets
  per Mbps, 20–127.
- Kernel 4.1.52 queueing: `htb`, `sfq`, `prio` are present; `fq_codel`, `codel`,
  `cake`, `pie`, `fq`, `tbf`, `red`, `hfsc`, `drr`, `netem` are not. An earlier
  note here said `sfq` was missing; it isn't.
- The stock firmware has a hidden per-device limit (`smart_network?form=client_speed_limit`,
  `write` with `mac`, `enableLimit`, kbps limits; the UI hides it unless
  `supportSpeedLimit`). It accepts settings and enforces nothing on this unit.
- Live updates: `iot.sh` runs take turns through a lock (`/tmp/ax10-iot/lock`),
  so a rebuild by hand, the watcher and the web page cannot interleave. A
  command that cannot get the lock within 60 s exits with an error; the
  watcher skips that pass and tries again 15 s later.

### Device lists on the pages
- Rows show where a device is now (Wi-Fi SSID and band from `wl assoclist`,
  wired/mesh port from `brctl showmacs`, else ARP), mark the device viewing the
  page (`REMOTE_ADDR`), sort online first, and can be renamed (UCI list
  `iot_names`, `mac=name`). The stock grid's store sync sends only the first
  changed row, so list switches save immediately via `ev_grid_custom_change`.

### Dashboard at /
- `iot-ui/dash/index.html` is one self-contained page (no build step). `iot.sh ui`
  bind-mounts it over `/www/index.html` (what `https://192.168.0.1/` serves) and
  bind-mounts `dash/login.html`, a redirect to `/`, over `/www/webpages/login.html`
  (where uhttpd sends every plain-HTTP visit). The stock UI stays at
  `/webpages/index.html`; `iot.sh ui-remove` undoes both mounts.
- Tabs: Devices (every device with name, IP, where it is connected; rename, block,
  and the IoT/guest switches), IoT, Guests, Wi-Fi (passwords with copy and a join
  QR code). It refreshes every 10 s while visible.
- **Login and encryption:** every LuCI request is AES-encrypted and RSA-signed. The
  page loads the stock scripts (`jquery`, `cryptoJS`, `encrypt.js`, `tpEncrypt.js`)
  and repeats the stock login: `login?form=keys` (RSA key for the password),
  `login?form=auth` (signing key and sequence number), then `login?form=login`
  with `confirm=true` (replaces any other admin session). The hash is
  MD5("admin" + password), or SHA-256 on Singapore units, which the page does not handle.
- **Shared session:** the page stores the token and keys under the stock UI's
  `localStorage` names (`token`, `encryptorAES`, `encryptorSeq`, `encryptorHash`,
  `encryptorRsa`), so each side opens the other already logged in. The router
  allows one admin session: a login elsewhere replaces ours, and our replies then
  fail to decrypt, which the page reports as "signed out".
- **Backend:** `iot_net.lua` forms `devices` (one list with every DHCP lease, the
  presence data, block-list and IoT/guest flags), `device` (write name, internet,
  allowed, fast for one MAC) and `summary` (uptime and the PPPoE interface
  `network.interface.internet` from ubus). The page adds names and guest status
  from the stock `access_control?form=black_devices` list, which also sees guests
  connected through the mesh satellite.
- **Blocking** uses the stock Access Control block list:
  `access_control?form=mode` (write `access_mode=black`), `form=enable` (write
  `enable=on`), `form=black_list` (`insert` with `new={"name","mac":"AA-BB-…"}`;
  `remove` with `key=<mac>` and `index`). Unblocking the last device switches
  Access Control back off. Tested with a made-up MAC, not a real device.
- Links to stock pages go to `/webpages/index.html`; the stock UI ignores URL
  fragments, so the page leaves the target in `sessionStorage` (`ax10-go`) and
  `locale.js`, which runs inside the stock UI, opens it once the menu is up.

### Known trade-offs
- While the IoT network runs, OneMesh onboarding of a **new** satellite over
  2.4 GHz won't work (its config slot is in use). Existing satellites use
  `wl1.2`/`wl0.2` and are unaffected.
- When TP-Link restarts Wi-Fi, it resets `wl1.4`'s SSID and its `br-filter`
  entry. The watcher repairs both within about 15 s. The mesh flags stay cleared
  thanks to the patched Wi-Fi script.
