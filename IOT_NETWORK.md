# Isolated IoT Wi-Fi on the stock AX10 firmware

`iot.sh` adds a separate 2.4 GHz Wi-Fi network for smart devices (the inverter's
Wi-Fi logger, cameras) to the stock TP-Link firmware, with a settings page in the
stock web UI. It needs no reflash and no opkg: `boot.sh` fetches it each boot.

Status (2026-11-10): tested live with an iPhone, an Apple Watch and the inverter
logger. A reboot test through the published release has not been run yet.

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
| IoT → internet | allowed, except MACs in `iot_noinet` |

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

### Known trade-offs
- While the IoT network runs, OneMesh onboarding of a **new** satellite over
  2.4 GHz won't work (its config slot is in use). Existing satellites use
  `wl1.2`/`wl0.2` and are unaffected.
- When TP-Link restarts Wi-Fi, it resets `wl1.4`'s SSID and its `br-filter`
  entry. The watcher repairs both within about 15 s. The mesh flags stay cleared
  thanks to the patched Wi-Fi script.
