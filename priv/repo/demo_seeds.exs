# Demo data for documentation screenshots and for exploring the panel locally.
#
#     MIX_ENV=dev mix run priv/repo/demo_seeds.exs
#
# Creates a small fleet with plausible metrics, projects, deployments and audit
# entries. Monitoring is disabled on the fake servers so no SSH is attempted.
#
# This script is NOT used by the installer.

alias BeamPanel.{Repo, Accounts, Servers, Projects, Audit, Notifications}
alias BeamPanel.Deploy.Deployment

Repo.delete_all(BeamPanel.Deploy.Deployment)
Repo.delete_all(BeamPanel.Projects.EnvVar)
Repo.delete_all(BeamPanel.Projects.Project)
Repo.delete_all(BeamPanel.Servers.MetricSample)
Repo.delete_all(BeamPanel.Servers.Server)
Repo.delete_all(BeamPanel.Servers.ServerGroup)
Repo.delete_all(BeamPanel.Audit.AuditLog)
Repo.delete_all(BeamPanel.Notifications.Channel)

admin =
  Accounts.get_user_by_email("admin@example.com") ||
    (
      {:ok, user} =
        Accounts.create_root_user(%{
          "email" => "admin@example.com",
          "name" => "Ирина Соколова",
          "password" => "demo-password-1234"
        })

      user
    )

for {email, name, role} <- [
      {"operator@example.com", "Павел Ким", "operator"},
      {"viewer@example.com", "Анна Гросс", "viewer"}
    ] do
  Accounts.get_user_by_email(email) ||
    Accounts.register_user(%{
      "email" => email,
      "name" => name,
      "role" => role,
      "password" => "demo-password-1234"
    })
end

{:ok, cluster} =
  Servers.create_group(%{"name" => "EU кластер", "description" => "Франкфурт, три узла"})

key = """
-----BEGIN OPENSSH PRIVATE KEY-----
ZGVtby1rZXktZm9yLXNjcmVlbnNob3RzLW9ubHktbm90LXVzYWJsZQ==
-----END OPENSSH PRIVATE KEY-----
"""

defmodule Demo do
  def facts(otp, elixir, opts \\ []) do
    %{
      "os_pretty" => Keyword.get(opts, :os, "Ubuntu 24.04.1 LTS"),
      "os_name" => "Ubuntu",
      "os_version" => "24.04",
      "kernel" => "6.8.0-45-generic",
      "arch" => "x86_64",
      "cpu_cores" => Keyword.get(opts, :cores, 8),
      "cpu_model" => "AMD EPYC 7763 64-Core Processor",
      "mem_total_mb" => Keyword.get(opts, :mem, 16_384),
      "virt" => "kvm",
      "erlang" => otp,
      "elixir" => elixir,
      "rebar3" => "yes",
      "node" => "v22.11.0",
      "git" => "2.43.0",
      "docker" => Keyword.get(opts, :docker, "27.3.1"),
      "nginx" => "1.24.0",
      "postgres" => Keyword.get(opts, :pg, "16.4"),
      "systemd" => "255",
      "epmd_names" => "name storefront at port 4369;"
    }
  end

  # A believable metrics series: a slow sine plus jitter, so sparklines look real.
  def series(server_id, base_cpu, base_mem, disk_percent, points \\ 90) do
    now = DateTime.utc_now()

    for i <- 0..(points - 1) do
      phase = i / 9.0
      cpu = clamp(base_cpu + :math.sin(phase) * 12 + jitter(6))
      mem = clamp(base_mem + :math.sin(phase / 2.5) * 4 + jitter(2))

      metrics = %{
        cpu_percent: Float.round(cpu, 1),
        memory: %{
          total: 16 * 1024 * 1024 * 1024,
          used: round(16 * 1024 * 1024 * 1024 * mem / 100),
          available: round(16 * 1024 * 1024 * 1024 * (100 - mem) / 100),
          cached: 2 * 1024 * 1024 * 1024,
          buffers: 512 * 1024 * 1024,
          swap_total: 2 * 1024 * 1024 * 1024,
          swap_used: 180 * 1024 * 1024,
          percent: Float.round(mem, 1)
        },
        disk: %{
          total: 160 * 1024 * 1024 * 1024,
          used: round(160 * 1024 * 1024 * 1024 * disk_percent / 100),
          available: round(160 * 1024 * 1024 * 1024 * (100 - disk_percent) / 100),
          percent: disk_percent * 1.0
        },
        load: %{
          load1: Float.round(cpu / 25, 2),
          load5: Float.round(cpu / 28, 2),
          load15: Float.round(cpu / 32, 2)
        },
        uptime: 1_182_000 + i * 10,
        net: %{
          rx: 0,
          tx: 0,
          rx_rate: round(1_400_000 + :math.sin(phase) * 600_000 + jitter(120_000)),
          tx_rate: round(820_000 + :math.cos(phase) * 400_000 + jitter(90_000))
        },
        process_count: 240 + rem(i, 17),
        beam_processes: beam_processes(),
        recorded_at: DateTime.add(now, -(points - i) * 10, :second)
      }

      # Persist as well: the panel warms its in-memory ring from these rows at
      # boot, so the charts are already populated when the server starts.
      BeamPanel.Servers.record_sample(server_id, metrics)
    end
  end

  defp beam_processes do
    [
      %{
        pid: 21_884,
        rss: 412 * 1024 * 1024,
        uptime: 486_320,
        node: "storefront@127.0.0.1",
        release: "/opt/beam/storefront/current",
        args: "/usr/lib/erlang/erts-15.1/bin/beam.smp -root /opt/beam/storefront/current"
      },
      %{
        pid: 22_140,
        rss: 268 * 1024 * 1024,
        uptime: 486_115,
        node: "billing@127.0.0.1",
        release: "/opt/beam/billing-api/current",
        args: "/usr/lib/erlang/erts-15.1/bin/beam.smp -root /opt/beam/billing-api/current"
      }
    ]
  end

  defp clamp(v), do: v |> max(1.0) |> min(99.0)
  defp jitter(range), do: :rand.uniform() * range - range / 2
