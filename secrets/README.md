# secrets/ — в git не попадает (см. .gitignore)

Что сюда положить на своей машине:

| файл | что это | где взять |
|---|---|---|
| `node-secret-key.txt` | `SECRET_KEY` для `docker-compose.yml` ноды (общий для всех нод 025, одна строка, БЕЗ кавычек и переводов строк) | исходная передаточная справка, §6; либо панель `panel.025vpn.ru` |
| `monitor-basic-auth.txt` | логин/пароль Basic-Auth веб-дашборда `https://monitor.avoro.dev-agent.ru:8443` | исходная справка, §3 |
| `xray-inbound.json` | приватник Reality и полный инбаунд :443 | панель, конфиг инбаунда |

`scripts/setup-node.sh` читает `node-secret-key.txt` (или env `NODE_SECRET_KEY`).

⚠️ В `docker-compose.yml` `SECRET_KEY` вставляется ДОСЛОВНО, вместе с кавычками, если они были
в исходном значении — см. §6 справки. Файл `node-secret-key.txt` должен содержать ровно то,
что подставляется после `SECRET_KEY=`.

SSH-ключи держим не здесь, а там же, где и раньше: `~/Desktop/ClaudeCode/keys/025key`
(ноды) и `~/Desktop/ClaudeCode/keys/hzhex_ed25519` (монитор). Пути настраиваются в
`inventory/nodes.json` или через env `SSH_KEY` / `MONITOR_SSH_KEY`.
