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
