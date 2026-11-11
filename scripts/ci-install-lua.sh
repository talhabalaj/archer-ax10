#!/bin/sh
# Install Lua 5.1's compiler (the router's Lua version) for the syntax check in
# tests/run.sh. It comes from Debian's package servers, in a container: Ubuntu's were
# unreachable from GitHub's runners on 2026-11-11 (Canonical outage), which blocked
# releases. Debian's luac5.1 needs only libc and libm, so the binary runs on the host.
set -e
docker run --rm -v /usr/local/bin:/out debian:bookworm-slim sh -c '
    apt-get update -qq && apt-get install -y -qq lua5.1 >/dev/null
    cp /usr/bin/luac5.1 /out/'
luac5.1 -v
