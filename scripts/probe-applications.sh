#!/usr/bin/env bash
# Enumerate Blizzard's legacy /applications/ tree by asking for piece 0 of each candidate.
#
# Every payload is served as numbered piece files, so "<base>/0" existing is the same question as
# "is there a payload here" - and it costs 262 KB at most, or nothing with a range request.
#
# The catch: rogue.blizzard.com.edgesuite.net sits behind an Akamai rule keyed on the CLIENT.
# From a machine where the Blizzard Downloader itself works, this works. From anywhere else every
# path returns 403, including "/", and no header changes that. Run this there, not here.
#
#   ./probe-applications.sh                 # the known-good set, as a self-test
#   ./probe-applications.sh --wide          # also sweep versions and apps we have not seen
#   ./probe-applications.sh --out found.tsv
set -u

HOST="${HOST:-rogue.blizzard.com.edgesuite.net}"
UA="Blizzard Web Client"
OUT=""; WIDE=0; DELAY="${DELAY:-0.25}"
while [ $# -gt 0 ]; do
  case "$1" in
    --wide) WIDE=1 ;;
    --out) shift; OUT="$1" ;;
    --host) shift; HOST="$1" ;;
    *) echo "usage: $0 [--wide] [--out file.tsv] [--host h]" >&2; exit 2 ;;
  esac; shift
done

# Confirmed live, from the torrents embedded in the getLegacy stubs.
KNOWN="
Diablo2/1.14B/D2
Diablo2/1.14B/LOD
StarCraft/1.15.2/Combo
Warcraft3/1.27a2/ROC
Warcraft3/1.27a2/TFT
"
# Shapes worth trying if you want to go looking. Version strings follow the observed style:
# Diablo2 uses 1.14B (upper), Warcraft3 uses 1.27a2 (lower + a build suffix).
WIDE_APPS="Diablo2 StarCraft Warcraft3 Warcraft2 Diablo Hellfire WorldofWarcraft Diablo3 Hearthstone"
WIDE_D2VERS="1.14B 1.14A 1.13D 1.13C 1.12A 1.11B 1.11"
WIDE_SCVERS="1.15.2 1.16.1 1.15.1 1.15 1.14"
WIDE_W3VERS="1.27a2 1.27a 1.27b 1.26a 1.28 1.29"
LOCALES="enUS enGB deDE esES esMX frFR itIT jaJP koKR plPL ptBR ruRU zhCN zhTW enUS-2"

hit() { # base
  code=$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 --max-time 20 \
         -A "$UA" -H 'Pragma: no-cache' "http://$HOST/applications/$1/0")
  echo "$code"
}

report() { printf "  %-4s %s\n" "$1" "$2"; [ -n "$OUT" ] && printf "%s\t%s\n" "$1" "$2" >> "$OUT"; }

[ -n "$OUT" ] && : > "$OUT"

echo "=== known-good set (if these are not 200, you are on a blocked network) ==="
ok=0
for k in $KNOWN; do
  for l in enUS enUS-2; do
    c=$(hit "$k/$l"); [ "$c" = "200" ] || [ "$c" = "206" ] && { report "$c" "$k/$l"; ok=1; }
    sleep "$DELAY"
  done
done
[ "$ok" = "0" ] && { echo "  nothing answered - the ACL is blocking this host. Stop here."; exit 1; }

echo "=== every locale of the known set ==="
for k in $KNOWN; do
  for l in $LOCALES; do
    c=$(hit "$k/$l"); case "$c" in 200|206) report "$c" "$k/$l" ;; esac
    sleep "$DELAY"
  done
done

[ "$WIDE" = "1" ] || exit 0

echo "=== wide sweep ==="
for app in $WIDE_APPS; do
  case "$app" in
    Diablo2)   vers="$WIDE_D2VERS"; variants="D2 LOD" ;;
    StarCraft) vers="$WIDE_SCVERS"; variants="Combo SC BW" ;;
    Warcraft3) vers="$WIDE_W3VERS"; variants="ROC TFT" ;;
    *)         vers="1.0 1.00 1.09 2.02"; variants="Retail Combo" ;;
  esac
  for v in $vers; do for var in $variants; do
    c=$(hit "$app/$v/$var/enUS"); case "$c" in 200|206) report "$c" "$app/$v/$var/enUS" ;; esac
    sleep "$DELAY"
  done; done
done
