# BEAM Control Panel — План реализации

> Документ фиксирует архитектуру, объём работ и порядок реализации.
> Версия плана: 1.0 · Целевой релиз: v0.1.0 «Foundation»

---

## 1. Цель первой очереди

Панель управления, которая контролирует **основной сервер** (тот, где она сама
запущена) и **дополнительные серверы** (подключаемые по SSH), с фокусом на
экосистему BEAM:

| Возможность | Что означает на практике |
|---|---|
| **Видеть проекты** | Автообнаружение Elixir/Erlang/Phoenix-приложений: mix-релизы, systemd-юниты, запущенные `beam.smp`, каталоги с `mix.exs` / `rebar.config` |
| **Мониторить** | Системные метрики (CPU/RAM/swap/диск/сеть/LA/uptime) + BEAM-метрики (процессы, планировщики, память по типам, ETS, порты, атомы, run queue, дерево супервизоров) |
| **Устанавливать** | Провижининг чистого Ubuntu 24.04/26.04: Erlang/OTP, Elixir, Node, PostgreSQL, nginx, certbot, Docker, сборочные зависимости — одной кнопкой |
| **Полноценно всё делать** | Деплой из Git → сборка релиза → миграции → systemd → health-check → rollback; управление env, логами, службами, кластером |

---

## 2. Модель домена

```
User ──< ApiToken
  │
  └──< AuditLog

Server (main | remote)
  ├── connection: local | ssh
  ├── facts (os, arch, cpu, ram, версии OTP/Elixir)
  ├── MetricSample (кольцо в ETS + агрегаты в PostgreSQL)
  └──< Project
         ├── EnvVar (шифруется Cloak)
         ├── BeamNode (имя ноды + cookie для distribution)
         └──< Deployment (лог в реальном времени)

ServerGroup (кластер) ──< Server
```

### Ключевые сущности

* **Server** — `name, hostname, ssh_port, ssh_user, auth_method (key|password|local), ssh_private_key (encrypted), tags, group, role, status, facts, last_seen_at`
* **Project** — `server_id, name, slug, kind (phoenix|elixir_release|erlang_release|mix_app), repo_url, branch, deploy_path, release_name, service_name, http_port, health_url, node_name, node_cookie (encrypted), auto_migrate, autostart`
* **Deployment** — `project_id, user_id, ref, status (pending|running|success|failed|rolled_back), started_at, finished_at, log, release_version, previous_version`
* **AuditLog** — `user_id, action, resource_type, resource_id, metadata, ip, inserted_at`

---

## 3. Архитектура транспорта

Работа с удалёнными серверами построена **на встроенном в OTP приложении `:ssh`** —
никаких внешних бинарников, одинаково работает на Linux и Windows.

```
BeamPanel.Remote            — фасад: run/3, stream/4, upload/4, write_file/4
BeamPanel.Remote.SSH        — exec-канал OTP :ssh, потоковый stdout/stderr, exit code
BeamPanel.Remote.Local      — та же сигнатура через System.cmd (основной сервер)
BeamPanel.Remote.Facts      — сбор фактов об ОС и версиях
BeamPanel.Remote.Metrics    — парсинг /proc, df, ps
```

Благодаря единому фасаду «основной сервер» и «дополнительный» неотличимы для
верхних слоёв: контексты, LiveView и деплой-пайплайн работают с ними одинаково.

### Глубокая интроспекция BEAM

Два уровня:

1. **Без distribution** — `bin/<release> rpc "..."` через SSH + парсинг `ps`.
   Работает всегда, ничего не требует от целевого приложения.
2. **Через distribution** — панель как hidden-нода подключается к ноде приложения
   и вызывает `:erpc.call/4`: `:erlang.system_info`, `:erlang.memory`,
   `:application.which_applications`, `:supervisor.which_children`, `:ets.all`,
   `Process.info`. Даёт живое дерево супервизоров без оверхеда shell.

---

## 4. Подсистемы

### 4.1 Monitoring

`BeamPanel.Monitor.Collector` — GenServer на каждый сервер:

* тик каждые N секунд, одна сессия на все метрики;
* парсит `/proc/stat`, `/proc/meminfo`, `/proc/loadavg`, `df`, `/proc/net/dev`;
* кладёт сэмпл в ETS-кольцо (последние 720 точек) и шлёт в `Phoenix.PubSub`;
* LiveView подписаны на топик `server:<id>:metrics`;
* circuit breaker: после N ошибок сервер помечается `unreachable`, интервал растёт.

### 4.2 Projects / Discovery

`BeamPanel.Projects.Discovery` сканирует сервер:

