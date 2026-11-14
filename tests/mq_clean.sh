#!/bin/sh
# Tests mq_clean (src/65-alerts.sh), the function that makes device names safe inside the
# JSON of an alert: quotes, backslashes and control characters out, and a cut at a byte
# limit never splitting a UTF-8 character. Run: sh tests/mq_clean.sh
set -e
cd "$(dirname "$0")/.."
sh scripts/build.sh >/dev/null
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
{ sed -n '/^mq_clean() {/,/^}/p' build/ax10-files/extra.sh; grep '^has_line() ' ax10.sh; } > "$T/f.sh"
. "$T/f.sh"
fails=0
t() { got="$(printf '%s' "$2" | mq_clean "$3")"; [ "$got" = "$4" ] || { echo "FAIL: $1: got [$got] want [$4]"; fails=$((fails + 1)); }; }
t "plain name" "Phone" 60 "Phone"
t "quote, backslash, tab, escape, newline out" "$(printf 'a"b\\c\td\033e\nf')" 60 "abcdef"
t "cut inside a 2-byte character" "$(printf 'abc\303\251z')" 4 "abc"
t "cut right after a 2-byte character" "$(printf 'ab\303\251z')" 4 "$(printf 'ab\303\251')"
t "cut inside a 3-byte character" "$(printf 'ab\342\202\254z')" 4 "ab"
t "cut right after a 3-byte character" "$(printf 'a\342\202\254z')" 4 "$(printf 'a\342\202\254')"
t "cut inside a 4-byte character" "$(printf 'a\360\237\230\200z')" 3 "a"
t "short enough: kept whole" "$(printf 'caf\303\251')" 60 "$(printf 'caf\303\251')"
t "default limit 60" "$(printf '%070d' 0)" "" "$(printf '%060d' 0)"
# has_line: an exact line, backslashes and dots taken literally.
printf '%s\n' 'x\ny' 'wl0.1' 'ax10/internet	ON' > "$T/lines"
has_line "$T/lines" 'x\ny' || { echo "FAIL: has_line: a backslash line not found"; fails=$((fails + 1)); }
has_line "$T/lines" 'wl0.1' || { echo "FAIL: has_line: plain line not found"; fails=$((fails + 1)); }
has_line "$T/lines" 'wl0x1' && { echo "FAIL: has_line: a dot matched any character"; fails=$((fails + 1)); }
has_line "$T/lines" 'wl0' && { echo "FAIL: has_line: part of a line matched"; fails=$((fails + 1)); }
has_line "$T/lines" "$(printf 'ax10/internet\tON')" || { echo "FAIL: has_line: a line with a tab not found"; fails=$((fails + 1)); }
has_line "$T/missing" 'x' && { echo "FAIL: has_line: a missing file matched"; fails=$((fails + 1)); }
[ "$fails" = 0 ] || exit 1
echo "mq_clean and has_line tests passed"
