#!/usr/bin/env bash
# Генерит inventory/p025_nodes.json (формат монитора: [{"ip","country"}]) из nodes.json.
# Попадают только ноды с "monitored": true.
#   scripts/gen-p025-nodes.sh            # записать в inventory/p025_nodes.json
#   scripts/gen-p025-nodes.sh --stdout   # только вывести
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

OUT="$REPO_ROOT/inventory/p025_nodes.json"
[ "${1:-}" = "--stdout" ] && OUT=/dev/stdout

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
{
  echo "["
  first=1
  while IFS=$'\t' read -r id country ip _domain _hostname _hosting _mon; do
    [ $first -eq 1 ] || echo ","
    first=0
    printf '  {"ip": "%s", "country": "%s"}' "$ip" "$country"
  done < <(inv_nodes --monitored)
  echo
  echo "]"
} > "$tmp"

if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" || die "сгенерирован невалидный JSON"
fi

cat "$tmp" > "$OUT"
[ "$OUT" = /dev/stdout ] || ok "записан $OUT ($(inv_nodes --monitored | wc -l | tr -d ' ') нод)"
