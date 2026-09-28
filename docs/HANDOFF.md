# proxy025 — кластер Remnawave-нод (panel.025vpn.ru) — ПЕРЕДАТОЧНАЯ СПРАВКА

_Составлено 2026-09-28. Самодостаточный документ для передачи в другой чат: как устроен кластер, что где лежит, полный рецепт разворачивания ноды, все текущие адреса, грабли и открытые вопросы._

---

## 1. Что это

Кластер **Remnawave-нод** сервиса **proxy025** (панель **panel.025vpn.ru**). Это НЕ pl-out экзиты (те — отдельный Xray/Reality-кластер `pl-out.proxy025.ru`, 6 польских серверов). Здесь — ноды: на каждой в docker крутится контейнер `remnanode`, внутри него Xray с VLESS/Reality-инбаундом на **:443** (selfsteal), фолбэк-таргет Reality — локальная nginx-заглушка на **127.0.0.1:9443** с LE-сертом под домен ноды.

Каждая нода в мониторинге видна в блоке **«Ноды»** таба **«025»** avoro-мониторинга (Mini App/веб-дашборд `@avoromonitor_bot`).

Роли по портам на каждой ноде:
- **:2222** — `remnanode` (NODE_PORT, процесс `rw-node`), связь с панелью.
- **:443** — Xray Reality selfsteal (инбаунд заводит ЮЗЕР в панели; со стороны сервера мы его не трогаем).
- **:9443** — nginx-заглушка (Reality fallback target), LE-серт под домен ноды.
- CrowdSec (агент + firewall-bouncer-iptables) — автономный, свой LAPI на каждой ноде.

---

## 2. Доступ / ключи / файлы (на Mac `~/Desktop/ClaudeCode`)

- **SSH-ключ ко всем нодам 025:** `~/Desktop/ClaudeCode/keys/025key` (pub — `025key.pub`). Вход: `ssh -i ~/Desktop/ClaudeCode/keys/025key -o IdentitiesOnly=yes root@<IP>`.
- **Первый вход на новую ноду** (пока ключа нет) — по root-паролю через `sshpass`, сразу заливаем pub-ключ в `~/.ssh/authorized_keys`.
- **Локальная копия кода мониторинга:** `~/Desktop/ClaudeCode/epyc-monitor-bot-live/` (бэкенд `backend/`, фронт `webapp/`, список нод `p025_nodes.json`).
- **Общий SECRET_KEY** для всех нод 025 (вставляется в docker-compose ДОСЛОВНО, В КАВЫЧКАХ) — см. раздел 6.

---

## 3. Сервер мониторинга (avoro) — ВАЖНО, переехал

Мониторинг («avoro», all-in-one: бот + Mini App + веб-дашборд + бэкенд-опрос нод) живёт НА avoro-экзите, а тот несколько раз менял адрес:

- было `194.48.217.130` (ключ `~/.ssh/avoro_ed25519`) — **МЁРТВ для нас**;
- **с 22.09 → `104.167.24.130`** (de-avoro-1-n, Debian13, ключ `~/Desktop/ClaudeCode/keys/hzhex_ed25519`), venv Python 3.13;
- 25.09 avoro-1 менял блок на `185.229.207.144/28` (шлюз .145, адреса .146-.158) — переустанавливали через IPMI; актуальный SSH-адрес монитора на момент составления **не подтверждён вживую** (см. открытый вопрос ниже).

Приложение на сервере: `/opt/epyc-monitor`, systemd-сервис `epyc-monitor`, nginx :8443. Веб-дашборд: `https://monitor.avoro.dev-agent.ru:8443` (Basic-Auth — см. secrets/monitor-basic-auth.txt).

**Список нод для блока «Ноды»:** файл `/opt/epyc-monitor/p025_nodes.json` — массив `[{"ip","country"}]`, бэкенд **перечитывает его каждый цикл** (обновление БЕЗ рестарта). Проверка живого поллинга на сервере:
```bash
cd /opt/epyc-monitor
curl -s -H "X-Web-Auth: $(grep ^WEB_AUTH_SECRET= .env|cut -d= -f2-)" http://127.0.0.1:8090/api/metrics \
  | ./venv/bin/python -c 'import sys,json;[print(n["country"],n["ip"],n.get("online")) for n in json.load(sys.stdin)["p025_nodes"]]'
```

