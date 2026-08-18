# BEAM Control Panel

**Self-hosted панель управления Linux-серверами с глубокой интеграцией в экосистему BEAM
(Elixir, Erlang, Phoenix).**

Панель управляет **основным сервером** (тем, на котором она сама запущена) и любым числом
**дополнительных серверов**, подключаемых по SSH: показывает проекты, снимает метрики
системы и BEAM, ставит тулчейн на чистый Ubuntu и выполняет полный цикл деплоя.

[English](README.md) · [План реализации](docs/PLAN.md)

---

## Что уже работает

| Раздел | Возможности |
|---|---|
| **Серверы** | Основной (локальный) + дополнительные по SSH · проверка связи · факты об ОС и тулчейне · группы/кластеры · теги и роли |
| **Мониторинг** | CPU, RAM, swap, диск, сеть, LA, аптайм, число процессов · живые графики через LiveView · кольцевой буфер в ETS + история в PostgreSQL · circuit breaker на недоступные узлы |
| **Проекты** | Автообнаружение развёрнутых приложений · Phoenix / Elixir release / mix-приложение / Erlang release · env-переменные (шифрованные) · генерация systemd-юнита и env-файла · start/stop/restart · health-check |
| **Деплой** | Пайплайн из 11 шагов с живым логом · сборка релиза на сервере · миграции · health-check · автоматический откат при неудаче · ручной откат на любой релиз |
| **BEAM / OTP** | Планировщики, память по типам, процессы, ETS, порты, атомы · дерево супервизоров · список приложений · distribution и соседние ноды · удалённая консоль (rpc) |
| **Установка ПО** | Провижининг чистого Ubuntu 24.04/26.04: Erlang, Elixir, Node, PostgreSQL, nginx, certbot, Docker, ufw, fail2ban, sysctl-тюнинг, swap, пользователь деплоя |
| **Логи** | `journalctl` в реальном времени с фильтром, паузой и поиском |
| **Безопасность** | Сессии + pbkdf2 · TOTP 2FA · RBAC (admin / operator / viewer) · шифрование секретов AES-256-GCM · аудит всех изменений · блокировка после неудачных входов |
| **Интеграции** | REST API с Bearer-токенами и scope · уведомления в webhook, Telegram, Slack, Discord, e-mail |

---

## Быстрый старт: чистый сервер Ubuntu 24.04 / 26.04

```bash
git clone https://github.com/rurumiru/BEAM-Control-Panel.git
cd BEAM-Control-Panel
sudo bash scripts/install-ubuntu.sh --domain panel.example.com --letsencrypt
```

Скрипт полностью автономен и идемпотентен. Он:

