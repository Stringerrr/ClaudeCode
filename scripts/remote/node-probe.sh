#!/usr/bin/env bash
# Выполняется НА НОДЕ (заливается по ssh на stdin). Печатает key=value, по строке на факт.
# Ожидает env: DOMAIN (SNI для проверки серта заглушки), MON_IP (для cscli allowlists check).
set -u
DOMAIN="${DOMAIN:-localhost}"
MON_IP="${MON_IP:-}"

first() { head -1 | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
kv() { printf '%s=%s\n' "$1" "${2:-n/a}"; }          # пустое значение -> n/a
run() { local out; out="$("$@" 2>/dev/null | first)"; printf '%s' "$out"; }

kv host        "$(run hostname)"
kv os          "$( (. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME") )"
kv uptime      "$(uptime -p 2>/dev/null | first | sed 's/^up //')"
kv load        "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null | first)"
kv mem         "$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d/%dMB", $3, $2}')"
kv disk        "$(df -h / 2>/dev/null | awk 'NR==2{print $5}')"

if command -v docker >/dev/null 2>&1; then
  st="$(run docker inspect -f '{{.State.Status}}' remnanode)"
  kv remnanode      "${st:-absent}"
  kv remna_since    "$(docker inspect -f '{{.State.StartedAt}}' remnanode 2>/dev/null | first | cut -c1-19)"
  kv remna_restarts "$(run docker inspect -f '{{.RestartCount}}' remnanode)"
else
  kv remnanode "нет_docker"
fi

for p in 443 9443 2222; do
  if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then kv "port_${p}" 1; else kv "port_${p}" 0; fi
done

kv nginx "$(run systemctl is-active nginx)"
cert="$(echo | timeout 7 openssl s_client -connect 127.0.0.1:9443 -servername "$DOMAIN" 2>/dev/null \
        | openssl x509 -noout -issuer -enddate -subject 2>/dev/null)"
if [ -n "$cert" ]; then
  kv cert_issuer "$(printf '%s\n' "$cert" | sed -n 's/^issuer=//p' | sed 's/.*CN *= *//' | first)"
  kv cert_cn     "$(printf '%s\n' "$cert" | sed -n 's/^subject=//p' | sed 's/.*CN *= *//' | first)"
  end="$(printf '%s\n' "$cert" | sed -n 's/^notAfter=//p' | first)"
  kv cert_until "$end"
  e="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  [ "${e:-0}" -gt 0 ] && kv cert_days "$(( (e - $(date +%s)) / 86400 ))"
else
  kv cert_issuer "НЕТ_ОТВЕТА"
fi
kv certbot_timer "$(run systemctl is-active certbot.timer)"

kv crowdsec   "$(run systemctl is-active crowdsec)"
kv cs_bouncer "$(run systemctl is-active crowdsec-firewall-bouncer)"
kv cs_version "$(cscli version 2>/dev/null | sed -n 's/.*[Vv]ersion: *\(v\?[0-9][^ ,]*\).*/\1/p' | first)"
kv cs_bans    "$(cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
if ! command -v cscli >/dev/null 2>&1; then
  kv allowlist "нет_cscli"
elif [ -n "$MON_IP" ]; then
  chk="$(cscli allowlists check "$MON_IP" 2>&1 | first)"
  case "$chk" in
    *allowlisted*)                                  kv allowlist yes ;;
    *"unknown command"*|*"unknown flag"*|*"Usage:"*) kv allowlist "старый_cscli" ;;
    *)                                              kv allowlist "NO" ;;
  esac
else
  kv allowlist "не_проверялся"
fi
kv probe done
