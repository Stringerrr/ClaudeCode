#!/usr/bin/env bash
# Синхронизация списка нод с сервером мониторинга (avoro) и проверка живого поллинга.
# Бэкенд перечитывает p025_nodes.json каждый цикл — рестарт сервиса НЕ нужен.
#
#   scripts/monitor-sync.sh            # показать diff локального и удалённого списка + статусы нод
#   scripts/monitor-sync.sh --push     # залить локальный inventory/p025_nodes.json (с бэкапом) и проверить
#   scripts/monitor-sync.sh --status   # только живые статусы нод из API монитора
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"

MODE="${1:---diff}"
REMOTE_FILE="$(inv_get monitor.nodes_file)"
APP_DIR="$(inv_get monitor.app_dir)"
LOCAL_FILE="$REPO_ROOT/inventory/p025_nodes.json"

status_cmd() {
  cat <<RS
cd "$APP_DIR" 2>/dev/null || exit 3
secret="\$(grep ^WEB_AUTH_SECRET= .env | cut -d= -f2-)"
curl -s -H "X-Web-Auth: \$secret" http://127.0.0.1:8090/api/metrics \
  | ./venv/bin/python -c 'import sys,json
d=json.load(sys.stdin)
for n in d.get("p025_nodes", []):
    print("%-26s %-16s %s" % (n.get("country"), n.get("ip"), "ONLINE" if n.get("online") else "OFF"))'
RS
}

show_status() {
  info "живой поллинг на мониторе:"
  ssh_monitor "bash -s" <<<"$(status_cmd)" || err "не смог прочитать API монитора (см. §3 HANDOFF: ключ/egress/SSH-allowlist)"
}

case "$MODE" in
  --status) show_status ;;

  --diff)
    [ -f "$LOCAL_FILE" ] || die "нет $LOCAL_FILE — сгенерь: scripts/gen-p025-nodes.sh"
    remote="$(ssh_monitor "cat '$REMOTE_FILE'" 2>/dev/null)" || die "не смог прочитать $REMOTE_FILE на мониторе"
    if diff -u <(printf '%s\n' "$remote") "$LOCAL_FILE" > /tmp/p025-nodes.diff 2>&1; then
      ok "локальный и удалённый списки совпадают"
    else
      warn "расхождение (слева — монитор, справа — локальный):"
      cat /tmp/p025-nodes.diff
      warn "залить: scripts/monitor-sync.sh --push"
    fi
    show_status
    ;;

  --push)
    [ -f "$LOCAL_FILE" ] || die "нет $LOCAL_FILE — сгенерь: scripts/gen-p025-nodes.sh"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$LOCAL_FILE" || die "локальный JSON невалиден"
    info "заливаю $LOCAL_FILE -> монитор:$REMOTE_FILE"
    ssh_monitor "cp '$REMOTE_FILE' '$REMOTE_FILE.bak.\$(date +%F-%H%M%S)' 2>/dev/null; cat > '$REMOTE_FILE.new' && \
                 python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$REMOTE_FILE.new' && \
                 mv '$REMOTE_FILE.new' '$REMOTE_FILE' && echo OK" < "$LOCAL_FILE" | grep -q OK \
      || die "заливка не удалась (файл на мониторе не тронут)"
    ok "залито; бэкенд подхватит в течение ~20с (рестарт не нужен)"
    sleep 25
    show_status
    ;;

  -h|--help) sed -n '2,7p' "$0" ;;
  *) die "неизвестный режим: $MODE (см. --help)" ;;
esac