1. ставит зависимости — Erlang/OTP 27, Elixir 1.18, Node.js 22, PostgreSQL, nginx;
2. создаёт системного пользователя `beampanel` и каталог `/opt/beam-panel`;
3. генерирует `SECRET_KEY_BASE` и ключ шифрования, кладёт их в `/etc/beam-panel/beam-panel.env`;
4. создаёт роль и базу в PostgreSQL;
5. собирает OTP-релиз и ставит systemd-юнит `beam-panel`;
6. накатывает миграции и создаёт администратора;
7. настраивает nginx (и, по флагу, сертификат Let's Encrypt);
8. генерирует SSH-ключ, которым панель будет ходить на управляемые серверы, и печатает его.

Полезные флаги:

```
--domain <host>          домен для nginx
--port <port>            порт приложения (по умолчанию 4000)
--admin-email <email>    e-mail администратора
--admin-password <pw>    пароль (иначе сгенерируется и будет напечатан)
--email <email>          e-mail для Let's Encrypt (по умолчанию --admin-email)
--no-nginx               без nginx
--letsencrypt            выпустить сертификат (требует --domain)
--otp 27 --elixir 1.18.4 версии тулчейна
```

Обновление:

```bash
sudo bash scripts/update.sh --pull
```

Скрипт делает дамп БД, собирает новый релиз рядом со старым, переключает симлинк
и **автоматически откатывается**, если служба не поднялась.

### Docker

```bash
cp .env.example .env
# заполните POSTGRES_PASSWORD, SECRET_KEY_BASE, BEAM_PANEL_CLOAK_KEY
docker compose up -d --build
```

### Подготовка управляемого узла

Панель умеет ставить тулчейн на дополнительный сервер сама — раздел
**Сервер → Установка ПО**. Тот же скрипт можно применить вручную:

```bash
mix beam_panel.gen.bootstrap --all       # обновит scripts/bootstrap-node.sh
scp scripts/bootstrap-node.sh root@node:/tmp/
ssh root@node 'bash /tmp/bootstrap-node.sh'
```

---

## Разработка

```bash
mix setup                # зависимости, БД, ассеты
mix run priv/repo/seeds.exs
mix phx.server           # http://localhost:4000
mix test                 # 127 тестов
mix precommit            # компиляция без warnings + формат + тесты
```

Требуется Elixir 1.18+, Erlang/OTP 25+, PostgreSQL 14+.

---

## Архитектура

```
BeamPanelWeb            LiveView UI + REST API + аутентификация и RBAC
      │
BeamPanel.Servers       инвентарь узлов, службы, системные действия
BeamPanel.Projects      BEAM-приложения, discovery, env, systemd
BeamPanel.Deploy        пайплайн, runner, откат, история
BeamPanel.Provision     playbook для Ubuntu, потоковое выполнение
BeamPanel.Monitor       GenServer на сервер, ETS-кольцо, PubSub
BeamPanel.Beam          интроспекция OTP через rpc + term_to_binary
      │
BeamPanel.Remote        единый фасад: SSH (OTP :ssh) либо локальный shell
```

Ключевые решения:

* **Никаких внешних агентов.** Всё делается по SSH встроенным в OTP приложением
  `:ssh` — на управляемом сервере не нужно ничего устанавливать.
* **Локальный и удалённый сервер неотличимы** для верхних слоёв: `BeamPanel.Remote`
  подставляет либо SSH-канал, либо `System.cmd`.
* **Интроспекция без парсинга текста.** Код выполняется на целевой ноде через
  `bin/<release> rpc`, результат возвращается как `term_to_binary` в base64 и
  декодируется в `:safe`-режиме — на выходе структурированные данные, а не вывод шелла.
* **Секреты шифруются в БД.** SSH-ключи, cookie и env-переменные проектов — AES-256-GCM
  (`cloak_ecto`), ключ живёт только в переменной окружения.

Подробности — в [docs/PLAN.md](docs/PLAN.md).

---

## REST API

```bash
curl -H "Authorization: Bearer bcp_..." https://panel.example.com/api/v1/status
curl -H "Authorization: Bearer bcp_..." https://panel.example.com/api/v1/servers
curl -X POST -H "Authorization: Bearer bcp_..." \
     https://panel.example.com/api/v1/projects/1/deploy
```

| Метод | Путь | Scope |
|---|---|---|
| GET | `/api/v1/status` | read |
| GET | `/api/v1/servers` · `/servers/:id` · `/servers/:id/metrics` | read |
| POST | `/api/v1/servers/:id/check` | deploy |
| GET | `/api/v1/projects` · `/projects/:id` | read |
| POST | `/api/v1/projects/:id/deploy` · `/restart` · `/rollback` | deploy |
| GET | `/api/v1/deployments` · `/deployments/:id` | read |

Токены создаются в **Настройки → API-токены**, показываются один раз.

---

## Безопасность

* Все секреты в БД зашифрованы `BEAM_PANEL_CLOAK_KEY` (AES-256-GCM).
  **Потеря ключа = потеря доступа к SSH-ключам и env проектов** — храните его с бэкапами.
* Роли: `admin` (всё, включая пользователей и удалённую консоль), `operator`
  (деплой, рестарт, провижининг), `viewer` (только чтение).
* Установщик выдаёт пользователю `beampanel` беспарольный `sudo` на локальном
  сервере (`/etc/sudoers.d/90-beam-panel`). Это необходимо: панель создаёт
  каталоги деплоя, пишет systemd-юниты, управляет службами и ставит пакеты.
  Если панель не должна администрировать основной сервер — удалите этот файл,
  управление удалёнными узлами по SSH продолжит работать.
* Каждое изменяющее действие пишется в аудит с указанием пользователя и IP.
* Удалённое выполнение кода на ноде (`OTP → Консоль`) доступно только администраторам.
* Панель ставит себя за nginx; в проде обязательно включите HTTPS.

---

## Дорожная карта

Файловый менеджер · UI для firewall · домены и SSL · управление Docker ·
управление БД · бэкапы · мониторинг Oban/Quantum · веб-терминал · hot code upgrade ·
плагины.

---

## Лицензия

MIT