end

servers = [
  %{
    attrs: %{
      "name" => "Main server",
      "slug" => "main",
      "hostname" => "solomonster.net",
      "connection" => "local",
      "role" => "primary",
      "ssh_user" => "root",
      "description" => "Хост, на котором работает панель",
      "monitor_enabled" => false,
      "tags_input" => "panel, primary"
    },
    facts: Demo.facts("27", "1.18.4"),
    metrics: {21.0, 47.0, 38}
  },
  %{
    attrs: %{
      "name" => "prod-web-1",
      "hostname" => "10.20.0.11",
      "ssh_private_key" => key,
      "group_id" => cluster.id,
      "role" => "secondary",
      "description" => "Фронтенд Phoenix, за nginx",
      "monitor_enabled" => false,
      "tags_input" => "prod, web, eu-central"
    },
    facts: Demo.facts("27", "1.18.4"),
    metrics: {58.0, 71.0, 62}
  },
  %{
    attrs: %{
      "name" => "prod-db-1",
      "hostname" => "10.20.0.21",
      "ssh_private_key" => key,
      "group_id" => cluster.id,
      "role" => "database",
      "description" => "PostgreSQL 16 + бэкапы",
      "monitor_enabled" => false,
      "tags_input" => "prod, database"
    },
    facts: Demo.facts("26", "1.17.3", pg: "16.4", docker: nil),
    metrics: {34.0, 82.0, 74}
  },
  %{
    attrs: %{
      "name" => "eu-worker-2",
      "hostname" => "10.20.0.32",
      "ssh_private_key" => key,
      "group_id" => cluster.id,
      "description" => "Фоновые задачи Oban",
      "monitor_enabled" => false,
      "tags_input" => "prod, worker"
    },
    facts: %{},
    unreachable: "connection refused: порт 22 закрыт файрволом"
  }
]

created =
  Enum.map(servers, fn spec ->
    {:ok, server} = Servers.create_server(spec.attrs)

    server =
      case spec do
        %{unreachable: reason} ->
          {:ok, s} = Servers.mark_unreachable(server, reason)
          s

        _ ->
          {:ok, s} = Servers.mark_online(server, spec.facts)
          s
      end

    case spec[:metrics] do
      {cpu, mem, disk} -> Demo.series(server.id, cpu, mem, disk)
      _ -> :ok
    end

    server
  end)

