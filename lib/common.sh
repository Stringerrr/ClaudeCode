#!/usr/bin/env bash
# Общие функции для скриптов кластера proxy025. Подключается через:
#   . "$(dirname "$0")/../lib/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${INVENTORY:-$REPO_ROOT/inventory/nodes.json}"

# ---------- вывод ----------
if [ -t 1 ]; then C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else C_R=; C_G=; C_Y=; C_B=; C_0=; fi
info() { printf '%s\n' "$*" >&2; }
warn() { printf '%s%s%s\n' "$C_Y" "$*" "$C_0" >&2; }
err()  { printf '%s%s%s\n' "$C_R" "$*" "$C_0" >&2; }
die()  { err "$*"; exit 1; }
ok()   { printf '%s%s%s\n' "$C_G" "$*" "$C_0" >&2; }

# ---------- чтение inventory (jq, иначе python3) ----------
_inv_tool() {
  if command -v jq >/dev/null 2>&1; then echo jq
  elif command -v python3 >/dev/null 2>&1; then echo python3
  else die "нужен jq или python3 (brew install jq)"; fi
}

# inv_nodes [--monitored] -> TSV: id country ip domain hostname hosting monitored
inv_nodes() {
  local only_mon=0
  [ "${1:-}" = "--monitored" ] && only_mon=1
  case "$(_inv_tool)" in
    jq) jq -r --argjson m "$only_mon" '
          .nodes[] | select($m == 0 or .monitored)
          | [.id, .country, .ip, .domain, (if (.hostname // "") == "" then "-" else .hostname end),
             (if (.hosting // "") == "" then "-" else .hosting end), (.monitored|tostring)]
          | @tsv' "$INVENTORY" ;;
    python3) python3 - "$INVENTORY" "$only_mon" <<'PY'
import json, sys
inv, only_mon = sys.argv[1], sys.argv[2] == "1"
for n in json.load(open(inv))["nodes"]:
    if only_mon and not n.get("monitored"):
        continue
    print("\t".join([n["id"], n["country"], n["ip"], n["domain"],
                     n.get("hostname") or "-", n.get("hosting") or "-",
                     "true" if n.get("monitored") else "false"]))
PY
    ;;
  esac
}

# inv_get monitor.ip -> значение (скаляр) или пусто
inv_get() {
  local path="$1"
  case "$(_inv_tool)" in
    jq) jq -r --arg p "$path" 'getpath($p|split(".")) // "" | if type=="array" then join(" ") else tostring end' "$INVENTORY" ;;
    python3) python3 - "$INVENTORY" "$path" <<'PY'
import json, sys
cur = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        cur = ""
        break
    cur = cur[part]
if isinstance(cur, list): print(" ".join(str(x) for x in cur))
elif isinstance(cur, bool): print("true" if cur else "false")
else: print(cur)
PY
    ;;
  esac
}

# inv_node_field <id> <field>
inv_node_field() {
  local id="$1" field="$2"
  inv_nodes | awk -F'\t' -v id="$id" -v f="$field" '
    $1 == id {
      split("id country ip domain hostname hosting monitored", k, " ")
      for (i = 1; i <= 7; i++) if (k[i] == f) { print $i; exit }
    }'
}

expand_path() { case "$1" in "~"/*) printf '%s\n' "$HOME/${1#"~/"}" ;; *) printf '%s\n' "$1" ;; esac; }

# ---------- SSH ----------
node_key()    { expand_path "${SSH_KEY:-$(inv_get ssh_key)}"; }

# У ноды может быть свой ключ (поле ssh_key рядом с ip). env SSH_KEY перебивает всё.
key_for_ip() {
  local ip="$1" k=""
  [ -n "${SSH_KEY:-}" ] && { expand_path "$SSH_KEY"; return; }
  if command -v jq >/dev/null 2>&1; then
    k="$(jq -r --arg ip "$ip" '.nodes[] | select(.ip == $ip) | .ssh_key // empty' "$INVENTORY")"
  elif command -v python3 >/dev/null 2>&1; then
    k="$(python3 -c '
import json, sys
inv, ip = sys.argv[1], sys.argv[2]
for n in json.load(open(inv))["nodes"]:
    if n["ip"] == ip and n.get("ssh_key"):
        print(n["ssh_key"])
        break
' "$INVENTORY" "$ip")"
  fi
  if [ -n "$k" ]; then expand_path "$k"; else node_key; fi
}
monitor_key() { expand_path "${MONITOR_SSH_KEY:-$(inv_get monitor.ssh_key)}"; }

ssh_opts() {
  printf '%s\n' -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}" -o BatchMode=yes -o LogLevel=ERROR
}

# ssh_node <ip> <команда...>
ssh_node() {
  local ip="$1"; shift
  local key opts=(); key="$(key_for_ip "$ip")"
  [ -f "$key" ] || die "нет SSH-ключа нод: $key"
  while IFS= read -r o; do opts+=("$o"); done < <(ssh_opts "$key")
  ssh "${opts[@]}" "root@$ip" "$@"
}

# ssh_monitor <команда...>
ssh_monitor() {
  local key opts=() host; key="$(monitor_key)"; host="$(inv_get monitor.ip)"
  [ -f "$key" ] || die "нет SSH-ключа монитора: $key"
  while IFS= read -r o; do opts+=("$o"); done < <(ssh_opts "$key")
  ssh "${opts[@]}" "root@$host" "$@"
}

# resolve <домен> -> IP (dig, иначе host/getent)
resolve() {
  local d="$1" ip=""
  if command -v dig >/dev/null 2>&1; then ip="$(dig +short +time=3 +tries=2 A "$d" | grep -E '^[0-9.]+$' | head -1)"
  elif command -v host >/dev/null 2>&1; then ip="$(host -t A "$d" 2>/dev/null | awk '/has address/{print $4; exit}')"
  else ip="$(getent hosts "$d" 2>/dev/null | awk '{print $1; exit}')"; fi
  printf '%s\n' "$ip"
}
