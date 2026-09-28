#!/usr/bin/env bash
# Выполняется НА НОДЕ. Идемпотентный сетап ноды 025 по §5 HANDOFF.
# Запускать детачем (см. scripts/setup-node.sh): nohup flock -n /root/setup.lock bash /root/node-setup.sh ...
#
# env:
#   DOMAIN            (обяз.) xx.proxy025.ru
#   NODE_SECRET_KEY   (обяз., если remnanode ещё не стоит) значение SECRET_KEY для docker-compose
#   LE_EMAIL          почта для Let's Encrypt (по умолчанию valeron2003k@gmail.com)
#   ALLOWLIST_ITEMS   через пробел: IP/CIDR монитора для CrowdSec-allowlist
#   SKIP_UPGRADE=1    не делать apt upgrade
#   SKIP_LE=1         не выпускать LE-серт (оставить self-signed)
set -u

DOMAIN="${DOMAIN:?нужен DOMAIN}"
NODE_SECRET_KEY="${NODE_SECRET_KEY:-}"
LE_EMAIL="${LE_EMAIL:-valeron2003k@gmail.com}"
ALLOWLIST_ITEMS="${ALLOWLIST_ITEMS:-}"
SKIP_UPGRADE="${SKIP_UPGRADE:-0}"
SKIP_LE="${SKIP_LE:-0}"
ALLOWLIST_NAME="${ALLOWLIST_NAME:-avoro-monitor}"

export DEBIAN_FRONTEND=noninteractive
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
step() { printf '\n[%s] === %s ===\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[%s] ОШИБКА: %s\n' "$(date +%H:%M:%S)" "$*"; echo "FAILED"; exit 1; }

# --- §8: dpkg-lock. Ждём; зависший apt-daily — прибиваем. ---
dpkg_locked() {
  if command -v fuser >/dev/null 2>&1; then
    fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1
  else
    pgrep -f 'apt-get|apt\.systemd\.daily|unattended-upgr|dpkg ' >/dev/null 2>&1
  fi
}
wait_dpkg() {
  local waited=0
  while dpkg_locked; do
    if [ $waited -ge 600 ]; then
      log "dpkg-lock держат >10 мин — снимаю apt-daily (§8)"
      systemctl stop apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
      pkill -9 -f apt.systemd.daily >/dev/null 2>&1
      pkill -9 -f unattended-upgrade >/dev/null 2>&1
      sleep 5
      break
    fi
    [ $((waited % 60)) -eq 0 ] && log "жду освобождения dpkg-lock… (${waited}с)"
    sleep 10; waited=$((waited + 10))
  done
}
apt_get() { wait_dpkg; apt-get -o DPkg::Lock::Timeout=300 "$@"; }

step "0. окружение"
log "hostname=$(hostname) domain=$DOMAIN"
. /etc/os-release 2>/dev/null
log "os=${PRETTY_NAME:-?} codename=${VERSION_CODENAME:-?}"
MYIP="$(curl -s --max-time 10 https://ifconfig.me || curl -s --max-time 10 https://api.ipify.org)"
log "внешний IP: ${MYIP:-неизвестен}"

step "1. apt"
apt_get update -qq || log "apt update с ошибками, продолжаю"
if [ "$SKIP_UPGRADE" != 1 ]; then apt_get upgrade -y -qq || log "apt upgrade с ошибками, продолжаю"; fi
apt_get install -y -qq curl ca-certificates openssl nginx certbot iproute2 psmisc >/dev/null || fail "не поставились базовые пакеты"

step "2. remnanode (docker)"
if ! command -v docker >/dev/null 2>&1; then
  log "ставлю docker"
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || fail "docker не поставился"
fi
if [ "$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null)" = running ]; then
  log "remnanode уже Up — НЕ трогаю (§5.3: не перетереть регистрацию)"
else
  [ -n "$NODE_SECRET_KEY" ] || fail "remnanode не запущен, а NODE_SECRET_KEY не передан"
  mkdir -p /opt/remnanode
  cat > /opt/remnanode/docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile: { soft: 1048576, hard: 1048576 }
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$NODE_SECRET_KEY
EOF
  (cd /opt/remnanode && docker compose up -d) || fail "docker compose up не отработал"
  sleep 5
  log "remnanode: $(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null)"
fi

step "3. заглушка nginx :9443 (Reality fallback, xver:0 => БЕЗ proxy_protocol)"
mkdir -p /usr/local/etc/xray /var/www/selfsteal
[ -f /var/www/selfsteal/index.html ] || cat > /var/www/selfsteal/index.html <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>It works</h1></body></html>
EOF
if [ ! -f /usr/local/etc/xray/self.crt ]; then
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /usr/local/etc/xray/self.key -out /usr/local/etc/xray/self.crt -days 3650 \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" >/dev/null 2>&1 || fail "self-signed не выпустился"
  log "self-signed выпущен на CN=$DOMAIN"
fi
write_selfsteal_conf() { # $1 = путь к fullchain, $2 = путь к ключу
  cat > /etc/nginx/conf.d/selfsteal.conf <<EOF
server {
    listen 127.0.0.1:9443 ssl;
    http2 on;
    server_name _;
    ssl_certificate     $1;
    ssl_certificate_key $2;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { root /var/www/selfsteal; index index.html; }
}
EOF
}
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  write_selfsteal_conf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
else
  write_selfsteal_conf /usr/local/etc/xray/self.crt /usr/local/etc/xray/self.key
