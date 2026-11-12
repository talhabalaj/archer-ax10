# Personal AX10 boot setup

This fork follows the SSH-first setup at https://archer-boot.pages.dev/.

`boot.sh` mirrors the TP-Link web-GUI admin password and starts SSH on port
2222. It binds to the router's LAN address and allows the LAN bridge, so a
client's DHCP address can change. It then starts `ax10.sh` (see
[IOT_NETWORK.md](IOT_NETWORK.md)), saves a copy of it in flash (the hook starts that
copy first at every boot, before anything is downloaded), and installs the packages listed in `openvpn.archer_boot.boot_pkgs`
(none unless set; see "Packages at boot" in IOT_NETWORK.md). The upstream password
fallback behavior is retained.

A separate, loopback-only OpenVPN instance with interface and route configuration disabled supplies the persistent
`up` hook. Its hook waits for network access, downloads this repository's boot
script, and runs it. The normal OpenVPN server configuration is retained.

The SSH host key is saved only in `openvpn.archer_boot.host_key` on the router.
No passwords, SSH private keys, or router configuration backups belong in this
repository. The hook restores the SSH host identity after each reboot.

Release assets and the opkg feed are hosted here:

```
https://github.com/talhabalaj/archer-ax10/releases/latest/download
```

Install the package manager separately on the rooted router:

```sh
curl -4Lk https://github.com/talhabalaj/archer-ax10/releases/latest/download/install.sh | sh
```

`install.sh` checks the release signature of the files it downloads whenever
the boot hook has left the release key at `/tmp/archer-sign.pub`. To check
`install.sh` itself as well, download it with its signature and verify before
running:

```sh
B=https://github.com/talhabalaj/archer-ax10/releases/latest/download
curl -4Lk -o /tmp/install.sh "$B/install.sh" && curl -4Lk -o /tmp/install.sh.sig "$B/install.sh.sig" &&
openssl dgst -sha256 -verify /tmp/archer-sign.pub -signature /tmp/install.sh.sig /tmp/install.sh &&
sh /tmp/install.sh
```

LuCI remains a separate package choice, as on the upstream site. ax10-debloat is
not in this feed: it stops services the mesh satellite and the Tether app need.

The personal feed patches LuCI's Wi-Fi client tables for the stock AX10
`iwinfo` response: flat `rx_rate` / `tx_rate` fields are normalized before
rendering, and unavailable rate or channel-width data is displayed without
inventing values. This fixes `Cannot read properties of undefined (reading
'rate')` on the status and wireless pages. The personal LuCI asset version
also prevents browsers from reusing the old JavaScript after an upgrade.
The feed build runs
`node tests/luci-rates.cjs` against the patched package before publishing.

Modern LuCI uses its own `/etc/config/luci_personal` configuration and
`/tmp/luci-personal-modulecache` compiled modules. The package does not
replace the TP-Link GUI's LuCI configuration or share its module cache.
On this stock firmware, the LED driver has no standard kernel trigger
interface; LuCI displays a notice directing LED settings to the TP-Link
interface instead of throwing a JavaScript error. Package checks also
cover this limitation and the separation of the two GUIs.

The OpenVPN hook and SSH availability must be verified after an actual reboot.

Upstream: https://github.com/lee-soft/archer-ax10. Rooting groundwork:
https://github.com/Waujito/TPLlAX1500GPL. Upstream package sources and licenses
are listed in `THIRD-PARTY.md`; the packages' source and build recipes live in the
upstream repos (github.com/lee-soft/ax10-busybox, ax10-dropbear, ax10-luci,
ax10-svc, ax10-wifi, ax10-opkg, newstack).

Isolated IoT Wi-Fi network (separate SSID, own subnet, firewalled, set up on the
dashboard): see [IOT_NETWORK.md](IOT_NETWORK.md), which also records what we
learned about the router internals along the way.
