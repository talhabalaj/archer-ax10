# Personal AX10 boot setup

This fork follows the SSH-first setup at https://archer-boot.pages.dev/.

`boot.sh` mirrors the TP-Link web-GUI admin password and starts SSH on port
2222. It binds to the router's LAN address and allows the LAN bridge, so a
client's DHCP address can change. It does not install packages or debloat the
router. The upstream password fallback behavior is retained.

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

LuCI and debloat remain separate package choices, as on the upstream site.

The OpenVPN hook and SSH availability must be verified after an actual reboot.

Upstream: https://github.com/lee-soft/archer-ax10. Rooting groundwork:
https://github.com/Waujito/TPLlAX1500GPL. Upstream package sources and licenses
are preserved in the submodules and `THIRD-PARTY.md`.