**⚠️ ГРАБЛЯ ДОСТУПА (актуально 28.09):** и Mac, и сервер-монитор ходят по SSH под ОДНИМ egress-IP, когда Mac включён в avoro-VPN. Монитор пускает SSH только с доверенных IP. На 28.09 egress Mac стал `91.79.42.53` (VPN был отключён) → SSH на `104.167.24.130` тарпитит (banner-timeout, хотя :22 и :8443 открыты). Чтобы дотянуться до монитора — включить avoro-VPN на Mac (egress снова доверенный) ЛИБО добавить текущий IP Mac в SSH-allowlist монитора.

---

## 4. Блок «Ноды» в мониторинге — как устроено (код в `epyc-monitor-bot-live`)

- **Бэкенд:** `backend/p025nodemon.py` — класс `P025NodeMonitor`, SSH-опрос ключом `/opt/epyc-monitor/keys/025key` раз в ~20с; вместо `systemctl xray` смотрит статус docker-контейнера `remnanode` + слушателей :443/:9443. Читает ноды из `config.load_p025_nodes()` (файл `p025_nodes.json`) каждый цикл.
- **config.py:** `P025_NODES_FILE` + `load_p025_nodes()`.
- **app.py:** инстанс `p025nodemon`, payload `p025_nodes`, алерты `on_p025_node_sample`, задача стартует всегда.
- **Фронт:** `webapp/index.html` секция «🖥 Ноды · 025», `webapp/app.js` — `renderP025Nodes`/`p025NodeCard` (страна+IP+host, CPU/RAM/диск, remnanode up, Reality :443, заглушка :9443, RX/TX, коннекты, CrowdSec, баны, спарклайн).
- **Деплой правок кода** (если правился бэкенд/фронт): `rsync -az backend/ webapp/` на `/opt/epyc-monitor/` (НЕ трогать `.env`, `keys/`, `*_state.json`) + `systemctl restart epyc-monitor`. Для смены только списка нод правки кода не нужны — достаточно обновить `p025_nodes.json`.

---

## 5. Рецепт разворачивания НОВОЙ ноды 025 (по шагам)

Юзер даёт: **IP + root-пароль + страна + домен** (`xx.proxy025.ru`). Часто ноду (`remnanode`) уже поставил сам — тогда наша часть только заглушка+LE+CrowdSec+allowlist+мониторинг.

1. **Ключ:** первый вход `sshpass -p '<pwd>' ssh -o StrictHostKeyChecking=accept-new root@IP`, залить `025key.pub` в `~/.ssh/authorized_keys`. Дальше — только ключом.
2. **apt:** `apt update && apt upgrade -y`. **Ждать dpkg-lock** (фоновый `unattended-upgrades`/`apt-daily`): цикл `fuser /var/lib/dpkg/lock-frontend` — иначе `apt` падает на локе.
3. **remnanode** (если ещё не стоит): docker + `/opt/remnanode/docker-compose.yml` (см. раздел 6), `docker compose up -d`. **Если `remnanode` уже Up — НЕ пересоздавать** (не перетереть регистрацию).
4. **Заглушка nginx :9443** (Reality selfsteal target). `xver:0` в их Xray-конфиге ⇒ nginx **БЕЗ `proxy_protocol`**. Конфиг:
   ```nginx
   server {
       listen 127.0.0.1:9443 ssl http2;
       server_name _;
       ssl_certificate     /usr/local/etc/xray/self.crt;   # сначала self-signed, потом LE
       ssl_certificate_key /usr/local/etc/xray/self.key;
       ssl_protocols TLSv1.2 TLSv1.3;
       location / { root /var/www/selfsteal; index index.html; }
   }
   ```
   Self-signed для старта: `openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout self.key -out self.crt -days 3650 -subj "/CN=<домен>" -addext "subjectAltName=DNS:<домен>"`. Проверка: `curl -sk https://127.0.0.1:9443/` = 200.
