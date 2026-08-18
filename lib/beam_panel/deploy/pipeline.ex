defmodule BeamPanel.Deploy.Pipeline do
  @moduledoc """
  The deploy pipeline: an ordered list of named steps, each a function of the
  execution context.

  A step returns `{:ok, ctx}` to continue or `{:error, reason}` to abort. Aborting
  triggers a rollback to the previously linked release when one exists.
  """

  alias BeamPanel.Projects.Project
  alias BeamPanel.Remote
  alias BeamPanel.Remote.Result

  @keep_releases 5

  # The deploy directory does not exist yet on a first deploy, so free space is
  # measured on the nearest existing parent rather than failing on `df`.
  @free_space_probe ~S"""
  d=__PATH__
  while [ ! -d "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done
  df -Ph "$d" | tail -1 | awk '{print $4" свободно на "$6}'
  """

  @type ctx :: map()

  @doc "Returns the steps for the project's kind."
  def steps(%Project{kind: "mix_app"}) do
    [
      {:preflight, "Проверка окружения", &preflight/1},
      {:prepare, "Подготовка каталогов", &prepare/1},
      {:fetch, "Получение исходников", &fetch/1},
      {:deps, "Зависимости", &deps/1},
      {:compile, "Компиляция", &compile/1},
      {:link, "Активация версии", &link_source/1},
      {:service, "systemd unit и env", &service/1},
      {:migrate, "Миграции БД", &migrate/1},
      {:restart, "Перезапуск службы", &restart/1},
      {:healthcheck, "Health check", &healthcheck/1},
      {:finalize, "Завершение", &finalize/1}
    ]
  end

  def steps(%Project{kind: "erlang_release"}) do
    [
      {:preflight, "Проверка окружения", &preflight/1},
      {:prepare, "Подготовка каталогов", &prepare/1},
      {:fetch, "Получение исходников", &fetch/1},
      {:release, "Сборка релиза (rebar3)", &rebar_release/1},
      {:link, "Активация версии", &link_release/1},
      {:service, "systemd unit и env", &service/1},
      {:restart, "Перезапуск службы", &restart/1},
      {:healthcheck, "Health check", &healthcheck/1},
      {:finalize, "Завершение", &finalize/1}
    ]
  end

  def steps(%Project{kind: kind}) do
    assets? = kind == "phoenix"

    [
      {:preflight, "Проверка окружения", &preflight/1},
      {:prepare, "Подготовка каталогов", &prepare/1},
      {:fetch, "Получение исходников", &fetch/1},
      {:deps, "Зависимости", &deps/1},
      {:compile, "Компиляция", &compile/1}
    ] ++
      if(assets?, do: [{:assets, "Сборка ассетов", &assets/1}], else: []) ++
      [
        {:release, "Сборка релиза", &mix_release/1},
        {:link, "Активация версии", &link_release/1},
        {:service, "systemd unit и env", &service/1},
        {:migrate, "Миграции БД", &migrate/1},
        {:restart, "Перезапуск службы", &restart/1},
        {:healthcheck, "Health check", &healthcheck/1},
        {:finalize, "Завершение", &finalize/1}
      ]
  end

  ## -------------------------------------------------------------------- steps

  defp preflight(ctx) do
    %{project: project} = ctx

    free_space =
      String.replace(@free_space_probe, "__PATH__", Remote.shell_quote(project.deploy_path))

    checks = [
      {"git", "command -v git"},
      {"free space", free_space}
    ]

    toolchain =
      case project.kind do
        "erlang_release" -> [{"rebar3", "command -v rebar3 || command -v ./rebar3"}]
        _ -> [{"elixir", "command -v elixir"}, {"mix", "command -v mix"}]
      end

    Enum.reduce_while(checks ++ toolchain, {:ok, ctx}, fn {label, cmd}, acc ->
      case sh(ctx, cmd) do
        {:ok, %Result{exit_status: 0} = result} ->
          log(ctx, "  #{label}: #{Result.out(result)}")
          {:cont, acc}

        _ ->
          {:halt, {:error, "не найдено: #{label}"}}
      end
    end)
  end

  defp prepare(ctx) do
    %{project: project, server: server} = ctx
    user = server.deploy_user || "deploy"

    dirs =
      [
        project.deploy_path,
        Path.join(project.deploy_path, "source"),
        Path.join(project.deploy_path, "releases"),
        Path.join(project.deploy_path, "shared"),
        Path.join(project.deploy_path, "tmp")
      ]
      |> Enum.map_join(" ", &Remote.shell_quote/1)

    with {:ok, _} <- must(ctx, "mkdir -p #{dirs}", sudo: true),
         {:ok, _} <-
           must(
             ctx,
             "chown -R #{user}:#{user} #{Remote.shell_quote(project.deploy_path)} 2>/dev/null || true",
             sudo: true
           ) do
      {:ok, ctx}
    end
  end

  defp fetch(ctx) do
    %{project: project, deployment: deployment} = ctx
    source = Project.source_path(project)
    ref = deployment.ref || project.git_ref || "origin/#{project.branch}"

    cond do
      is_nil(project.repo_url) or project.repo_url == "" ->
        log(ctx, "  repo_url не задан — используется существующий рабочий каталог")
        {:ok, ctx}

      true ->
        clone_or_fetch = """
        if [ -d #{Remote.shell_quote(source)}/.git ]; then
          git -C #{Remote.shell_quote(source)} remote set-url origin #{Remote.shell_quote(project.repo_url)}
          git -C #{Remote.shell_quote(source)} fetch --all --prune --tags
        else
          rm -rf #{Remote.shell_quote(source)}
          git clone #{Remote.shell_quote(project.repo_url)} #{Remote.shell_quote(source)}
          git -C #{Remote.shell_quote(source)} fetch --all --prune --tags
        fi
        git -C #{Remote.shell_quote(source)} checkout --detach #{Remote.shell_quote(ref)}
        git -C #{Remote.shell_quote(source)} clean -fdx -e _build -e deps -e node_modules
        """

        with {:ok, _} <- must(ctx, clone_or_fetch, timeout: 15 * 60_000) do
          sha = capture(ctx, "git -C #{Remote.shell_quote(source)} rev-parse --short HEAD")
          msg = capture(ctx, "git -C #{Remote.shell_quote(source)} log -1 --pretty=%s")
          log(ctx, "  #{sha} #{msg}")
          {:ok, Map.merge(ctx, %{commit_sha: sha, commit_message: msg})}
        end
    end
  end

  defp deps(ctx) do
    with {:ok, _} <-
           must(ctx, "mix local.hex --force --if-missing && mix local.rebar --force --if-missing",
             cd: Project.source_path(ctx.project),
             env: mix_env(ctx),
             timeout: 10 * 60_000
           ),
         {:ok, _} <-
           must(ctx, "mix deps.get --only #{ctx.project.mix_env}",
             cd: Project.source_path(ctx.project),
             env: mix_env(ctx),
             timeout: 20 * 60_000
           ) do
      {:ok, ctx}
    end
  end

  defp compile(ctx) do
    must_step(ctx, "mix compile",
      cd: Project.source_path(ctx.project),
      env: mix_env(ctx),
      timeout: 30 * 60_000
    )
  end

  defp assets(ctx) do
    source = Project.source_path(ctx.project)

    cmd = """
    if grep -q 'assets.deploy' mix.exs 2>/dev/null || [ -d assets ]; then
      mix assets.deploy || (mix assets.setup && mix assets.deploy)
    else
      echo "нет ассетов — пропуск"
    fi
    """

    must_step(ctx, cmd, cd: source, env: mix_env(ctx), timeout: 30 * 60_000)
  end

  defp mix_release(ctx) do
    %{project: project} = ctx
    target = release_dir(ctx)

    cmd =
      "mix release #{Remote.shell_quote(project.release_name)} --overwrite --path #{Remote.shell_quote(target)}"

    fallback = "mix release --overwrite --path #{Remote.shell_quote(target)}"

    case sh(ctx, "cd #{Remote.shell_quote(Project.source_path(project))} && #{cmd}",
           env: mix_env(ctx),
           timeout: 30 * 60_000
         ) do
      {:ok, %Result{exit_status: 0}} ->
        {:ok, ctx}

      _ ->
        log(ctx, "  именованный релиз не найден, пробуем релиз по умолчанию")

        must_step(ctx, fallback,
          cd: Project.source_path(project),
          env: mix_env(ctx),
          timeout: 30 * 60_000
        )
    end
  end

  defp rebar_release(ctx) do
    %{project: project} = ctx
    source = Project.source_path(project)
    target = release_dir(ctx)

    cmd = """
    rebar3 as prod release
    rm -rf #{Remote.shell_quote(target)}
    mkdir -p #{Remote.shell_quote(target)}
    cp -a _build/prod/rel/*/. #{Remote.shell_quote(target)}/
    """

    must_step(ctx, cmd, cd: source, timeout: 30 * 60_000)
  end

  defp link_release(ctx) do
    %{project: project} = ctx
    target = release_dir(ctx)
    current = Project.current_path(project)

    with {:ok, _} <-
           must(ctx, "ln -sfn #{Remote.shell_quote(target)} #{Remote.shell_quote(current)}",
             sudo: true
           ) do
      log(ctx, "  current -> #{target}")
      {:ok, ctx}
    end
  end

  defp link_source(ctx) do
    %{project: project} = ctx
    current = Project.current_path(project)
    source = Project.source_path(project)

    with {:ok, _} <-
           must(ctx, "ln -sfn #{Remote.shell_quote(source)} #{Remote.shell_quote(current)}",
             sudo: true
           ) do
      {:ok, ctx}
    end
  end

  defp service(ctx) do
    case BeamPanel.Projects.sync_service(ctx.project) do
      {:ok, path} ->
        log(ctx, "  unit: #{path}")
        {:ok, ctx}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp migrate(%{project: %Project{auto_migrate: false}} = ctx) do
    log(ctx, "  авто-миграции отключены")
    {:ok, ctx}
  end

  defp migrate(ctx) do
    %{project: project} = ctx
    command = project.migrate_command || default_migrate_command(project)

    case sh(ctx, command, sudo: true, timeout: 20 * 60_000) do
      {:ok, %Result{exit_status: 0} = result} ->
        log(ctx, indent(Result.combined(result)))
        {:ok, ctx}

      {:ok, %Result{} = result} ->
        {:error, "миграции завершились с ошибкой:\n#{Result.combined(result)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp default_migrate_command(%Project{kind: "mix_app"} = project) do
    "cd #{Remote.shell_quote(Project.source_path(project))} && MIX_ENV=#{project.mix_env} mix ecto.migrate"
  end

  defp default_migrate_command(%Project{} = project) do
    app = String.to_atom(project.release_name)

    code =
      "Application.load(#{inspect(app)}); " <>
        "Enum.each(Application.get_env(#{inspect(app)}, :ecto_repos, []), fn repo -> " <>
        "{:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true)) end)"

    "#{Remote.shell_quote(Project.bin_path(project))} eval #{Remote.shell_quote(code)}"
  end

  defp restart(ctx) do
    %{project: project} = ctx
    unit = Remote.shell_quote(project.service_name)

    with {:ok, _} <- must(ctx, "systemctl daemon-reload", sudo: true),
         {:ok, _} <- must(ctx, "systemctl restart #{unit}", sudo: true, timeout: 5 * 60_000) do
      log(ctx, "  #{project.service_name} перезапущен")
      {:ok, ctx}
    end
  end

  defp healthcheck(ctx) do
    %{project: project} = ctx

    case Project.health_endpoint(project) do
      nil ->
        log(ctx, "  health endpoint не задан — пропуск")
        {:ok, ctx}

      url ->
        cmd = """
        for i in $(seq 1 30); do
          code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 #{Remote.shell_quote(url)} || echo 000)
          if [ "$code" -ge 200 ] && [ "$code" -lt 500 ]; then echo "OK $code"; exit 0; fi
          sleep 2
        done
        echo "FAIL last=$code"
        exit 1
        """

        case sh(ctx, cmd, timeout: 3 * 60_000) do
          {:ok, %Result{exit_status: 0} = result} ->
            log(ctx, "  #{Result.out(result)} (#{url})")
            {:ok, ctx}

          {:ok, %Result{} = result} ->
            {:error, "health check не прошёл: #{Result.combined(result)} (#{url})"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp finalize(ctx) do
    %{project: project} = ctx
    releases = Project.releases_path(project)

    prune = """
    cd #{Remote.shell_quote(releases)} 2>/dev/null && ls -1dt */ 2>/dev/null | tail -n +#{@keep_releases + 1} | xargs -r rm -rf || true
    """

    sh(ctx, prune, sudo: true)

    version = ctx[:release_version] || release_version(ctx)
    log(ctx, "  активная версия: #{version}")

    {:ok, Map.put(ctx, :release_version, version)}
  end

  ## ------------------------------------------------------------------ helpers

  @doc "Directory of the release being built in this run."
  def release_dir(ctx) do
    Path.join(Project.releases_path(ctx.project), release_version(ctx))
  end

  @doc "Version label — timestamp plus commit sha when known."
  def release_version(ctx) do
    ctx[:version] ||
      (
        stamp = ctx.deployment.inserted_at || DateTime.utc_now()

        stamp
        |> DateTime.to_iso8601(:basic)
        |> String.replace(~r/[^0-9TZ]/, "")
      )
  end

  @doc "Restores the previous release and restarts the unit."
  def rollback(ctx, previous_dir) do
    %{project: project} = ctx

    with {:ok, _} <-
           must(
             ctx,
             "ln -sfn #{Remote.shell_quote(previous_dir)} #{Remote.shell_quote(Project.current_path(project))}",
             sudo: true
           ),
         {:ok, _} <-
           must(ctx, "systemctl restart #{Remote.shell_quote(project.service_name)}", sudo: true) do
      {:ok, previous_dir}
    end
  end

  @doc "Lists available release directories, newest first."
  def list_releases(project) do
    server = project.server

    out =
      Remote.capture(
        server,
        "ls -1dt #{Remote.shell_quote(Project.releases_path(project))}/*/ 2>/dev/null | head -20"
      )

    out
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim_trailing(String.trim(&1), "/"))
    |> Enum.reject(&(&1 == ""))
  end

  defp mix_env(ctx) do
    %{
      "MIX_ENV" => ctx.project.mix_env || "prod",
      "HOME" => ctx.project.deploy_path,
      "LANG" => "en_US.UTF-8"
    }
  end

  defp sh(ctx, command, opts \\ []) do
    Remote.run(ctx.server, command, Keyword.merge([conn: ctx[:conn], timeout: 5 * 60_000], opts))
  end

  defp must(ctx, command, opts) do
    case stream(ctx, command, opts) do
      {:ok, %{exit_status: 0} = result} ->
        {:ok, result}

      {:ok, %{exit_status: status}} ->
        {:error, "команда завершилась с кодом #{status}: #{command}"}

      {:error, reason} ->
        {:error, "ошибка выполнения: #{inspect(reason)}"}
    end
  end

  defp must_step(ctx, command, opts) do
    case must(ctx, command, opts) do
      {:ok, _} -> {:ok, ctx}
      error -> error
    end
  end

  defp stream(ctx, command, opts) do
    logger = ctx.log

    Remote.stream(
      ctx.server,
      command,
      fn _io, chunk ->
        chunk
        |> String.split(~r/\r?\n/)
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.each(&logger.("  " <> &1))
      end,
      Keyword.merge([conn: ctx[:conn], collect: false, timeout: 5 * 60_000], opts)
    )
  end

  defp capture(ctx, command) do
    case sh(ctx, command) do
      {:ok, %Result{exit_status: 0} = result} -> Result.out(result)
      _ -> ""
    end
  end

  defp log(ctx, message), do: ctx.log.(message)

  defp indent(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map_join("\n", &("  " <> &1))
  end
end
