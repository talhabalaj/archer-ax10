#!/bin/sh
# Join src/*.sh, in name order, into ax10.sh: the one file that is deployed to the
# router, released, saved in flash and tested. Edit src/, never ax10.sh.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/ax10.sh}"
{
    head -n 1 "$ROOT/src/00-core.sh"
    echo "# Built from src/ by scripts/build.sh: edit those files, not this one."
    tail -n +2 "$ROOT/src/00-core.sh"
    for f in "$ROOT"/src/*.sh; do
        [ "${f##*/}" = 00-core.sh ] && continue
        echo
        cat "$f"
    done
} > "$OUT.tmp"
sh -n "$OUT.tmp"
chmod 755 "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

# The files the router downloads next to ax10.sh (ax10-files.tar.gz), in build/ax10-files:
#   web/dashboard.html   web/dashboard/page.html with style.css and js/*.js (name order)
#                        put in at its two markers: one self-contained page
#   web/ax10.lua         the dashboard's backend (a LuCI controller)
#   helpers/             DNS over HTTPS, the automatic speed limit, CA certificates
F="$ROOT/build/ax10-files"
rm -rf "$F.tmp"; mkdir -p "$F.tmp/web" "$F.tmp/helpers"
while IFS= read -r line; do
    case "$line" in
        "/* @@style */") cat "$ROOT/web/dashboard/style.css" ;;
        "/* @@app */") cat "$ROOT"/web/dashboard/js/*.js ;;
        *) printf '%s\n' "$line" ;;
    esac
done < "$ROOT/web/dashboard/page.html" > "$F.tmp/web/dashboard.html"
cp "$ROOT/web/ax10.lua" "$F.tmp/web/ax10.lua"
cp "$ROOT"/helpers/* "$F.tmp/helpers/"
rm -rf "$F"; mv "$F.tmp" "$F"
