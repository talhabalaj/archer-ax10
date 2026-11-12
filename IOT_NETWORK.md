# Isolated IoT Wi-Fi on the stock AX10 firmware

`ax10.sh` adds a separate 2.4 GHz Wi-Fi network for smart devices (the inverter's
Wi-Fi logger, cameras) to the stock TP-Link firmware, set up on our dashboard. It
needs no reflash and no opkg: `boot.sh` fetches it each boot. TP-Link's own web UI
is left as it is.

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
- **Watcher:** busybox-init `respawn` runs `ax10.sh watch`, which re-applies every
  15 s whatever TP-Link undoes.
- **Dashboard:** `https://192.168.0.1/` opens our own dashboard (see
  [Dashboard](#dashboard-at-)); the stock UI stays at `/webpages/index.html`.

## Usage

```sh
sh /tmp/ax10.sh set ssid "wifi-iot"
sh /tmp/ax10.sh set key  "<8-63 chars>"
sh /tmp/ax10.sh set static "aa:bb:cc:dd:ee:01,192.168.50.10"   # inverter logger
sh /tmp/ax10.sh set allow_lan "tcp:8899@192.168.50.10"          # inverter-link callback
sh /tmp/ax10.sh set noinet "<camera-mac>"                       # optional
sh /tmp/ax10.sh set enabled 1
sh /tmp/ax10.sh ui      # install the web page
sh /tmp/ax10.sh start   # apply + register the watcher
sh /tmp/ax10.sh status
sh /tmp/ax10.sh stop    # undo everything, give wl1.4 back to TP-Link
```

Settings are UCI options `openvpn.archer_boot.iot_*`, saved with
`uci_commit_flash`. `boot.sh` runs `ax10.sh boot` whenever `iot_enabled` exists
(0 or 1): that installs the page, and starts the network if the value is 1.
Release assets: `ax10.sh`, `ax10-files.tar.gz` (the dashboard, its backend and the
helpers, built into `build/ax10-files` by `scripts/build.sh`). `ax10.sh` is built from `src/` by
`scripts/build.sh`. The offline tests are `sh tests/run.sh`; CI runs them before
publishing.

inverter-link: the phone is on another subnet, so automatic discovery won't find
the logger. Add it by IP (192.168.50.10). The logger connects back to the phone
on TCP 8899, which is what the `allow_lan` exception permits.

## Home allow list and join-home page

Our own allow list for the home network, run by the watcher (`ax10.sh home`), edited on
the dashboard's Wi-Fi tab. TP-Link's Access Control stays off: in allow-list mode it
also filters the guest Wi-Fi, and its guest exemption uses `-m physdev`, which this
kernel lacks, so guests silently lose internet.

- Home radios (`iot_home_ifs`, default `wl0.1 wl1.1`) take only listed MACs
  (`wl macmode 2`); unlisted clients are disconnected.
- Unlisted home clients the radios can't see (behind the mesh satellite, wired) are
  dropped by MAC in the raw table (`AX10_HOME`). Guests are never dropped.
- `ax10.sh home-open [s]` lets new devices in for a while; they are added as they appear.
- Last-seen times are saved daily; `iot_home_expire=N` removes entries unseen for N
  days, except pinned ones (`iot_home_keep`).
- Edits go through `ax10.sh home-allow` / `home-set` under the run lock. Turning the
  lock on pins the requesting device (resolved on the router), and refuses an empty list.
- A listed device that joins the guest Wi-Fi gets the join-home page instead of
  internet: its DNS answers every name with the router (no IPv6), HTTP gets a 302 to
  the page (so the phone's captive-network check opens it), HTTPS is reset. A small Lua
  server serves it (a second uhttpd can't start on TP-Link's build).
- Apple devices change their private MAC when the network's security changes (e.g.
  WPA2/WPA3 to WPA3-only): add the new MACs before such a change, or they are locked out.

## Local names and DNS over HTTPS

Pi-hole-style local names, served by the stock dnsmasq (`iot_dns_on=1`):

- Every device gets `<hostname>.<suffix>` (suffix `iot_dns_domain`, default `home`,
  editable on the dashboard's Internet tab), the router gets the names in
  `iot_dns_router` (e.g. `router`), and `iot_dns_hosts` adds fixed ones
  (`name=ip`). dnsmasq runs with `domain=`, `local=/<suffix>/`,
  `addn-hosts=$RUN/hosts`, `no-resolv` and our `server=` lines; the config is checked
  with `dnsmasq --test` before use and rolled back if it fails.
- DHCP hands out the router as DNS: option 6 in the stock `dhcp.lan.dhcp_option`
  (the previous value is kept in `iot_dns_prev6` and restored when switched off),
  and the DNS servers are stripped from `/etc/dhcp6s.conf` for DHCPv6.
- TP-Link's "dnsproxy" DNATs LAN DNS for the router to the ISP's servers
  (`prerouting_rule_dns`), so names never resolved; ACCEPT rules at the top of that
  chain keep queries for the router on the router.
- **DNS over HTTPS** (`iot_dns_doh=1`): `helpers/doh.lua` listens on 127.0.0.1:5053 and
  POSTs each query (RFC 8484) to the provider over a pool of up to 3
  `openssl s_client` connections, which check the chain against `helpers/cacert.pem`
  and the name (`-verify 10 -verify_hostname <name> -verify_return_error`; without
  `-verify 10` this OpenSSL 1.0.2 reports a bad certificate and carries on). luasec
  0.4 on the router can't check names, hence s_client. Health-checked every pass
  (`doh.lua check`); `$RUN/doh.ok` decides whether dnsmasq uses it or the plain
  servers.

## Automatic speed limit

`iot_wan_auto=1` runs `helpers/autorate.lua` while the whole-connection limit is on.
Every second it reads the WAN counters and pings two of four reflectors (1.1.1.1,
8.8.8.8, 9.9.9.9, 1.0.0.1; 16-byte payload). The pings leave from the router itself,
out the WAN port, so they never pass through our queues (which sit on `br-lan` and
`ifb0`): they see the line.

- Full (over 90% of the limit) and delay normal: raise that direction 4% a second.
- Delay up by 15 ms or more (both reflectors agree): drop to just under what got
  through, hold 5 s.
- Raised but the traffic didn't follow and holds steady (this ISP polices instead of
  queueing, so no delay shows): that's the ceiling; sit 3% under it for a minute.
- Idle: drift back to the usual speed. Calm (under 20% both ways): ping every 10th
  second only.
- Rates change in place (`$RUN/rate.sh`, `tc class change`); nothing is rebuilt.
  Range `iot_wan_min_*`/`iot_wan_max_*` (default half to three times the usual).
  State in `$RUN/autorate.stat`; restarts carry on from it for a minute.
- The thresholds are first guesses; this line tops out around 35 Mbps.

## Data usage

`usage_sync` (every watcher pass, `iot_usage_on`, on by default):

- Totals per day and month from the WAN interface's counters: exact.
- Per device per month from two sources: devices on this router's Wi-Fi from
  `wl sta_info` (all their traffic, IPv6 included, plus traffic between devices at
  home); every other device (mesh satellite, cable) from TP-Link's `tfstats`
  (`ubus call tfstats get '{"page":0,"pagesize":200}'`, at most 200; `rx` is what the
  device received). tfstats counts IPv4 only, and only traffic that passes through
  Linux: complete while the whole-connection limit is on (it takes everything off
  the fast path), mostly missed when it is off. Its readings are taken every pass and
  added only for devices the radios don't list, so a device moving between router
  and satellite is not counted twice. What neither source sees shows as "not matched
  to a device".
- `$RUN/usage` (bytes), saved to flash every 4 hours in MB, as UCI lists with one
  entry each (`iot_usage_days`, `_months`, `_devs`: one long value would be cut at
  2465 characters by TP-Link's startup); 62 days, 24 months, devices for this month and
  the last. Not saved at the first reading after a start (flash holds that already). A
  reboot loses what came since the last save: `ax10.sh reboot` saves first (the
  dashboard's Reboot button uses it, falling back to TP-Link's reboot), and the watcher
  saves in the 5 minutes before TP-Link's own scheduled reboot (`autoreboot.reboot`,
  run by cron; here Mondays 03:00). (Four
  reboots in under 4 hours on 12 Nov lost that day's per-device figures this way.)
  `iot_usage_boot` vs `/proc/sys/kernel/random/boot_id` decides whether a first
  reading is new traffic (a new boot) or only a baseline.

## Router load

`load_guard` (every watcher pass) appends to `$RUN/load.log`: uptime, busy % (all
3 cores), softirq % (network processing), load average, WAN kbit/s down and up; 24
hours kept. Four passes in a row at 90% or more log one line with the busiest
processes (by name only: `pppd`'s command line holds the PPPoE login). The
dashboard's Internet tab shows it (`web/ax10.lua` form `load`). `ax10.sh load [n]` prints
the last readings. The whole-connection limit and device caps take traffic off the
hardware fast path, so the processor is where a busy router shows first. Typical:
20-30% busy at a few Mbps with the limit on.

## Boot from the saved copy

The boot hook starts a copy of `ax10.sh` saved in flash first, if its signature
verifies with the release key, so the home allow list and the IoT network are up
within seconds of every boot, with or without internet (before, the home Wi-Fi took
anyone with the password until the release had downloaded). The release is then the
update: the hook downloads `boot.sh` and retries every 30 s until it can; `boot.sh`
runs in full, saves the release's `ax10.sh` if it changed, and restarts on it.

- `ax10.sh boot` (`save_copy`, given the signature by `boot.sh` in `SAVE_COPY_SIG`)
  saves the copy whenever the release's `ax10.sh` changes, under the run lock, after
  stopping the watcher that was running (it may be an older version's):
  gzip + base64 (about 57 KB) as a UCI list `openvpn.archer_boot.cache_iot` in 1000
  character chunks (TP-Link's startup cuts list values to 2465 characters: 4000-character
  chunks came back short after a reboot and the copy failed verification), the release's own signature in `cache_iot_sig`, its md5 in
  `cache_iot_sum`. It refuses if the settings would pass ~90 KB, and reads the copy
  back before committing.
- `SAVED_COPY=1 ax10.sh boot` runs everything ax10.sh does by itself (IoT network, home
  allow list, speed limits at the usual speeds, local names with plain DNS, usage,
  load) and skips the web UI, DNS over HTTPS and the automatic limit, whose files come
  with the release.
- No SSH until the release downloads: the lifeline binary (`dropbear_vanilla`, 106 KB
  gzipped) doesn't fit, and the stock dropbear has a TP-Link MAC-based pre-auth lockout.
- The hook command lives in `openvpn.archer_boot.boot_cmd`; `scripts/signed-hook.sh
  update` rewrites it from the script (key kept). Tested in `tests/signing.sh`; the
  save/restore through TP-Link's own settings format was checked on the router (67 KB
  encrypted with the copy, of 128 KB).

## Packages at boot

`boot.sh` installs opkg and the packages in `openvpn.archer_boot.boot_pkgs` (e.g.
`ax10-busybox`; empty = none) after the IoT step. `install.sh` and its payload are
checked by signature; the package index (`Packages`) is signed in CI, and each `.ipk`
must match its SHA-256 there before `opkg install` runs on the local file (opkg's own
downloads use a wget that doesn't check certificates). The release pulls the latest
upstream opkg payload and packages on every build. ax10-debloat is not in our feed:
it stops `sync-server` (which copies Wi-Fi settings to the mesh satellite) and the
cloud services the Tether app uses.

## What we learned about this router

### Storage and persistence
- The root filesystem is read-only squashfs. `/etc` is **ramfs**, `/tmp` is
  tmpfs, and nothing in them survives a reboot.
- `uci commit` writes only to RAM. TP-Link's `/sbin/uci_commit_flash <config>`
  (its patched `luci.model.uci`; plain commit is `commit_without_write_flash`)
  writes the config to flash. That's how `openvpn.archer_boot.*` persists.
- Flash is one 16 MB chip (`nvrammanager -s` lists the partitions); the only one we
  write is `user-config` (128 KB). A save turns every file in `/etc/config` into one
  XML file (`luci.sys.config.convertFileToXml`), compresses and encrypts it
  (`luci.model.crypto.enc_file_entry`) and writes it with `nvrammanager -w`; boot
  reads it back the same way. About 26 KB is used by the settings alone. Something in
  TP-Link's startup cuts each UCI value (list items too) to **2465 characters** as the
  settings load; the XML conversion alone keeps longer ones, so a check in RAM passes and
  only a reboot shows it. Keep every saved value well under that (the SSH host key is
  565, the boot hook 1058). A save
  that fails would lose every setting, the boot hook included, so anything large
  is tried through that pipeline into `/tmp` first.
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

### Speed limits (dashboard: Internet, and Networks → Guest)
- Three optional caps, all applied by `ax10.sh shape` and kept in sync by the
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
  per Mbps, 20–127; the priority lane always 127 (at 90, a video call's bursts of
  frames were dropped).
- Guests come and go all day, and each one changes the per-device part (a guest's
  own cap, its filter into the guest lane). Rebuilding everything for that emptied
  every queue and restarted the automatic limit: in a load test during a Meet call,
  incoming video fell from about 2.3 to 0.8 Mbit/s after each rebuild, and the log
  showed 35 rebuilds in 2.6 hours. Now a device change only redoes the per-device
  part: `tc filter del ... prio 1` removes every device filter at once (the
  calls-and-games filters are at prio 2 and 3), then the classes 1:11 and up go
  (a class can't be deleted while a filter points at it), and they are added back.
  If any device class stays, everything is rebuilt as before.
- Kernel 4.1.52 queueing: `htb`, `sfq`, `prio` are present; `fq_codel`, `codel`,
  `cake`, `pie`, `fq`, `tbf`, `red`, `hfsc`, `drr`, `netem` are not. An earlier
  note here said `sfq` was missing; it isn't.
- The stock firmware has a hidden per-device limit (`smart_network?form=client_speed_limit`,
  `write` with `mac`, `enableLimit`, kbps limits; the UI hides it unless
  `supportSpeedLimit`). It accepts settings and enforces nothing on this unit.
- Live updates: one lock, `$RUN/run.lock`, is held by every `ax10.sh` command except
  `status`, by each watcher pass, and by the dashboard backend around its own settings
  writes. It's the kernel's `lockf` (through nixio): owned by one process, not passed
  to the daemons a run starts, and released the moment the holder exits or is killed,
  so nothing stale is ever left (tested on the router: across `exec`, after `kill -9`,
  and with a child outliving the holder). A shell can't hold `lockf` itself, so a
  command re-runs itself through `$RUN/lockrun.lua` (written by `ax10.sh`), which
  takes the lock and `exec`s the shell: same process, lock held until it exits.
  busybox's `flock` is unusable here (its lock is inherited by every daemon a run
  starts). The dashboard saves, then asks for `ax10.sh kick`: that leaves a note
  (`$RUN/sync.want`) and waits for the lock; whoever holds it applies notes until
  none is left, so a burst of changes is one or two passes and the last change always
  lands. The watcher holds `$RUN/watch.lock` for its lifetime (a second one stands
  down) and runs each pass as `ax10.sh pass`. An earlier version used Lamport bakery
  locks on ticket directories; most review findings were in deciding when those were
  stale.

### Device lists on the pages
- Rows show where a device is now (Wi-Fi SSID and band from `wl assoclist`,
  wired/mesh port from `brctl showmacs`, else ARP), mark the device viewing the
  page (`REMOTE_ADDR`), sort online first, and can be renamed (UCI list
  `iot_names`, `mac=name`). The stock grid's store sync sends only the first
  changed row, so list switches save immediately via `ev_grid_custom_change`.

### Dashboard at /
- One self-contained page, `web/dashboard.html`, built from `web/dashboard/`: `page.html`
  with `style.css` and `js/*.js` (joined in name order, one script) put in at its two
  markers. `ax10.sh ui` bind-mounts it over `/www/index.html` (what
  `https://192.168.0.1/` serves). Nothing else of TP-Link's UI is changed: plain-HTTP
  visits land on its own login, and it stays at `/webpages/index.html`. (Earlier
  versions added two pages, a menu entry, a theme and a login redirect to it;
  `ax10.sh ui` takes those down.) `ax10.sh ui-remove` undoes the mount.
- Tabs: Devices (every device with name, IP, where it is connected, live traffic;
  rename, cap, block, forget), Networks (Home with the allow list, Guest with its
  limits and join-home page, IoT), Internet (connection, data used, the
  whole-connection limit, capped devices, router load, local names). Light by
  default with a dark theme. It refreshes every 10 s while visible.
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
- **Backend:** `web/ax10.lua` (LuCI controller at `/admin/ax10`) forms `devices` (one list with every DHCP lease, the
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
- Links to TP-Link's settings open `/webpages/index.html` (its home page: the stock
  UI ignores URL fragments, so it can't be opened on a given page).

### Mesh satellite (Archer C6, EasyMesh)
- It joins over `wl1.2` (hidden backhaul) and appears as `wds1.2.1` in `br-lan`;
  its clients keep their own MACs (4-address frames), so the raw-table MAC drop
  catches them. The mesh doesn't carry a separate guest network
  (`meshd.primvlanid=0`) and the C6 broadcasts only the home SSID.
- TP-Link's Access Control does not reach it, in either mode. Tested: with the allow
  list on (in RAM, then restored), an unknown device joined the C6 two minutes
  later and stayed. The stock page only saves and runs
  `/etc/init.d/access_control reload` locally. TP-Link staff describe syncing
  features to satellites as future work.
- `/tmp/easymesh_client_list` (written by `easymesh-controller`) lists the C6's
  stations with signal and rates, no byte counters.

### Device-to-device isolation (tested in a separate experiment)
- `wl ap_isolate 1` on a home radio blocks all client-to-client traffic on that
  radio, allowed devices included: Broadcom's `should_deliver()` drops a frame whose
  in and out port are the same before it looks at `hairpin_mode`.
- ebtables can be built for this kernel (TP-Link GCC 5.5, MAP off, `sk_buff` padding,
  sockopt base moved to 0x1E00) and filters per MAC between ports (Wi-Fi to
  satellite, wired, other band); not between two clients of one radio. The recipe is
  in the separate toolchain folder, not in this repo.
- The Wi-Fi driver offers no AP/VLAN interfaces, so per-password VLANs on one SSID
  (hostapd `sae_password=...|vlanid=`) are not possible.

### busybox 1.19 and other shell traps
- `sh -n -c "<cmd>"` **runs** the command (only `sh -n <file>` parses without running).
- No `fold`, `paste`, `diff`; `grep` has no `-x`; `tar` warns on macOS extended headers
  (`tar --no-xattrs` or ignore).
- `$( ... case x in a) ... esac ... )`: the pattern's `)` ends the substitution in some
  shells; use `if` inside command substitutions.
- Arithmetic is 64-bit, so byte counters are fine.
- `ps w` shows full command lines, and `pppd`'s holds the PPPoE login: filter it out
  of anything printed or logged.

### Known trade-offs
- While the IoT network runs, OneMesh onboarding of a **new** satellite over
  2.4 GHz won't work (its config slot is in use). Existing satellites use
  `wl1.2`/`wl0.2` and are unaffected.
- When TP-Link restarts Wi-Fi, it resets `wl1.4`'s SSID and its `br-filter`
  entry. The watcher repairs both within about 15 s. The mesh flags stay cleared
  thanks to the patched Wi-Fi script.
