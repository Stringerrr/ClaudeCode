#!/usr/bin/env bash
# Выполняется НА НОДЕ. Замеряет ёмкость аплинка: берёт максимум из нескольких источников.
# env: DURATION (сек на источник, по умолчанию 12), DO_UP (1 — мерить и отдачу)
set -u
DURATION="${DURATION:-12}"
DO_UP="${DO_UP:-1}"

down_best=0; src_best=""
for url in \
  "https://speed.cloudflare.com/__down?bytes=200000000" \
  "https://proof.ovh.net/files/1Gb.dat" \
  "http://speedtest.tele2.net/1GB.zip"
do
  sp="$(curl -s --max-time "$DURATION" -o /dev/null -w '%{speed_download}' "$url" 2>/dev/null | cut -d. -f1)"
  [ -n "${sp:-}" ] || sp=0
  echo "src=${url%%\?*} bytes_per_sec=$sp"
  if [ "$sp" -gt "$down_best" ]; then down_best="$sp"; src_best="$url"; fi
done

up_best=0
if [ "$DO_UP" = 1 ]; then
  sp="$(dd if=/dev/zero bs=1M count=100 2>/dev/null \
        | curl -s --max-time "$DURATION" -o /dev/null -w '%{speed_upload}' \
               -X POST --data-binary @- https://speed.cloudflare.com/__up 2>/dev/null | cut -d. -f1)"
  [ -n "${sp:-}" ] && [ "$sp" -gt 0 ] 2>/dev/null && up_best="$sp"
fi

# что заявляет сам интерфейс (потолок линка)
iface="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
link="$(cat "/sys/class/net/$iface/speed" 2>/dev/null)"

echo "down_mbps=$(( down_best * 8 / 1000000 ))"
echo "up_mbps=$(( up_best * 8 / 1000000 ))"
echo "best_src=$src_best"
echo "iface=${iface:-?} link_mbps=${link:-?}"
echo "probe=done"
