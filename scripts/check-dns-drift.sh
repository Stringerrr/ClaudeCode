#!/usr/bin/env bash
# Сверяет IP из inventory/nodes.json с тем, что сейчас отдаёт DNS по домену ноды.
# У hostes.io / play2go.cloud IP меняются регулярно — DNS ведёт домен, это источник правды.
#   scripts/check-dns-drift.sh           # только показать
#   scripts/check-dns-drift.sh --apply   # обновить nodes.json + перегенерить p025_nodes.json
# Выход: 0 — расхождений нет; 1 — есть дрейф; 2 — домен не резолвится.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

drift=0; unresolved=0
declare -a CHANGES=()

printf '%-6s %-22s %-16s %-16s %s\n' ID DOMAIN INVENTORY DNS STATUS
while IFS=$'\t' read -r id country ip domain _hostname _hosting mon; do
  dns="$(resolve "$domain")"
  if [ -z "$dns" ]; then
    status="${C_R}не резолвится${C_0}"; unresolved=1
  elif [ "$dns" = "$ip" ]; then
    status="${C_G}ok${C_0}"
  else
    status="${C_Y}ДРЕЙФ${C_0}"; drift=1; CHANGES+=("$id	$ip	$dns")
  fi
  [ "$mon" = "true" ] || id="$id*"
  printf '%-6s %-22s %-16s %-16s %b\n' "$id" "$domain" "$ip" "${dns:--}" "$status"
done < <(inv_nodes)
echo "* — нода не в мониторинге"

if [ ${#CHANGES[@]} -gt 0 ] && [ $APPLY -eq 1 ]; then
  for c in "${CHANGES[@]}"; do
    IFS=$'\t' read -r id old new <<<"$c"
    python3 - "$INVENTORY" "$id" "$new" <<'PY'
import json, sys
path, node_id, new_ip = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path))
for n in data["nodes"]:
    if n["id"] == node_id:
        n["ip"] = new_ip
json.dump(data, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PY
    ok "$id: $old -> $new (записано в nodes.json)"
  done
  INVENTORY="$INVENTORY" "$REPO_ROOT/scripts/gen-p025-nodes.sh"
  warn "не забудь залить список на монитор: scripts/monitor-sync.sh"
elif [ ${#CHANGES[@]} -gt 0 ]; then
  warn "есть дрейф; чтобы записать — запусти с --apply"
fi

[ $unresolved -eq 1 ] && exit 2
exit $drift