[main, web, db, _worker] = created

projects = [
  %{
    "server_id" => web.id,
    "name" => "Storefront",
    "kind" => "phoenix",
    "repo_url" => "git@github.com:acme/storefront.git",
    "branch" => "main",
    "deploy_path" => "/opt/beam/storefront",
    "http_port" => 4000,
    "health_url" => "http://127.0.0.1:4000/health",
    "node_name" => "storefront@127.0.0.1",
    "description" => "Витрина магазина на Phoenix LiveView"
  },
  %{
    "server_id" => web.id,
    "name" => "Billing API",
    "kind" => "elixir_release",
    "repo_url" => "git@github.com:acme/billing.git",
    "branch" => "main",
    "deploy_path" => "/opt/beam/billing-api",
    "http_port" => 4010,
    "node_name" => "billing@127.0.0.1",
    "description" => "Расчёты и выставление счетов"
  },
  %{
    "server_id" => db.id,
    "name" => "Mailer Worker",
    "kind" => "mix_app",
    "repo_url" => "git@github.com:acme/mailer.git",
    "branch" => "main",
    "deploy_path" => "/opt/beam/mailer",
    "description" => "Очередь исходящей почты"
  },
  %{
    "server_id" => db.id,
    "name" => "Legacy Gateway",
    "kind" => "erlang_release",
    "deploy_path" => "/opt/beam/legacy-gateway",
    "http_port" => 8080,
    "discovered" => true,
    "description" => "Erlang-шлюз, найден автоматически"
  }
]

[storefront, billing, mailer, legacy] =
  Enum.map(projects, fn attrs ->
    {:ok, project} = Projects.create_project(attrs)
    project
  end)

{:ok, storefront} =
  Projects.set_status(storefront, %{
    status: "running",
    current_version: "20260818T104512",
    previous_version: "20260817T193004",
    last_deployed_at: DateTime.utc_now() |> DateTime.add(-3, :hour) |> DateTime.truncate(:second)
  })

{:ok, _} =
  Projects.set_status(billing, %{
    status: "running",
    current_version: "20260818T091220",
    last_deployed_at: DateTime.utc_now() |> DateTime.add(-9, :hour) |> DateTime.truncate(:second)
  })

{:ok, _} = Projects.set_status(mailer, %{status: "stopped", current_version: "20260814T140000"})
{:ok, _} = Projects.set_status(legacy, %{status: "failed", current_version: "20260731T081500"})

for {key, value, secret} <- [
      {"DATABASE_URL", "ecto://storefront:s3cr3t@10.20.0.21/storefront_prod", true},
      {"SECRET_KEY_BASE", "8sT2p1QeR7yZ0mVxK4nB6dH9jL3wA5cF", true},
      {"PHX_HOST", "shop.example.com", false},
      {"POOL_SIZE", "20", false},
      {"SENTRY_DSN", "https://abc123@sentry.io/4506", true}
    ] do
  Projects.create_env_var(storefront, %{"key" => key, "value" => value, "secret" => secret})
end

deploy_log = """
── Деплой Storefront на prod-web-1 ──
▸ Проверка окружения
  git: /usr/bin/git
  free space: 96G свободно на /
  elixir: /usr/local/bin/elixir
  mix: /usr/local/bin/mix
▸ Подготовка каталогов
▸ Получение исходников
  a41f9c2 Ускорение выдачи каталога
▸ Зависимости
  Resolving Hex dependencies...
  All dependencies are up to date
▸ Компиляция
  Compiling 84 files (.ex)
  Generated storefront app
▸ Сборка ассетов
  Done in 412ms
▸ Сборка релиза
  * assembling storefront-1.4.0 on MIX_ENV=prod
▸ Активация версии
  current -> /opt/beam/storefront/releases/20260818T104512
▸ systemd unit и env
  unit: /etc/systemd/system/storefront.service
▸ Миграции БД
  20260812091500_add_index_to_orders.exs: migrated
▸ Перезапуск службы
  storefront.service перезапущен
▸ Health check
  OK 200 (http://127.0.0.1:4000/health)
▸ Завершение
  активная версия: 20260818T104512
✓ Деплой завершён за 1 мин 47 с
"""