* `systemctl list-units --type=service` → юниты с `/bin/<name> start` в ExecStart;
* `find <roots> -maxdepth 4 -name mix.exs -o -name rebar.config`;
* `ps -eo pid,args | grep beam.smp` → `-name`/`-sname`, `-setcookie`, путь релиза;
* результат — кандидаты, которые оператор одним кликом превращает в Project.

### 4.3 Deploy pipeline

`BeamPanel.Deploy.Pipeline` — декларативный список шагов, исполняется
`BeamPanel.Deploy.Runner` (Task под DynamicSupervisor); каждая строка вывода
транслируется в PubSub → LiveView показывает лог в реальном времени.

```
 1. preflight    доступность, свободное место, версии тулчейна
 2. fetch        git clone/fetch + checkout ref
 3. deps         mix deps.get --only prod
 4. compile      MIX_ENV=prod mix compile
 5. assets       mix assets.deploy (для Phoenix)
 6. release      MIX_ENV=prod mix release --overwrite
 7. migrate      bin/<rel> eval Release.migrate (если auto_migrate)
 8. systemd      генерация/обновление unit + daemon-reload
 9. restart      systemctl restart
10. healthcheck  HTTP GET health_url с ретраями
11. finalize     симлинк current → release, запись версии, уведомления
```

Ошибка на любом шаге → `rollback` на предыдущий релиз (симлинк + restart).

### 4.4 Provisioning (чистый Ubuntu 24.04 / 26.04)

`BeamPanel.Provision.Playbook` строит идемпотентный bash-скрипт из выбранных
компонентов и исполняет через SSH с потоковым выводом:

* `base` — apt update, build-essential, git, curl, unzip, locales
* `erlang` — Erlang/OTP из Erlang Solutions repo
* `elixir` — Elixir 1.18/1.19
* `nodejs` — NodeSource 22 LTS
* `postgres` — PostgreSQL 16/17 + роль и БД
* `nginx` — nginx + шаблон reverse-proxy
* `certbot` — Let us Encrypt (certbot + плагин nginx)
* `docker` — Docker CE + compose plugin
* `hardening` — ufw, fail2ban, sshd_config, unattended-upgrades
* `tuning` — swapfile, sysctl под BEAM (somaxconn, file-max, swappiness)
* `deploy_user` — системный пользователь, каталоги, права

### 4.5 Logs

Потоковый `journalctl -u <service> -f -o cat` через SSH exec-канал → PubSub →
LiveView с фильтром, поиском, паузой и скачиванием.

### 4.6 Безопасность

* Аутентификация: session + `pbkdf2` (без C-компилятора), TOTP 2FA.
* RBAC: `admin` / `operator` / `viewer`; проверки в контекстах и роутере.
* Все секреты (SSH-ключи, cookie, env) — AES-256-GCM через `cloak_ecto`.
* Аудит каждого мутирующего действия.
* REST API по Bearer-токенам со сроком жизни и отзывом.

---

## 5. Стек

| Слой | Технологии |
|---|---|
| Backend | Elixir 1.18+, Phoenix 1.8, Phoenix LiveView 1.2, Ecto/PostgreSQL |
| Транспорт | OTP `:ssh`, `:ssh_sftp`, Erlang distribution, `:erpc` |
| Frontend | LiveView, Tailwind CSS 4, daisyUI 5, Heroicons |
| Runtime | Bandit, OTP releases, systemd, Docker |
| Данные | PostgreSQL 16+, ETS (горячие метрики) |

---

## 6. Порядок работ

| Этап | Содержание |
|---|---|
| 0 | Скелет Phoenix, зависимости, конфиг, Cloak vault |
| 1 | Accounts, RBAC, 2FA, сессии, аудит, seeds |
| 2 | Remote-слой: SSH/local exec, sftp, facts |
| 3 | Servers: CRUD, проверка связи, группы/кластеры |
| 4 | Monitor: сбор метрик, ETS-хранилище, PubSub |
| 5 | Projects: схема, discovery, env vars, управление сервисом |
| 6 | Deploy: pipeline, runner, стриминг лога, rollback |
| 7 | BEAM/OTP интроспекция + кластер |
| 8 | Provisioning Ubuntu 24.04/26.04 |
| 9 | Логи, уведомления, REST API |
| 10 | LiveView UI (dashboard, серверы, проекты, деплой, OTP, логи) |
| 11 | Деплой самой панели: Docker, compose, systemd, install.sh |

---

## 7. Дальше (v0.2+)

Файловый менеджер · Firewall UI · SSL/домены · Docker UI · Управление БД ·
Бэкапы · Oban/Quantum мониторинг · Плагины · Web-терминал · Hot code upgrade.
