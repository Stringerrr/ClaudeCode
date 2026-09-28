#!/usr/bin/env bash
# CrowdSec-allowlist монитора на нодах. Без него нода банит SSH-опрос avoro (§7 HANDOFF).
#
#   scripts/crowdsec-allowlist.sh                         # проверить текущий egress на всех нодах
#   scripts/crowdsec-allowlist.sh --from-monitor          # снять реальный egress С МОНИТОРА и проверить
#   scripts/crowdsec-allowlist.sh --from-monitor --apply  # снять egress, раскатать на все ноды, записать в inventory
#   scripts/crowdsec-allowlist.sh --apply 1.2.3.4/32 5.6.7.8   # раскатать конкретные записи
#   scripts/crowdsec-allowlist.sh de fl --apply 1.2.3.4   # только на эти ноды
# Выход: 0 — везде allowlisted, 1 — где-то нет.
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"

LIST_NAME="${LIST_NAME:-avoro-monitor}"
APPLY=0; FROM_MONITOR=0; ITEMS=(); FILTER=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --from-monitor) FROM_MONITOR=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *.*.*.*|*.*.*.*/*) ITEMS+=("$1") ;;
    *) FILTER+=("$1") ;;
  esac
  shift
done

if [ $FROM_MONITOR -eq 1 ]; then
  info "снимаю egress с монитора $(inv_get monitor.ip)…"
  eg="$(ssh_monitor "curl -s --max-time 10 https://ifconfig.me || curl -s --max-time 10 https://api.ipify.org" 2>/dev/null | tr -d '[:space:]')"
  case "$eg" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ok "egress монитора: $eg"; ITEMS+=("$eg/32") ;;
    *) die "не смог снять egress монитора (получено: '${eg:-пусто}'). Проверь SSH до монитора." ;;
  esac
fi

# что проверяем, если явных записей не дали — известный egress из inventory
CHECK_IP="${ITEMS[0]:-}"
CHECK_IP="${CHECK_IP%%/*}"
[ -n "$CHECK_IP" ] || CHECK_IP="$(inv_get monitor.egress_ip)"
[ -n "$CHECK_IP" ] || die "не задан IP для проверки: укажи его аргументом или заполни monitor.egress_ip"
[ $APPLY -eq 1 ] && [ ${#ITEMS[@]} -eq 0 ] && die "--apply без записей: укажи IP/CIDR или добавь --from-monitor"

wanted() {
  [ ${#FILTER[@]} -eq 0 ] && return 0
  local id="$1" f; for f in "${FILTER[@]}"; do [ "$f" = "$id" ] && return 0; done; return 1
}

remote_script() {
  cat <<'RS'
set -u
LIST="$1"; CHECK="$2"; shift 2
command -v cscli >/dev/null 2>&1 || { echo "RESULT=нет_cscli"; exit 0; }
if [ "$#" -gt 0 ]; then
  if ! cscli allowlists list -o raw 2>/dev/null | grep -q "^${LIST}," ; then
    cscli allowlists create "$LIST" -d "avoro monitor/mac egress" >/dev/null 2>&1 \
      || { echo "RESULT=create_failed(старый_cscli?)"; exit 0; }
    echo "CREATED=$LIST"
  fi
  out="$(cscli allowlists add "$LIST" "$@" 2>&1)" || { echo "RESULT=add_failed: $(echo "$out" | head -1)"; exit 0; }
  echo "ADDED=$*"
fi
chk="$(cscli allowlists check "$CHECK" 2>&1 | head -1)"
case "$chk" in
  *allowlisted*) echo "RESULT=yes" ;;
  *) echo "RESULT=NO ($chk)" ;;
esac
RS
}

bad=0
while IFS=$'\t' read -r id country ip domain hostname hosting mon; do
  wanted "$id" || continue
  out="$(ssh_node "$ip" "bash -s -- '$LIST_NAME' '$CHECK_IP' ${ITEMS[*]:-}" <<<"$(remote_script)" 2>&1)"
  rc=$?
  res="$(printf '%s\n' "$out" | sed -n 's/^RESULT=//p' | head -1)"
  extra="$(printf '%s\n' "$out" | grep -E '^(CREATED|ADDED)=' | tr '\n' ' ')"
  if [ $rc -ne 0 ] || [ -z "$res" ]; then
    printf '%-6s %-16s %bSSH/ошибка%b %s\n' "$id" "$ip" "$C_R" "$C_0" "$(printf '%s' "$out" | head -1 | cut -c1-70)"
    bad=$((bad+1)); continue
  fi
  case "$res" in
    yes) printf '%-6s %-16s %ballowlisted%b %s\n' "$id" "$ip" "$C_G" "$C_0" "$extra" ;;
    *)   printf '%-6s %-16s %b%s%b %s\n' "$id" "$ip" "$C_R" "$res" "$C_0" "$extra"; bad=$((bad+1)) ;;
  esac
done < <(inv_nodes)

if [ $APPLY -eq 1 ] && [ $bad -eq 0 ]; then
  python3 - "$INVENTORY" "$CHECK_IP" "${ITEMS[@]}" <<'PY'
import json, sys
path, check_ip, items = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open(path))
m = d["monitor"]
m["egress_ip"] = check_ip
for it in items:
    if it not in m["egress_cidrs"]:
        m["egress_cidrs"].append(it)
m["egress_verified"] = True
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PY
  ok "inventory обновлён: monitor.egress_ip=$CHECK_IP, egress_cidrs += ${ITEMS[*]}"
fi

echo
[ $bad -eq 0 ] && { ok "$CHECK_IP в allowlist на всех проверенных нодах"; exit 0; }
err "нод с проблемой: $bad"; exit 1
