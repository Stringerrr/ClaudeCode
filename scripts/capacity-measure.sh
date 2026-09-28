#!/usr/bin/env bash
# §9.3: замер ёмкости канала нод и запись в capacity.json монитора (иначе бар «СЕТЬ» врёт).
#
#   scripts/capacity-measure.sh --show            # показать текущий capacity.json с монитора (и его схему)
#   scripts/capacity-measure.sh --measure [ids]   # замерить (по умолчанию все ноды), напечатать результат
#   scripts/capacity-measure.sh --measure --write # замерить и слить в capacity.json на мониторе (с бэкапом)
#
# ВАЖНО: схема capacity.json не задокументирована в HANDOFF. --write сохраняет уже существующие
# ключи/поля файла и только обновляет числа; если файла нет — пишет свою схему и предупреждает.
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"

MODE=""; WRITE=0; FILTER=()
while [ $# -gt 0 ]; do
  case "$1" in
    --show) MODE=show ;;
    --measure) MODE=measure ;;
    --write) WRITE=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) FILTER+=("$1") ;;
  esac
  shift
done
[ -n "$MODE" ] || { sed -n '2,9p' "$0"; exit 1; }
CAP_FILE="$(inv_get monitor.capacity_file)"

if [ "$MODE" = show ]; then
  ssh_monitor "cat '$CAP_FILE' 2>/dev/null || echo '(файла нет)'"
  exit 0
fi

wanted() {
  [ ${#FILTER[@]} -eq 0 ] && return 0
  local id="$1" f; for f in "${FILTER[@]}"; do [ "$f" = "$id" ] && return 0; done; return 1
}

PROBE="$REPO_ROOT/scripts/remote/capacity-probe.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RESULT="$TMP/result.json"; echo "{}" > "$RESULT"

while IFS=$'\t' read -r id country ip domain hostname hosting mon; do
  wanted "$id" || continue
  info "замер $id ($ip)…"
  out="$(ssh_node "$ip" "DURATION=${DURATION:-12} DO_UP=${DO_UP:-1} bash -s" < "$PROBE" 2>/dev/null)"
  if ! printf '%s' "$out" | grep -q 'probe=done'; then err "  $id: замер не удался"; continue
  fi
  down="$(printf '%s\n' "$out" | sed -n 's/^down_mbps=//p')"
  up="$(printf '%s\n' "$out" | sed -n 's/^up_mbps=//p')"
  link="$(printf '%s\n' "$out" | sed -n 's/.*link_mbps=//p')"
  printf '  %-6s down=%s Mbps up=%s Mbps link=%s Mbps\n' "$id" "$down" "$up" "$link"
  python3 - "$RESULT" "$ip" "$id" "$down" "$up" "$link" <<'PY'
import json, sys, datetime
path, ip, nid, down, up, link = sys.argv[1:7]
d = json.load(open(path))
d[ip] = {"id": nid, "down_mbps": int(down or 0), "up_mbps": int(up or 0),
         "link_mbps": link, "measured_at": datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z"}
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2)
PY
done < <(inv_nodes)

echo; info "результат:"; cat "$RESULT"

[ $WRITE -eq 1 ] || { echo; warn "чтобы записать на монитор — добавь --write"; exit 0; }

existing="$(ssh_monitor "cat '$CAP_FILE' 2>/dev/null" || true)"
merged="$TMP/merged.json"
printf '%s' "$existing" > "$TMP/existing.json"
python3 - "$TMP/existing.json" "$RESULT" "$merged" <<'PY'
import json, sys
exist_path, new_path, out_path = sys.argv[1:4]
try:
    existing = json.load(open(exist_path))
    if not isinstance(existing, dict):
        raise ValueError
except Exception:
    existing = {}
    print("!! на мониторе не было валидного capacity.json — пишу свою схему "
          "{ip: {id, down_mbps, up_mbps, link_mbps, measured_at}}; сверь с backend/app.py", file=sys.stderr)
new = json.load(open(new_path))
# сохраняем имена полей, которые уже использует монитор
sample = next((v for v in existing.values() if isinstance(v, dict)), None)
for ip, vals in new.items():
    if sample is not None:
        cur = dict(existing.get(ip, {}))
        for field in sample:
            low = field.lower()
            if "down" in low or low in ("mbps", "speed", "capacity"):
                cur[field] = vals["down_mbps"]
            elif "up" in low:
                cur[field] = vals["up_mbps"]
            elif "time" in low or "date" in low or "at" in low:
                cur[field] = vals["measured_at"]
        existing[ip] = cur or vals
    else:
        existing[ip] = vals
json.dump(existing, open(out_path, "w"), ensure_ascii=False, indent=2)
PY
echo; info "будет записано на монитор:"; cat "$merged"
printf 'записать в %s? [y/N] ' "$CAP_FILE"; read -r ans
case "$ans" in y|Y|yes) ;; *) die "отменено" ;; esac
ssh_monitor "cp '$CAP_FILE' '$CAP_FILE.bak.\$(date +%F-%H%M%S)' 2>/dev/null; cat > '$CAP_FILE'" < "$merged" \
  && ok "записано (бэкап рядом)" || die "запись не удалась"
