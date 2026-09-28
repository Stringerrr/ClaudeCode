#!/usr/bin/env bash
# Опрашивает ноды по SSH и печатает состояние: remnanode, :443/:9443, серт заглушки,
# CrowdSec + баны + allowlist монитора, диск/нагрузка.
#   scripts/healthcheck.sh                # все ноды из inventory
#   scripts/healthcheck.sh de fl          # только эти id
#   scripts/healthcheck.sh --monitored    # только те, что в мониторинге
#   scripts/healthcheck.sh --raw          # сырые key=value по каждой ноде
# Выход: 0 — всё чисто, 1 — есть проблемы.
set -uo pipefail
. "$(dirname "$0")/../lib/common.sh"

RAW=0; FILTER=(); ONLY_MON=0
for a in "$@"; do
  case "$a" in
    --raw) RAW=1 ;;
    --monitored) ONLY_MON=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) FILTER+=("$a") ;;
  esac
done

MON_IP="${ALLOWLIST_CHECK_IP:-$(inv_get monitor.egress_ip)}"
PROBE="$REPO_ROOT/scripts/remote/node-probe.sh"
[ -f "$PROBE" ] || die "нет $PROBE"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

wanted() {
  [ ${#FILTER[@]} -eq 0 ] && return 0
  local id="$1" f
  for f in "${FILTER[@]}"; do [ "$f" = "$id" ] && return 0; done
  return 1
}

sel=()
while IFS=$'\t' read -r id country ip domain hostname hosting mon; do
  [ $ONLY_MON -eq 1 ] && [ "$mon" != "true" ] && continue
  wanted "$id" || continue
  sel+=("$id	$ip	$domain")
done < <(inv_nodes)
[ ${#sel[@]} -gt 0 ] || die "нечего опрашивать (проверь фильтр)"

info "опрос ${#sel[@]} нод (allowlist-проверка по $MON_IP)…"
for row in "${sel[@]}"; do
  IFS=$'\t' read -r id ip domain <<<"$row"
  (
    ssh_node "$ip" "DOMAIN='$domain' MON_IP='$MON_IP' bash -s" < "$PROBE" > "$TMP/$id.out" 2> "$TMP/$id.err"
    echo $? > "$TMP/$id.rc"
  ) &
done
wait

problems=0
printf '\n%-6s %-16s %-10s %-4s %-5s %-14s %-9s %-5s %-6s %-5s %s\n' \
  ID IP REMNANODE 443 9443 CERT CROWDSEC BANS ALLOW DISK LOAD
for row in "${sel[@]}"; do
  IFS=$'\t' read -r id ip domain <<<"$row"
  f="$TMP/$id.out"; rc="$(cat "$TMP/$id.rc" 2>/dev/null || echo 255)"
  g() { sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1; }

  if [ "$rc" != 0 ] || [ "$(g probe)" != done ]; then
    printf '%-6s %-16s %bНЕДОСТУПНА%b  %s\n' "$id" "$ip" "$C_R" "$C_0" \
      "$(head -1 "$TMP/$id.err" 2>/dev/null | cut -c1-70)"
    problems=$((problems + 1)); continue
  fi

  cert="$(g cert_issuer)"; days="$(g cert_days)"
  case "$cert" in
    *"Let's Encrypt"*|*R1*|*E[0-9]*) cert_s="LE ${days:-?}д" ;;
    НЕТ_ОТВЕТА)                      cert_s="нет:9443" ;;
    *)                               cert_s="self ${days:-?}д" ;;
  esac
  printf '%-6s %-16s %-10s %-4s %-5s %-14s %-9s %-5s %-6s %-5s %s\n' \
    "$id" "$ip" "$(g remnanode)" "$(g port_443)" "$(g port_9443)" "$cert_s" \
    "$(g crowdsec)" "$(g cs_bans)" "$(g allowlist)" "$(g disk)" "$(g load | cut -d' ' -f1)"

  [ "$(g remnanode)" = running ]  || { warn "  $id: remnanode не running ($(g remnanode))"; problems=$((problems+1)); }
  [ "$(g port_9443)" = 1 ]        || { warn "  $id: заглушка :9443 не слушает"; problems=$((problems+1)); }
  [ "$(g port_443)"  = 1 ]        || warn "  $id: :443 пусто — инбаунд не заведён в панели (см. §5.8 HANDOFF)"
  case "$cert_s" in self*|нет*)      warn "  $id: на :9443 не LE-серт ($cert)"; problems=$((problems+1)) ;; esac
  [ -n "$days" ] && [ "$days" -lt 14 ] 2>/dev/null && { warn "  $id: серт истекает через ${days}д"; problems=$((problems+1)); }
  [ "$(g crowdsec)" = active ]    || { warn "  $id: crowdsec не active"; problems=$((problems+1)); }
  [ "$(g cs_bouncer)" = active ]  || { warn "  $id: crowdsec-firewall-bouncer не active"; problems=$((problems+1)); }
  [ "$(g allowlist)" = yes ]      || { warn "  $id: монитор $MON_IP НЕ в allowlist ($(g allowlist)) — нода забанит опрос"; problems=$((problems+1)); }
  d="$(g disk | tr -d '%')"; [ -n "$d" ] && [ "$d" -gt 85 ] 2>/dev/null && { warn "  $id: диск $d%"; problems=$((problems+1)); }
done

if [ $RAW -eq 1 ]; then
  for row in "${sel[@]}"; do
    IFS=$'\t' read -r id ip domain <<<"$row"
    echo; echo "=== $id ($ip, $domain) ==="
    cat "$TMP/$id.out" 2>/dev/null
    [ -s "$TMP/$id.err" ] && { echo "-- stderr --"; cat "$TMP/$id.err"; }
  done
fi

echo
[ $problems -eq 0 ] && { ok "проблем не найдено"; exit 0; }
err "проблем: $problems"; exit 1