5. **LE-серт под домен ноды** (когда DNS `<домен>`→IP ноды прогрузился, :80 свободен):
   ```bash
   certbot certonly --standalone -d <домен> --non-interactive --agree-tos -m valeron2003k@gmail.com --deploy-hook "systemctl restart nginx"
   # затем в selfsteal.conf заменить пути ssl_certificate* на /etc/letsencrypt/live/<домен>/{fullchain,privkey}.pem
   systemctl restart nginx   # ⚠️ именно RESTART, не reload — reload серт НЕ подхватывает!
   ```
   Проверка: `echo | openssl s_client -connect 127.0.0.1:9443 -servername <домен> | openssl x509 -noout -issuer` → должен быть Let's Encrypt. Если DNS не готов — оставить self-signed CN=домен, LE выпустить позже.
6. **CrowdSec 1:1 с pl-out** (native apt, свой LAPI):
   ```bash
   curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash
   apt install -y crowdsec crowdsec-firewall-bouncer-iptables   # mode iptables, INPUT
   cscli collections install crowdsecurity/{linux,sshd,nginx,base-http-scenarios,http-cve,whitelist-good-actors}
   # acquis.d: setup.linux.yaml (messages/syslog/kern.log→syslog), setup.nginx.yaml (/var/log/nginx/*.log→nginx), setup.sshd.yaml (auth.log/secure→syslog)
   ```
   **ГОЧА Ubuntu 26.04 (codename `resolute`):** packagecloud не знает resolute → `crowdsec` тянется из Ubuntu universe (старьё 1.4.6), bouncer'а нет. ФИКС: в `/etc/apt/sources.list.d/crowdsec_crowdsec.list` заменить `resolute`→`noble` (+удалить deb-src), `apt purge crowdsec && rm -rf /etc/crowdsec`, переустановить (получишь 1.8.1). **ГОЧА dpkg-lock:** ждать освобождения перед установкой.
7. **ОБЯЗАТЕЛЬНО allowlist монитора в CrowdSec** (иначе нода банит SSH-опрос):
   ```bash
   cscli allowlists create avoro-monitor -d "avoro monitor/mac egress"
   cscli allowlists add avoro-monitor 194.48.217.128/28
   cscli allowlists check 194.48.217.130   # должно быть allowlisted
   ```
   ⚠️ Диапазон `194.48.217.128/28` — egress СТАРОГО avoro (194.48.217.130). **Монитор с 22.09 на 104.167.24.130 — его egress в этот /28 НЕ входит.** Проверить актуальный egress монитора (`curl -s ifconfig.me` С САМОГО монитора) и при необходимости добавить его в allowlist на всех нодах, иначе ноды начнут банить опрос. **Это открытый вопрос (см. раздел 9).**
8. **Xray-инбаунд в панели** `panel.025vpn.ru` заводит ЮЗЕР (Reality :443, serverNames `deepl.com` + `*.proxy025.ru`, приватник из его конфига). Пока не заведёт — на ноде `:443` пусто (в мониторинге `443=0`), это норма.
9. **Мониторинг:** дописать ноду в `/opt/epyc-monitor/p025_nodes.json` (`{"ip":"...","country":"🇩🇪 Страна"}`), перечитается сам.

**Флапающие/свежесозданные машины** (провайдер ещё провижинит, banner-timeout вперемешку с успехом): длинный сетап гнать НЕ интерактивной сессией, а детачем — `scp` скрипт, `nohup flock -n /root/setup.lock bash /root/setup.sh > /root/setup.log 2>&1 &`, поллить лог до `DONE`. `flock`, НЕ `pgrep` (pgrep -f матчит саму команду запуска → ложное «already running»).

---

## 6. Секреты (вставлять ДОСЛОВНО)

**docker-compose.yml для remnanode** (`NODE_PORT=2222`, `SECRET_KEY` — общий для всех нод 025, В КАВЫЧКАХ как есть):

```yaml
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
      - SECRET_KEY=<ЗНАЧЕНИЕ В secrets/node-secret-key.txt, в git не хранится>
```

