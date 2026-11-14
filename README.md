# archer-ax10 (personal fork)

Add-ons for a **TP-Link Archer AX10** on its stock firmware: nothing is reflashed. The
router's root filesystem is read-only and everything else is RAM, so the add-ons are
started again at every boot by a hook saved in the router's settings, and come from the
signed releases of this repo.

## What it adds

- **Isolated IoT Wi-Fi**: its own hidden network, subnet and firewall; devices pinned and
  locked; internet per device.
- **Home allow list**: only listed devices join the home Wi-Fi (also through the mesh
  satellite and on cables); a join page on the guest Wi-Fi helps listed devices move over.
- **Speed limits**: per device, for guests, and for the whole connection, fixed or
  automatic (follows the line); calls and games first, guests last.
- **Local names and DNS over HTTPS**: `<device>.home`, encrypted upstream DNS.
- **Data usage** per day, month and device, and a **router load** watcher.
- **Dashboard** at `https://192.168.0.1/` (the stock UI stays at `/webpages/index.html`).

## How a boot works

```
hook in the router's settings (OpenVPN "up", the one thing that persists)
  ├─ starts the signed copy of ax10.sh saved in flash: allow list, IoT network,
  │  limits and names are up within seconds, with or without internet
  └─ downloads boot.sh from the latest release (signature checked), which
       ├─ mirrors the web-UI admin password to root and starts SSH on :2222
       ├─ downloads ax10.sh aside (checked), which installs itself, takes over,
       │  installs the dashboard and saves itself as the copy in flash
       └─ installs opkg and the packages in boot_pkgs (each checked)
```

Every download is checked against the release key saved on the router
(`scripts/signed-hook.sh`).

## Repository

| Path | What |
| --- | --- |
| `src/*.sh` | Everything on the router, one file per job; `scripts/build.sh` joins them into `ax10.sh` |
| `src/extra/*.sh` | The parts that wait for the downloaded files (speaker relay, usage, load, MQTT alerts): built into `extra.sh` in `ax10-files.tar.gz`, loaded by `ax10.sh` |
| `web/` | The dashboard (source in `web/dashboard/`, built into one page) and its LuCI backend `web/ax10.lua` |
| `helpers/` | DNS-over-HTTPS forwarder, automatic speed limit, CA certificates |
| `boot.sh` | What the hook runs once the release downloads |
| `scripts/signed-hook.sh` | Writes the boot hook into the router's settings |
| `install.sh`, `index.sh`, `bootstrap/` | opkg installer, feed index, SSH lifeline binary |
| `tests/` | `sh tests/run.sh` runs everything offline |
| `.github/workflows/` | Tests on every push; `build-feed.yml` builds and signs a release |

The optional opkg packages (`ax10-busybox`, `ax10-dropbear`, `ax10-luci`, `ax10-svc`,
`ax10-wifi`) are built in their upstream repos; the release collects their `.ipk`s and
signs the index.

## Docs

- [IOT_NETWORK.md](IOT_NETWORK.md): every feature, and what we learned about the router
- [ROUTER_SETUP.md](ROUTER_SETUP.md): the boot hook, SSH and release setup
- [AGENTS.md](AGENTS.md): how to work on this repo (tests, trying changes, releases)

## Password

The stock firmware has no root password, so `boot.sh` sets one for SSH by **mirroring the
router's own web-UI admin password**: TP-Link stores it encrypted in
`/etc/config/accountmgnt`, and the firmware's own routine
(`luci.model.accountmgnt.get_localPassword`) decrypts it; it is hashed straight into
`/etc/shadow`. Change it in the web UI and SSH follows at the next boot. A hash of the
default `admin` is the only fallback, used if that routine fails.

## Upstream and license

Based on [lee-soft/archer-ax10](https://github.com/lee-soft/archer-ax10) (boot hook,
opkg feed, packages); rooting groundwork by
[Waujito/TPLlAX1500GPL](https://github.com/Waujito/TPLlAX1500GPL).
MIT for this project's own code (see LICENSE); third-party binaries keep their own
licenses (see THIRD-PARTY.md).
