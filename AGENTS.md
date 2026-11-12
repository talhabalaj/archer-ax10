# Working on this repo

Add-ons for a TP-Link Archer AX10 on its **stock firmware**. Nothing is flashed: the
router's root filesystem is read-only and everything in RAM is gone after a reboot.
A boot hook saved in the router's settings first starts the copy of `ax10.sh` saved
there, then downloads `boot.sh` from the latest GitHub release, checks its signature,
and runs it (the release is the update). `boot.sh` starts an SSH lifeline
and `ax10.sh`, which runs everything else. Read `IOT_NETWORK.md` for what each feature
does and what we learned about the router; this file is about how to work.

## Map

| Path | What |
| --- | --- |
| `src/*.sh` | Everything on the router, one file per job (IoT network, home allow list, join-home page, devices, names + DNS over HTTPS, speed limits, usage, load, UI install, guards, status, the watcher, commands). `scripts/build.sh` joins them, in name order, into `ax10.sh`. |
| `ax10.sh` | **Built, not edited, not tracked.** The single file that is deployed (`/tmp/ax10.sh`), released, saved in flash and tested. `tests/run.sh` builds it first. |
| `web/ax10.lua` | LuCI controller: the dashboard's backend (`/admin/ax10?form=...`). |
| `web/dashboard/` | The dashboard's source: `page.html`, `style.css`, `js/*.js`; built into one self-contained `web/dashboard.html`. |
| `helpers/` | DNS-over-HTTPS forwarder, automatic speed limit, CA certificates. |
| `build/` | **Built, not tracked**: `ax10-files/` is what the router downloads as `ax10-files.tar.gz`. |
| `boot.sh` | Run at every boot by the hook once the release downloads: root password, SSH lifeline on :2222, saves the copy of `ax10.sh` in flash, `ax10.sh boot`, packages. |
| `scripts/signed-hook.sh` | Writes the boot hook into the router's settings (`install`, `update`, `revert`). |
| `install.sh`, `index.sh`, `bootstrap/` | opkg's installer, the feed index builder, the SSH lifeline binary. The packages themselves are built upstream (github.com/lee-soft/ax10-*); the release workflow downloads their `.ipk`s. |
| `tests/` | `run.sh` runs everything: shell syntax, Lua syntax and LuCI-name check, `doh_parse.lua`, `ax10.sh` (offline, with stubs), `signing.sh` (the boot chain). |
| `.github/workflows/build-feed.yml` | The release: runs the tests, builds the feed, signs the boot files, publishes `vNN-personal`. |

Settings are UCI options `openvpn.archer_boot.*` (`iot_*` for ax10.sh), saved to
flash with `uci_commit_flash`. Runtime state is in `/tmp/ax10-iot` (`$RUN`), with
the log at `$RUN/iot.log`.

## Feedback loops, fastest first

1. **Offline tests:** `sh tests/run.sh` (needs a Lua compiler, `luac5.1` or `luac`,
   and `node`; locally it skips the Lua checks if none is found, CI fails instead). Every behaviour change gets a test in `tests/ax10.sh` or `tests/signing.sh`.
   macOS has no `/proc`, so some code paths differ from Linux: before a release, also
   run the suite in a Linux container, as CI does:
   `docker run --rm -v "$PWD":/src:ro ubuntu:24.04 sh -c 'apt-get update -qq && apt-get install -y -qq lua5.1 nodejs openssl procps gawk curl >/dev/null; cp -r /src /w && cd /w && sh tests/run.sh'`
2. **On the router, from the working tree** (no release needed): run
   `sh scripts/build.sh`, then copy `ax10.sh` and
   the contents of `build/ax10-files/` over SSH (port 2222), put those in
   `/tmp/ax10-iot/files/`, then run `sh <new ax10.sh> ui`. That copies itself to
   `/tmp/ax10.sh`, installs the UI and restarts the watcher. Then check health: one
   `ax10.sh watch` process, `ax10.sh status`, `ax10.sh home`, `tail $RUN/iot.log`, the
   dashboard loads, and names resolve if they're on. What runs from RAM is gone after
   a reboot, so the router goes back to the last release.
3. **Release:** commit on `main`, push, `gh workflow run build-feed.yml -f tag=vNN-personal`,
   wait for it, then download `ax10.sh` and `ax10-files.tar.gz` from the release and
   compare them with the commit. Only release when asked.
4. **Review:** larger changes get an independent review before release (another
   model, with the diff and what was already fixed). Fix findings with tests, then
   say what is left.

## Rules that come from incidents

- **Flash is the dangerous part.** The router keeps one 128 KB settings partition,
  holding every setting including the boot hook. A failed save loses all of it, and
  with it our way back in. Before writing anything large, run it through TP-Link's
  save pipeline into `/tmp` (see `IOT_NETWORK.md`, Storage). Change the boot hook only
  through `scripts/signed-hook.sh`, after its tests pass. Ask before any flash or
  hook change the task didn't clearly call for.
- **busybox `sh -n -c` runs the command.** Parse-check a script with `sh -n <file>`.
- **LuCI caches controller code.** A file-level `local` named `entry`, `call`, `node`,
  `alias` or `assign` in `web/ax10.lua` shadows LuCI's own and breaks every page
  (`tests/run.sh` checks this).
- **Secrets stay out of output.** `ps w` shows `pppd`'s command line, which holds the
  PPPoE login: never print or log it unfiltered. Never print the router password or
  key material. Keep device names, MACs and other personal details out of commits,
  docs and anything sent to outside services; this repo is public.
- **Don't fight the watcher.** It re-applies every 15 s. Change behaviour through
  `ax10.sh` and settings, not by hand on the router, or it will undo you.
- **One lock for every writer.** Every `ax10.sh` command but `status` holds the run
  lock (the kernel's `lockf`, see `src/10-lock.sh`); so does each watcher pass and the
  dashboard backend around its own settings writes (`locked()` in `web/ax10.lua`).
  Never call an `ax10.sh` command from inside `locked()`: it would wait for the lock
  its caller holds. The dashboard saves, then calls `ax10.sh kick`.
- **Test against the real router before claiming something works there**, and say
  what wasn't tested (for example, a reboot without internet).
- TP-Link undoes things: Wi-Fi restarts reset slot settings, the firewall reloads
  drop chains. Code that adds state must survive being undone, and the watcher puts
  it back.

## Style

- New code goes in the `src/` file for its job; a file only holds top-level variable
  assignments and function definitions (the commands run from `99-main.sh`, last), so
  files can be reordered or split without changing behaviour.
- Shell is POSIX `sh` that also runs on busybox 1.19 ash: no bashisms, no `flock`,
  no `fold`/`paste`/`diff`, no `grep -x`. 64-bit arithmetic is available.
- Comments explain *why*, in plain sentences, next to the code they explain.
- The dashboard is deployed as one file but edited in parts (`web/dashboard/`): new
  code goes in the `js/` file for its page, and the build joins them in name order
  into one script (a name declared twice fails the JS check). Use its tokens (`--signal`, `--warn`, `--bad`, ...)
  and check JS with `node -e "new Function(...)"` or the test suite. Apostrophes inside
  single-quoted JS strings need `&rsquo;`.
- User-facing text (dashboard, log lines) says what happened and what to do, without
  jargon.