**Xray-инбаунд (Reality selfsteal), который панель раздаёт на ноду** — ключевые параметры (полный конфиг — у юзера в панели):
- `port: 443`, `network: raw`, `security: reality`, `xver: 0`
- `target: "127.0.0.1:9443"`, `spiderX: "/"`
- `privateKey: <в git не хранится — панель / secrets/xray-inbound.json>`
- `shortIds: ["1fd5d9","a3f9c2d7","6b1e8a4f","9d7c0e2a"]`
- `fingerprint: "chrome"`
- `serverNames: ["deepl.com","de.proxy025.ru","pl.proxy025.ru","nl.proxy025.ru","it.proxy025.ru","jp.proxy025.ru"]`

---

## 7. Все ноды кластера (актуальные адреса на 28.09.2026)

⚠️ **У этих провайдеров (hostes.io / play2go.cloud) IP РЕГУЛЯРНО МЕНЯЮТСЯ.** Симптом: нода вдруг OFF «no data after retries», ручной SSH на старый IP = banner-timeout (по старому IP уже чужая/мёртвая машина — это НЕ бан). Лечение: `dig <домен>` даёт новый IP (DNS ведёт домен), SSH туда ключом 025key (машина та же, опознаётся по hostname), обновить IP в `p025_nodes.json`.

| Страна (подпись) | Текущий IP | Домен | Hostname машины | Хостинг |
|---|---|---|---|---|
| 🇩🇪 Германия (Hostes) | 151.242.161.154 | de.proxy025.ru | 025-node-germ.hostes.io | Hostes |
| 🇩🇪 Германия 2 (Hostes) | 151.242.161.216 | de-2.proxy025.ru | 025-node-germ-2.hostes.io | Hostes |
| 🇯🇵 Япония | 31.76.91.243 | jp.proxy025.ru | (Ubuntu 24.04) | — |
| 🇮🇹 Италия | 31.77.154.126 | it.proxy025.ru | (Ubuntu 24.04) | — |
| 🇫🇮 Финляндия | **13.143.173.228** | fl.proxy025.ru | 025-node-FINLAND.play2go.cloud | play2go |
| 🇵🇱 Польша (Hostes) | 31.56.188.71 | pl.proxy025.ru | 025-node-poland.hostes.io | Hostes |
| 🇵🇱 Польша 2 (Hostes) | 31.59.125.208 | pl-2.proxy025.ru | 025-node-poland-2.hostes.io | Hostes |
| 🇳🇱 Нидерланды | 31.77.149.191 | nl.proxy025.ru | V-VPN-NETHERLANDS.play2go.cloud | play2go |

**Выведена из мониторинга (сервер жив, но в дашборде не показывается):**
| 🇸🇪 Швеция | 177.3.215.207 | se.proxy025.ru | 025-NODE-SWEEDEN.play2go.cloud | play2go — снята из `p025_nodes.json` 17.09 по просьбе юзера |

История смен IP: DE `151.242.160.222→.224→151.242.161.154`; DE2 `151.242.160.206→151.242.161.216`; FI `87.121.82.237→31.77.151.61→13.143.173.228`; SE `31.76.81.125→177.3.215.207`; PL `94.183.157.42→31.56.188.71`; PL2 `94.183.157.73→31.59.125.208`.

---

## 8. Грабли (собрано за сессии)

- **RESTART, не reload** после смены серта nginx — reload серт не подхватывает, отдаёт старый self-signed.
- **xver:0 ⇒ nginx без `proxy_protocol`** (у pl-out было xver:1 с proxy_protocol — не путать).
- **Ubuntu 26.04 (resolute)**: packagecloud-репо CrowdSec битый → правь на `noble`, переустанавливай (иначе 1.4.6 из universe + нет bouncer).
- **dpkg-lock**: фоновый `unattended-upgrades`/`apt-daily` держит лок; ЖДАТЬ перед apt. **Зависший apt** (видел на FI — фоновый `apt-get update` висел ~12ч из-за таймаута сети, держал лок): `systemctl stop apt-daily.service apt-daily.timer && pkill -9 -f apt.systemd.daily`, затем повторить.
- **Флапающие свежие ноды**: сетап детачем через `nohup flock … &` + поллинг лога, НЕ интерактивной сессией.
- **allowlist монитора в CrowdSec обязателен**, иначе нода банит SSH-опрос (Mac и монитор ходят под одним egress-IP через avoro-VPN).
- **IP нод меняются** — при OFF первым делом `dig <домен>`.
- **DNS после смены IP** должен указывать на новый IP не только для прокси, но и для LE-автопродления (certbot standalone :80).

