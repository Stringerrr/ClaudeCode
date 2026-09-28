#!/usr/bin/env bash
# Разворачивание НОВОЙ ноды 025 (§5 HANDOFF): ключ -> apt -> remnanode -> заглушка :9443 ->
# LE -> CrowdSec -> allowlist монитора -> запись в inventory.
# Сетап гонится ДЕТАЧЕМ на ноде (nohup + flock) и поллится по логу — свежие машины флапают (§5).
#
#   scripts/setup-node.sh --id de-3 --ip 1.2.3.4 --domain de-3.proxy025.ru \
#                         --country "🇩🇪 Германия 3" [--hosting hostes] [--password 'rootpw'] \
#                         [--skip-upgrade] [--skip-le] [--no-inventory]
#
# SECRET_KEY берётся из env NODE_SECRET_KEY или из secrets/node-secret-key.txt (в git не хранится).
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"

ID=""; IP=""; DOMAIN=""; COUNTRY=""; HOSTING=""; PASSWORD=""
SKIP_UPGRADE=0; SKIP_LE=0; ADD_INV=1
while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID="$2"; shift ;;
    --ip) IP="$2"; shift ;;
    --domain) DOMAIN="$2"; shift ;;
    --country) COUNTRY="$2"; shift ;;
    --hosting) HOSTING="$2"; shift ;;
    --password) PASSWORD="$2"; shift ;;
    --skip-upgrade) SKIP_UPGRADE=1 ;;
    --skip-le) SKIP_LE=1 ;;
    --no-inventory) ADD_INV=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
  shift
done
[ -n "$ID" ] && [ -n "$IP" ] && [ -n "$DOMAIN" ] || die "нужны --id, --ip, --domain (см. --help)"
[ -n "$COUNTRY" ] || COUNTRY="$ID"

KEY="$(node_key)"; PUB="$KEY.pub"
[ -f "$KEY" ] || die "нет ключа $KEY"

SECRET_FILE="$REPO_ROOT/secrets/node-secret-key.txt"
NODE_SECRET_KEY="${NODE_SECRET_KEY:-}"
if [ -z "$NODE_SECRET_KEY" ] && [ -f "$SECRET_FILE" ]; then NODE_SECRET_KEY="$(tr -d '\n\r' < "$SECRET_FILE")"; fi
[ -n "$NODE_SECRET_KEY" ] || warn "NODE_SECRET_KEY пуст — сетап упадёт, если remnanode ещё не стоит (положи его в $SECRET_FILE)"

ALLOWLIST_ITEMS="$(inv_get monitor.egress_cidrs)"
[ "$(inv_get monitor.egress_verified)" = true ] || \
  warn "egress монитора не подтверждён (inventory monitor.egress_verified=false) — после сетапа прогони scripts/crowdsec-allowlist.sh --from-monitor --apply"

# --- 1. ключ ---
if ! ssh_node "$IP" true 2>/dev/null; then
  [ -n "$PASSWORD" ] || die "по ключу не пускает и --password не задан"
  command -v sshpass >/dev/null 2>&1 || die "нужен sshpass (brew install hudochenkov/sshpass/sshpass)"
  [ -f "$PUB" ] || die "нет публичного ключа $PUB"
  info "заливаю публичный ключ по паролю…"
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "root@$IP" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$(cat "$PUB")' ~/.ssh/authorized_keys 2>/dev/null \
     || echo '$(cat "$PUB")' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" \
    || die "не удалось залить ключ"
  ssh_node "$IP" true || die "ключ залит, но вход по ключу всё равно не работает"
fi
ok "вход по ключу работает: $(ssh_node "$IP" hostname)"

# --- 2. заливаем и запускаем детачем ---
info "заливаю node-setup.sh"
ssh_node "$IP" "cat > /root/node-setup.sh" < "$REPO_ROOT/scripts/remote/node-setup.sh" || die "не залился скрипт"

if ssh_node "$IP" "flock -n /root/setup.lock true" 2>/dev/null; then
  info "запускаю сетап детачем (лог: /root/setup.log)"
  ssh_node "$IP" "rm -f /root/setup.log; nohup setsid flock -n /root/setup.lock env \
      DOMAIN='$DOMAIN' NODE_SECRET_KEY='$NODE_SECRET_KEY' ALLOWLIST_ITEMS='$ALLOWLIST_ITEMS' \
      SKIP_UPGRADE=$SKIP_UPGRADE SKIP_LE=$SKIP_LE \
      bash /root/node-setup.sh > /root/setup.log 2>&1 < /dev/null &" || die "не смог запустить сетап"
else
  warn "сетап уже выполняется на ноде (flock занят) — просто поллю лог"
fi

# --- 3. поллим лог (§5: флапающие машины) ---
printed=0; waited=0; limit=$((45 * 60)); state=""
while [ $waited -lt $limit ]; do
  logtxt="$(ssh_node "$IP" "cat /root/setup.log 2>/dev/null" 2>/dev/null)"
  if [ -n "$logtxt" ]; then
    total="$(printf '%s\n' "$logtxt" | wc -l | tr -d ' ')"
    if [ "$total" -gt "$printed" ]; then
      printf '%s\n' "$logtxt" | tail -n +$((printed + 1))
      printed="$total"
    fi
    case "$logtxt" in *DONE*) state=done; break ;; *FAILED*) state=failed; break ;; esac
  fi
  sleep 15; waited=$((waited + 15))
done

case "$state" in
  done)   ok "сетап завершён" ;;
  failed) die "сетап упал — смотри лог на ноде: /root/setup.log" ;;
  *)      die "таймаут $((limit / 60)) мин; сетап, возможно, ещё идёт: ssh root@$IP tail -f /root/setup.log" ;;
esac

# --- 4. inventory ---
if [ $ADD_INV -eq 1 ]; then
  python3 - "$INVENTORY" "$ID" "$COUNTRY" "$IP" "$DOMAIN" "$HOSTING" <<'PY'
import json, sys
path, nid, country, ip, domain, hosting = sys.argv[1:7]
d = json.load(open(path))
for n in d["nodes"]:
    if n["id"] == nid:
        n.update({"country": country, "ip": ip, "domain": domain, "hosting": hosting, "monitored": True})
        break
else:
    d["nodes"].append({"id": nid, "country": country, "ip": ip, "domain": domain,
                       "hostname": "", "hosting": hosting, "monitored": True})
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PY
  hn="$(ssh_node "$IP" hostname 2>/dev/null)"
  [ -n "$hn" ] && python3 - "$INVENTORY" "$ID" "$hn" <<'PY'
import json, sys
path, nid, hn = sys.argv[1:4]
d = json.load(open(path))
for n in d["nodes"]:
    if n["id"] == nid:
        n["hostname"] = hn
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
PY
  "$REPO_ROOT/scripts/gen-p025-nodes.sh"
  ok "нода $ID добавлена в inventory"
fi

echo
info "дальше:"
info "  1) scripts/monitor-sync.sh --push        # показать ноду в дашборде"
info "  2) инбаунд Reality :443 на $DOMAIN заводит юзер в панели $(inv_get panel) (§5.8)"
info "  3) scripts/healthcheck.sh $ID            # проверить"
