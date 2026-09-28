# proxy025 — кластер Remnawave-нод (panel.025vpn.ru)

Рабочий тулкит по кластеру нод сервиса proxy025: инвентарь, разворачивание новой ноды,
проверка состояния, синхронизация с мониторингом avoro.

Полная передаточная справка (устройство кластера, порты, грабли) — **[docs/HANDOFF.md](docs/HANDOFF.md)**.
Секреты в git не хранятся — **[secrets/README.md](secrets/README.md)**.

## Что где

| Путь | Что это |
|---|---|
| `inventory/nodes.json` | **источник правды**: ноды (id, страна, IP, домен, hostname, хостинг, показывать ли в мониторинге) + параметры монитора |
| `inventory/p025_nodes.json` | генерируемый файл в формате монитора `[{"ip","country"}]` |
| `lib/common.sh` | общие функции: чтение inventory, SSH, резолв |
| `scripts/*.sh` | то, что запускаешь руками с Мака |
| `scripts/remote/*.sh` | то, что заливается и выполняется на ноде |

## Требования

Bash, `ssh`, `python3` (или `jq`), `dig`; `sshpass` — только для первого входа на новую ноду по паролю.
SSH-ключи: `~/Desktop/ClaudeCode/keys/025key` (ноды), `~/Desktop/ClaudeCode/keys/hzhex_ed25519` (монитор);
пути меняются в `inventory/nodes.json` или через env `SSH_KEY` / `MONITOR_SSH_KEY`.

## Типовые задачи

```bash
# нода показывает OFF в дашборде — первым делом проверить, не сменился ли IP (§8 справки)
scripts/check-dns-drift.sh              # сверить IP из inventory с DNS
scripts/check-dns-drift.sh --apply      # записать новые IP + перегенерить список для монитора
scripts/monitor-sync.sh --push          # залить список на монитор (рестарт сервиса не нужен)

# состояние всех нод: remnanode, :443/:9443, серт заглушки, CrowdSec, баны, allowlist, диск
scripts/healthcheck.sh
scripts/healthcheck.sh de fl --raw

# egress монитора -> allowlist CrowdSec на всех нодах (иначе ноды банят SSH-опрос, §5.7)
scripts/crowdsec-allowlist.sh --from-monitor          # только посмотреть
scripts/crowdsec-allowlist.sh --from-monitor --apply  # раскатать и записать в inventory

# новая нода (юзер дал IP + root-пароль + страну + домен)
scripts/setup-node.sh --id de-3 --ip 1.2.3.4 --domain de-3.proxy025.ru \
                      --country "🇩🇪 Германия 3" --hosting hostes --password 'rootpw'

# ёмкость канала для бара «СЕТЬ» (§9.3)
scripts/capacity-measure.sh --show
scripts/capacity-measure.sh --measure --write
```

Все скрипты понимают `--help`; коды выхода: `0` — чисто, `1` — есть расхождения/проблемы.

## Что скрипт НЕ делает

- Не трогает работающий `remnanode` (чтобы не потерять регистрацию ноды в панели).
- Не заводит Xray-инбаунд :443 — его создаёт юзер в панели `panel.025vpn.ru` (§5.8 справки).
- Не правит код мониторинга (`epyc-monitor-bot-live`) — он живёт отдельно; здесь только список нод.

## Открытые задачи

Актуальный статус — в конце [docs/HANDOFF.md](docs/HANDOFF.md) (§10) и в §9 исходной справки.
Кратко: залить FI-IP на монитор, снять и раскатать реальный egress монитора, замерить ёмкость.