---

## 9. Открытые вопросы / что доделать

1. **🇫🇮 Финляндия: `p025_nodes.json` на сервере ещё НЕ обновлён** на новый IP `13.143.173.228` (локально обновлён). Не удалось залить — монитор переехал на `104.167.24.130`, а SSH туда с текущего egress Mac (`91.79.42.53`, VPN был отключён) тарпитится. Долить: включить avoro-VPN на Mac (или allowlist IP Mac на мониторе), затем `rsync p025_nodes.json` ЛИБО на самом мониторе: `sed -i 's/31.77.151.61/13.143.173.228/' /opt/epyc-monitor/p025_nodes.json`.
2. **Актуальный SSH-адрес и egress монитора** после переездов 22.09 (`104.167.24.130`) и 25.09 (блок `185.229.207.144/28`) — уточнить вживую. От egress монитора зависит, какой IP должен быть в CrowdSec-allowlist на нодах (сейчас там старый `194.48.217.128/28`).
3. **Ёмкость канала 025-нод (`capacity.json`) не замерена** — у нескольких нод сменились IP, старые записи вычистились. Нужен нагрузочный замер и запись в `/opt/epyc-monitor/capacity.json`, иначе бар «СЕТЬ» в дашборде врёт.
4. **DE2 / PL2**: инбаунд :443 в панели заводит юзер (на момент сетапа было `443=0`).

---

## 10. Обновления к справке (28.09.2026, добавлено при переносе в репозиторий)

Секреты из §3/§6 в этом файле **вырезаны** — они лежат вне git, см. `secrets/README.md`.
Источником правды по адресам теперь служит `inventory/nodes.json`, а не таблица §7
(таблица оставлена как исторический срез).

**Проверено резолвом DNS 28.09 (из облачной сессии, SSH недоступен):**

- Все 9 доменов нод резолвятся ровно в те IP, что в таблице §7 — дрейфа на эту дату нет.
- `monitor.avoro.dev-agent.ru` → **185.229.207.147**. Это внутри блока `185.229.207.144/28`,
  на который avoro-1 переехал 25.09 (§3). Значит рабочий SSH-адрес монитора — `185.229.207.147`,
  а `104.167.24.130` из §3 больше не актуален. Записан в `inventory/nodes.json` → `monitor.ip`.
- `panel.025vpn.ru` → `109.196.101.231`.
- `pl-out.proxy025.ru` → 6 адресов: `31.59.125.243`, `31.59.125.223`, `31.59.125.88`,
  `31.59.125.177`, `31.59.125.161`, `31.56.188.205` (это отдельный кластер экзитов, не ноды).
- На всех 8 нодах из мониторинга **:443 принимает TLS-соединение** — то есть Reality-инбаунд
  заведён, включая DE2 и PL2. Открытый вопрос §9.4, судя по всему, закрыт; подтвердить
  окончательно можно только с ноды (`scripts/healthcheck.sh`).

**Что осталось незакрытым (требует SSH с Мака):**

1. §9.1 — FI `13.143.173.228` в `p025_nodes.json` **на самом мониторе**:
   `scripts/monitor-sync.sh` покажет расхождение и зальёт.
2. §9.2 — **egress монитора** так и не снят вживую. Его нельзя вывести из DNS: наружу
   монитор может ходить не тем адресом, на который резолвится его имя. Снимать только
   с самого монитора и сразу раскатывать в allowlist: `scripts/crowdsec-allowlist.sh --from-monitor --apply`.
   Пока в `inventory/nodes.json` стоит старый `194.48.217.128/28` и `egress_verified: false`.
3. §9.3 — ёмкость не замерена: `scripts/capacity-measure.sh --measure --write`
   (схему `capacity.json` перед записью сверить с `backend/app.py`).