deployments = [
  %{
    project_id: storefront.id,
    user_id: admin.id,
    status: "success",
    strategy: "release",
    ref: "origin/main",
    commit_sha: "a41f9c2",
    commit_message: "Ускорение выдачи каталога",
    release_version: "20260818T104512",
    previous_version: "20260817T193004",
    duration_ms: 107_000,
    log: deploy_log,
    hours_ago: 3
  },
  %{
    project_id: billing.id,
    user_id: admin.id,
    status: "success",
    strategy: "release",
    ref: "origin/main",
    commit_sha: "7bd0114",
    commit_message: "Исправление округления НДС",
    release_version: "20260818T091220",
    duration_ms: 94_500,
    log: "▸ Health check\n  OK 200\n✓ Деплой завершён за 1 мин 34 с\n",
    hours_ago: 9
  },
  %{
    project_id: legacy.id,
    user_id: admin.id,
    status: "rolled_back",
    strategy: "release",
    ref: "origin/main",
    commit_sha: "f30ab77",
    commit_message: "Переход на новый протокол",
    release_version: "20260818T060000",
    previous_version: "20260731T081500",
    error: "healthcheck: health check не прошёл: FAIL last=502",
    duration_ms: 233_000,
    log: "▸ Health check\n✗ Health check: FAIL last=502\n↩ Откат на предыдущий релиз\n↩ Откат выполнен\n",
    hours_ago: 20
  },
  %{
    project_id: mailer.id,
    user_id: admin.id,
    status: "failed",
    strategy: "release",
    ref: "feature/retries",
    commit_sha: "0c19e4a",
    commit_message: "Экспоненциальные повторы",
    error: "compile: команда завершилась с кодом 1",
    duration_ms: 41_000,
    log: "▸ Компиляция\n✗ Компиляция: команда завершилась с кодом 1\n",
    hours_ago: 30
  },
  %{
    project_id: storefront.id,
    user_id: admin.id,
    status: "success",
    strategy: "rollback",
    release_version: "20260817T193004",
    duration_ms: 8_400,
    log: "↩ Откат на /opt/beam/storefront/releases/20260817T193004\n✓ Откат выполнен\n",
    hours_ago: 38
  }
]

for d <- deployments do
  at = DateTime.utc_now() |> DateTime.add(-d.hours_ago, :hour) |> DateTime.truncate(:second)

  %Deployment{}
  |> Deployment.changeset(
    d
    |> Map.drop([:hours_ago])
    |> Map.merge(%{
      started_at: at,
      finished_at: DateTime.add(at, div(d.duration_ms, 1000), :second)
    })
  )
  |> Repo.insert!()
  |> Ecto.Changeset.change(inserted_at: at, updated_at: at)
  |> Repo.update!()
end

Notifications.create_channel(%{
  "name" => "Дежурная смена",
  "kind" => "telegram",
  "config" => %{"bot_token" => "7712345678:AAF-demo-token", "chat_id" => "-1001234567890"},
  "events" => ["deploy_failed", "server_unreachable"]
})

Notifications.create_channel(%{
  "name" => "CI webhook",
  "kind" => "webhook",
  "config" => %{"url" => "https://ci.example.com/hooks/beam-panel"},
  "events" => []
})

Accounts.create_api_token(admin, %{"name" => "GitHub Actions", "scopes" => ["read", "deploy"]})

audit = [
  {"deploy.start", "project", storefront.id, %{ref: "origin/main"}},
  {"project.restart", "project", billing.id, %{}},
  {"server.create", "server", web.id, %{name: "prod-web-1"}},
  {"provision.start", "server", db.id, %{components: ["base", "erlang", "elixir"]}},
  {"project.env.set", "project", storefront.id, %{key: "SENTRY_DSN"}},
  {"auth.login", "user", admin.id, %{}},
  {"api_token.create", "api_token", 1, %{name: "GitHub Actions"}}
]

for {action, type, id, meta} <- audit do
  Audit.log(admin, action, resource_type: type, resource_id: id, metadata: meta, ip: "203.0.113.42")
end

IO.puts("""

Демо-данные созданы.
  вход:   admin@example.com / demo-password-1234
  сервера: #{length(created)}, проекты: 4, деплои: #{length(deployments)}
  основной сервер: #{main.name}
""")
