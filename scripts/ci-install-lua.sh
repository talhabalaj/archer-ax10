#!/bin/sh
# Install Lua 5.1 (the router's Lua version): its compiler for the syntax checks in
# tests/run.sh, and the interpreter for tests/doh_parse.lua. It comes from Debian's package servers, in a container: Ubuntu's were
# unreachable from GitHub's runners on 2026-11-11 (Canonical outage), which blocked
# releases. Debian's luac5.1 needs only libc and libm, so the binary runs on the host.
set -e
docker run --rm -v /usr/local/bin:/out debian:bookworm-slim sh -c '
    apt-get update -qq && apt-get install -y -qq lua5.1 >/dev/null
    cp /usr/bin/luac5.1 /usr/bin/lua5.1 /out/
    cp -L /usr/lib/*/liblua5.1.so.0 /out/ 2>/dev/null || true'
luac5.1 -v
# The interpreter is linked against liblua5.1.so.0; make it findable if it came along.
[ -f /usr/local/bin/liblua5.1.so.0 ] && { sudo cp /usr/local/bin/liblua5.1.so.0 /usr/local/lib/ && sudo ldconfig; }
lua5.1 -v