fi
nginx -t >/dev/null 2>&1 || fail "nginx -t не прошёл"
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx || fail "nginx не стартанул"
code="$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:9443/ || echo 000)"
log "заглушка :9443 отвечает $code"

step "4. Let's Encrypt"
DNSIP="$(getent hosts "$DOMAIN" | awk '{print $1; exit}')"
log "DNS $DOMAIN -> ${DNSIP:-нет} ; наш IP ${MYIP:-?}"
if [ "$SKIP_LE" = 1 ]; then
  log "SKIP_LE=1 — пропускаю"
elif [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  log "LE-серт уже есть"
elif [ -z "$DNSIP" ] || { [ -n "$MYIP" ] && [ "$DNSIP" != "$MYIP" ]; }; then
  log "DNS ещё не ведёт на эту машину — остаюсь на self-signed (§5.5), LE выпустить позже"
else
  systemctl stop nginx
  certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" \
    --deploy-hook "systemctl restart nginx" || log "certbot не выпустил серт (проверь :80 и DNS)"
  systemctl start nginx
  if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    write_selfsteal_conf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    nginx -t >/dev/null 2>&1 && systemctl restart nginx   # §8: именно restart, reload серт не подхватит
    log "серт LE подключён, nginx перезапущен"
  fi
fi
iss="$(echo | timeout 7 openssl s_client -connect 127.0.0.1:9443 -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
log "issuer на :9443: ${iss:-нет ответа}"

step "5. CrowdSec"
if ! command -v cscli >/dev/null 2>&1; then
  curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash >/dev/null 2>&1
  apt_get update -qq >/dev/null 2>&1
  LIST=/etc/apt/sources.list.d/crowdsec_crowdsec.list
  if ! apt-cache policy crowdsec-firewall-bouncer-iptables 2>/dev/null | grep -q 'Candidate: [0-9]'; then
    # §8: packagecloud не знает свежие кодовые имена (напр. Ubuntu 26.04 resolute)
    fallback=noble; [ "${ID:-ubuntu}" = debian ] && fallback=bookworm
    log "репо CrowdSec пустой для ${VERSION_CODENAME:-?} — подменяю кодовое имя на $fallback (§8)"
    [ -f "$LIST" ] && sed -i "s/ ${VERSION_CODENAME:-nosuch} / $fallback /g; /^deb-src/d" "$LIST"
    apt-get purge -y -qq crowdsec >/dev/null 2>&1; rm -rf /etc/crowdsec
    apt_get update -qq >/dev/null 2>&1
  fi
  apt_get install -y -qq crowdsec crowdsec-firewall-bouncer-iptables >/dev/null 2>&1 \
    || fail "crowdsec/bouncer не поставились"
fi
log "cscli: $(cscli version 2>/dev/null | head -1)"

for c in linux sshd nginx base-http-scenarios http-cve whitelist-good-actors; do
  cscli collections install "crowdsecurity/$c" >/dev/null 2>&1 || log "коллекция $c: уже стоит или недоступна"
done

mkdir -p /etc/crowdsec/acquis.d
[ -f /etc/crowdsec/acquis.d/setup.linux.yaml ] || cat > /etc/crowdsec/acquis.d/setup.linux.yaml <<'EOF'
filenames:
  - /var/log/messages
  - /var/log/syslog
  - /var/log/kern.log
labels:
  type: syslog
EOF
[ -f /etc/crowdsec/acquis.d/setup.nginx.yaml ] || cat > /etc/crowdsec/acquis.d/setup.nginx.yaml <<'EOF'
filenames:
  - /var/log/nginx/*.log
labels:
  type: nginx
EOF
[ -f /etc/crowdsec/acquis.d/setup.sshd.yaml ] || cat > /etc/crowdsec/acquis.d/setup.sshd.yaml <<'EOF'
filenames:
  - /var/log/auth.log
  - /var/log/secure
labels:
  type: syslog
EOF
systemctl enable crowdsec crowdsec-firewall-bouncer >/dev/null 2>&1
systemctl restart crowdsec; systemctl restart crowdsec-firewall-bouncer
log "crowdsec=$(systemctl is-active crowdsec) bouncer=$(systemctl is-active crowdsec-firewall-bouncer)"

step "6. allowlist монитора (§5.7 — без него нода забанит SSH-опрос)"
if [ -n "$ALLOWLIST_ITEMS" ]; then
  cscli allowlists list -o raw 2>/dev/null | grep -q "^${ALLOWLIST_NAME}," \
    || cscli allowlists create "$ALLOWLIST_NAME" -d "avoro monitor/mac egress" >/dev/null 2>&1
  # shellcheck disable=SC2086
  cscli allowlists add "$ALLOWLIST_NAME" $ALLOWLIST_ITEMS >/dev/null 2>&1 || log "allowlists add не отработал (старый cscli?)"
  for it in $ALLOWLIST_ITEMS; do log "check ${it%%/*}: $(cscli allowlists check "${it%%/*}" 2>&1 | head -1)"; done
else
  log "ALLOWLIST_ITEMS пуст — пропускаю (потом: scripts/crowdsec-allowlist.sh --from-monitor --apply)"
fi

step "7. итог"
for p in 443 9443 2222; do
  if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then log ":$p слушает"; else log ":$p пусто"; fi
done
log "remnanode: $(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || echo absent)"
log "если :443 пусто — инбаунд Reality заводит ЮЗЕР в панели (§5.8), это норма до его настройки"
echo "DONE"
