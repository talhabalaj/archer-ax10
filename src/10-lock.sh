# ==== src/10-lock.sh: the run lock, pid files
# One lock around everything that changes the router or the saved settings: every
# ax10.sh command but `status`, every watcher pass, and the dashboard's own settings
# writes (web/ax10.lua takes the same lock). Without it, interleaved rebuilds leave
# rules in the wrong order, and two writers of one list lose each other's change.
#
# It is the kernel's lock (lockf, through nixio): it belongs to one process, is not
# passed on to the daemons a run starts, and is let go the moment its holder exits or
# is killed, so there is nothing stale to detect or take over. (busybox's flock is
# the other kind: its lock is inherited by every daemon a run starts and never let go.
# Earlier versions built a lock from directories instead, and most of the bugs found
# in review were in deciding when such a lock was stale.)
#
# A shell can't hold a lockf lock itself. So a command that needs it runs itself again
# through $RUN/lockrun.lua, which takes the lock and then execs the shell: the same
# process, so the lock stays held until that command exits. AX10_LOCKED names the lock
# and the process holding it, so the re-run knows it is the holder (and its children,
# with other pids, don't think they are).
RUNLOCK="$RUN/run.lock"
LOCK_WAIT="${LOCK_WAIT:-60}"
lockrun_write() {   # $RUN/lockrun.lua: in ax10.sh, so it works without the web UI's files
    # Written aside under a name of our own, checked, then renamed into place: callers
    # run this before they hold any lock, so two at once must never share a temp file
    # (one truncating it while the other renames it would publish an empty launcher,
    # which Lua runs happily: no lock taken, nothing run, exit 0).
    mkdir -p "$RUN"; lw_t="$RUN/.lockrun.lua.$$"
    cat > "$lw_t" <<'LUA'
-- lockrun.lua <lock file> <seconds> <program> [args...]   (written by ax10.sh)
-- Take the kernel lock on <lock file> (lockf), waiting up to <seconds> (0: try once),
-- then exec <program> in this same process, so it holds the lock until it exits.
-- Lock busy until the end: exit 75, after AX10_BUSY_SLEEP seconds if that is set.
local nixio = require "nixio"
local f = nixio.open(arg[1], "w")
if not f then io.stderr:write("ax10.sh: can't open " .. tostring(arg[1]) .. "\n"); os.exit(1) end
local deadline = os.time() + (tonumber(arg[2]) or 0)
while not f:lock("tlock") do
    if os.time() >= deadline then
        io.stderr:write("ax10.sh: another run is in progress; try again\n")
        local s = tonumber(os.getenv("AX10_BUSY_SLEEP") or "")
        if s then nixio.nanosleep(s, 0) end
        os.exit(75)
    end
    nixio.nanosleep(0, 200000000)
end
nixio.exec(arg[3], unpack(arg, 4))
io.stderr:write("ax10.sh: can't run " .. tostring(arg[3]) .. "\n")
os.exit(127)
LUA
    grep -q '^nixio.exec(arg\[3\]' "$lw_t" 2>/dev/null || { rm -f "$lw_t"; return 1; }
    if cmp -s "$lw_t" "$RUN/lockrun.lua" 2>/dev/null; then rm -f "$lw_t"; else mv -f "$lw_t" "$RUN/lockrun.lua" || { rm -f "$lw_t"; return 1; }; fi
}
holds() { [ "$AX10_LOCKED" = "$1:$$" ]; }   # holds <lock file>: does this process hold it?
# with_lock <lock file> <seconds to wait, 0 = try once> <ax10.sh args...>: run ax10.sh
# again with these args, holding the lock. Does not return: the process becomes that
# run, and exits with its status (75 if the lock stayed busy).
with_lock() {
    wl_f="$1"; wl_w="$2"; shift 2
    export AX10_LOCKED="$wl_f:$$"
    # LOCKRUN: a stand-in for lockrun.lua where there is no nixio (the offline tests)
    if [ -n "$LOCKRUN" ]; then exec $LOCKRUN "$wl_f" "$wl_w" /bin/sh "$0" "$@"; fi
    lockrun_write || { echo "ax10.sh: can't write $RUN/lockrun.lua" >&2; exit 1; }
    exec "$LUA" "$RUN/lockrun.lua" "$wl_f" "$wl_w" /bin/sh "$0" "$@"
}
# A process's start time (/proc/<pid>/stat field 22), so a recycled pid is never
# taken for the process that had it before. Empty where there is no /proc.
lock_start() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
# Pid files for the helpers we start (join page, DNS over HTTPS, automatic limit):
# the pid plus its start time. A file holding only a pid was written by an old
# version (still running across an upgrade without a reboot): then the process counts
# as ours if its command line contains <hint>, so it is stopped and not left holding
# its port.
# Is the IoT network meant to be up? The setting says so, unless `ax10.sh stop` took it
# down by hand ($RUN/iot.stopped): then it stays down until `start` or a reboot, even
# though the watcher keeps running for the features that don't depend on it.
iot_on() { [ "$(cfg enabled 0)" = 1 ] && [ ! -e "$RUN/iot.stopped" ]; }
pid_save() { echo "$2 $(lock_start "$2")" > "$1"; }                # pid_save <file> <pid>
pid_live() {                                                       # pid_live <file> [hint]
    pl_hint="$2"; set -- $(cat "$1" 2>/dev/null)
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
    if [ -n "$2" ]; then [ "$2" = "$(lock_start "$1")" ]; return; fi
    [ -z "$(lock_start "$1")" ] && return 0                        # no /proc here: the pid is all there is
    [ -n "$pl_hint" ] && tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q -- "$pl_hint"
}
pid_kill() { pid_live "$1" "$2" && kill "$(cut -d' ' -f1 "$1")" 2>/dev/null; rm -f "$1"; }   # pid_kill <file> [hint]

bridge_of() { m="$(readlink "$NET/$1/brport/bridge" 2>/dev/null)"; echo "${m##*/}"; }
