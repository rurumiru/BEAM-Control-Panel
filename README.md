# BEAM Control Panel

**A self-hosted control panel for Linux servers with first-class support for the BEAM
ecosystem (Elixir, Erlang, Phoenix).**

It manages the **main server** (the host it runs on) and any number of **additional
servers** reached over SSH: discovers projects, collects system and BEAM metrics,
installs the toolchain on a clean Ubuntu box, and runs the full deployment cycle.

[Русский](README_RU.md) · [Implementation plan](docs/PLAN.md)

---

## What works today

| Area | Capabilities |
|---|---|
| **Servers** | Local main server + SSH-reachable nodes · connectivity checks · OS and toolchain facts · groups/clusters · tags and roles |
| **Monitoring** | CPU, RAM, swap, disk, network, load average, uptime, process count · live LiveView charts · ETS ring buffer plus PostgreSQL history · circuit breaker for unreachable hosts |
| **Projects** | Auto-discovery of deployed applications · Phoenix / Elixir release / mix app / Erlang release · encrypted environment variables · systemd unit and env file generation · start/stop/restart · health checks |
| **Deployment** | 11-step pipeline with live log streaming · release built on the target host · migrations · health check · automatic rollback on failure · manual rollback to any release |
| **BEAM / OTP** | Schedulers, memory by type, processes, ETS, ports, atoms · supervision tree · application list · distribution and peer nodes · remote console (rpc) |
| **Provisioning** | Clean Ubuntu 24.04/26.04: Erlang, Elixir, Node, PostgreSQL, nginx, certbot, Docker, ufw, fail2ban, sysctl tuning, swap, deploy user |
| **Logs** | Live `journalctl` streaming with filter, pause and search |
| **Security** | Sessions + pbkdf2 · TOTP 2FA · RBAC (admin / operator / viewer) · AES-256-GCM secret encryption · full audit trail · lockout after failed logins |
| **Integrations** | REST API with scoped bearer tokens · notifications to webhook, Telegram, Slack, Discord, e-mail |

---

## Quick start on a clean Ubuntu 24.04 / 26.04 server

```bash
git clone https://github.com/rurumiru/BEAM-Control-Panel.git
cd BEAM-Control-Panel
sudo bash scripts/install-ubuntu.sh --domain panel.example.com --letsencrypt
```

The installer is self-contained and idempotent. It:

1. installs dependencies — Erlang/OTP 27, Elixir 1.18, Node.js 22, PostgreSQL, nginx;
2. creates the `beampanel` system user and `/opt/beam-panel`;
3. generates `SECRET_KEY_BASE` and the encryption key into `/etc/beam-panel/beam-panel.env`;
4. creates the PostgreSQL role and database;
5. builds an OTP release and installs the `beam-panel` systemd unit;
6. runs migrations and creates the administrator;
7. configures nginx (and, with the flag, a Let's Encrypt certificate);
8. generates the SSH key the panel will use to reach managed servers, and prints it.

Useful flags:

```
--domain <host>          hostname for nginx
--port <port>            application port (default 4000)
--admin-email <email>    administrator e-mail
--admin-password <pw>    password (generated and printed when omitted)
--no-nginx               skip nginx
--letsencrypt            issue a certificate (requires --domain)
--otp 27 --elixir 1.18.4 toolchain versions
```

Updating:

```bash
sudo bash scripts/update.sh --pull
```

It dumps the database, builds the new release alongside the old one, flips the
symlink and **rolls back automatically** if the service fails to come up.

### Docker

```bash
cp .env.example .env
# fill in POSTGRES_PASSWORD, SECRET_KEY_BASE, BEAM_PANEL_CLOAK_KEY
docker compose up -d --build
```

### Preparing a managed node

The panel can install the toolchain on an additional server itself — see
**Server → Install software**. The same script can be applied by hand:

```bash
mix beam_panel.gen.bootstrap --all       # refreshes scripts/bootstrap-node.sh
scp scripts/bootstrap-node.sh root@node:/tmp/
ssh root@node 'bash /tmp/bootstrap-node.sh'
```

---

## Development

```bash
mix setup                # dependencies, database, assets
mix run priv/repo/seeds.exs
mix phx.server           # http://localhost:4000
mix test                 # 121 tests
mix precommit            # warnings-as-errors compile + format + tests
```

Requires Elixir 1.17+, Erlang/OTP 26+, PostgreSQL 14+.

---

## Architecture

```
BeamPanelWeb            LiveView UI + REST API + auth and RBAC
      │
BeamPanel.Servers       host inventory, services, system actions
BeamPanel.Projects      BEAM applications, discovery, env, systemd
BeamPanel.Deploy        pipeline, runner, rollback, history
BeamPanel.Provision     Ubuntu playbook, streamed execution
BeamPanel.Monitor       one GenServer per server, ETS ring, PubSub
BeamPanel.Beam          OTP introspection via rpc + term_to_binary
      │
BeamPanel.Remote        single facade: SSH (OTP :ssh) or local shell
```

Key decisions:

* **No agents.** Everything happens over SSH using OTP's built-in `:ssh`
  application — nothing needs to be installed on managed servers.
* **Local and remote hosts are indistinguishable** to upper layers:
  `BeamPanel.Remote` swaps in either an SSH channel or `System.cmd`.
* **Introspection without screen scraping.** Code runs on the target node through
  `bin/<release> rpc`, the result comes back as base64 `term_to_binary` and is decoded
  in `:safe` mode — structured data, not shell output.
* **Secrets are encrypted at rest.** SSH keys, cookies and project env vars use
  AES-256-GCM (`cloak_ecto`); the key lives only in the environment.

See [docs/PLAN.md](docs/PLAN.md) for details.

---

## REST API

```bash
curl -H "Authorization: Bearer bcp_..." https://panel.example.com/api/v1/status
curl -H "Authorization: Bearer bcp_..." https://panel.example.com/api/v1/servers
curl -X POST -H "Authorization: Bearer bcp_..." \
     https://panel.example.com/api/v1/projects/1/deploy
```

| Method | Path | Scope |
|---|---|---|
| GET | `/api/v1/status` | read |
| GET | `/api/v1/servers` · `/servers/:id` · `/servers/:id/metrics` | read |
| POST | `/api/v1/servers/:id/check` | deploy |
| GET | `/api/v1/projects` · `/projects/:id` | read |
| POST | `/api/v1/projects/:id/deploy` · `/restart` · `/rollback` | deploy |
| GET | `/api/v1/deployments` · `/deployments/:id` | read |

Tokens are created under **Settings → API tokens** and shown exactly once.

---

## Security

* Every secret in the database is encrypted with `BEAM_PANEL_CLOAK_KEY` (AES-256-GCM).
  **Losing the key means losing access to stored SSH keys and project env vars** —
  keep it with your backups.
* Roles: `admin` (everything, including users and the remote console), `operator`
  (deploy, restart, provision), `viewer` (read-only).
* Every mutating action is written to the audit log with the user and IP.
* Remote code execution on a node (`OTP → Console`) is admin-only.
* The panel installs itself behind nginx; always enable HTTPS in production.

---

## Roadmap

File manager · firewall UI · domains and SSL · Docker management · database
management · backups · Oban/Quantum monitoring · web terminal · hot code upgrade ·
plugins.

---

## License

MIT
