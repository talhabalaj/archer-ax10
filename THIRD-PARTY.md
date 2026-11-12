# Third-party components

This project's own scripts, packaging, and build tooling are MIT-licensed (see LICENSE).
It distributes and/or builds several third-party components that remain under **their own
upstream licenses**. Nothing here relicenses them.

| Component | Used in | Upstream | License |
|---|---|---|---|
| BusyBox 1.31 (static) | `ax10-busybox`, boot bootstrap | https://busybox.net | GPL-2.0-only |
| Dropbear SSH | `ax10-dropbear`, boot lifeline | https://matt.ucc.asn.au/dropbear/ | MIT-style (see dropbear LICENSE) |
| rpcd (+ mod-luci) | `ax10-luci` | https://github.com/openwrt/rpcd | ISC |
| uhttpd | `ax10-luci` | https://github.com/openwrt/uhttpd | ISC |
| libubox / ubus | `ax10-luci` | https://git.openwrt.org | ISC |
| cgi-io | `ax10-luci` | https://github.com/openwrt/cgi-io | ISC |
| lucihttp | `ax10-luci` | https://github.com/jow-/lucihttp | ISC / Apache-2.0 |
| json-c 0.13 | `ax10-luci` | https://github.com/json-c/json-c | MIT |
| LuCI (Lua + web UI) | `ax10-luci` | https://github.com/openwrt/luci | Apache-2.0 |
| Entware opkg + loader | boot bootstrap (`opt.tar.gz`) | https://github.com/Entware/Entware | GPL-2.0 / various |

Prebuilt binaries attached to Releases are provided as a convenience. This repo builds none of
them: the packages are built in their upstream repos (github.com/lee-soft/ax10-busybox,
ax10-dropbear, ax10-luci, ax10-svc, ax10-wifi, ax10-opkg), each with its `build/` directory,
using the shared glibc cross toolchain in github.com/lee-soft/newstack (GCC, binutils, glibc:
GPL-3.0 / LGPL-2.1). The corresponding sources are referenced above and pinned in those recipes.

If you redistribute the GPL components (BusyBox, Entware, the toolchain), honour their source
requirements — links to the exact upstream versions are above and pinned in the build recipes.
