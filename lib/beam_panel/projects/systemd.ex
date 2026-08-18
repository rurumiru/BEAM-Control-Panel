defmodule BeamPanel.Projects.Systemd do
  @moduledoc """
  Renders the systemd unit and environment file for a project.

  Units are written to `/etc/systemd/system/<service_name>` and the environment
  file to `<deploy_path>/shared/env` with mode 0600, since it carries secrets.
  """

  alias BeamPanel.Projects.{Project, EnvVar}
  alias BeamPanel.Servers.Server

  @doc "Absolute path of the unit file."
  def unit_path(%Project{service_name: name}), do: "/etc/systemd/system/#{name}"

  @doc "Absolute path of the environment file."
  def env_path(%Project{deploy_path: path}), do: Path.join([path, "shared", "env"])

  @doc "Renders the unit file."
  def render_unit(%Project{} = project, %Server{} = server) do
    user = server.deploy_user || "deploy"
    exec_start = exec_start(project)
    exec_stop = exec_stop(project)

    """
    # Managed by BEAM Control Panel — manual edits are overwritten on deploy.
    [Unit]
    Description=#{project.name} (#{project.kind})
    Documentation=https://github.com/rurumiru/BEAM-Control-Panel
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=exec
    User=#{user}
    Group=#{user}
    WorkingDirectory=#{Project.current_path(project)}
    EnvironmentFile=-#{env_path(project)}
    ExecStart=#{exec_start}
    #{if exec_stop, do: "ExecStop=#{exec_stop}", else: ""}
    Restart=on-failure
    RestartSec=5
    TimeoutStartSec=120
    TimeoutStopSec=30
    KillMode=mixed
    LimitNOFILE=65535
    SyslogIdentifier=#{Project.unit_base(project)}
    NoNewPrivileges=true
    PrivateTmp=true
    ProtectSystem=full
    ProtectHome=true

    [Install]
    WantedBy=multi-user.target
    """
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  defp exec_start(%Project{kind: "mix_app"} = project) do
    "/usr/bin/env MIX_ENV=#{project.mix_env} mix run --no-halt"
  end

  defp exec_start(project), do: "#{Project.bin_path(project)} start"

  defp exec_stop(%Project{kind: "mix_app"}), do: nil
  defp exec_stop(project), do: "#{Project.bin_path(project)} stop"

  @doc """
  Renders the environment file.

  Base variables (`MIX_ENV`, `PORT`, `RELEASE_NODE`, `RELEASE_COOKIE`, `HOME`) are
  emitted first, then user-defined variables which may override them.
  """
  def render_env(%Project{} = project, env_vars) do
    base =
      [
        {"MIX_ENV", project.mix_env || "prod"},
        {"LANG", "en_US.UTF-8"},
        {"HOME", Project.current_path(project)},
        {"RELEASE_TMP", Path.join(project.deploy_path, "tmp")},
        project.http_port && {"PORT", to_string(project.http_port)},
        project.node_name && {"RELEASE_NODE", project.node_name},
        project.node_cookie && {"RELEASE_COOKIE", project.node_cookie},
        project.node_cookie && {"RELEASE_DISTRIBUTION", "name"}
      ]
      |> Enum.reject(&is_nil/1)

    custom = Enum.map(env_vars, fn %EnvVar{key: key, value: value} -> {key, value || ""} end)

    (base ++ custom)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{escape(value)}" end)
    |> Kernel.<>("\n")
  end

  defp escape(value) do
    value = to_string(value)

    if String.match?(value, ~r/[\s"'#$]/) do
      ~s("#{String.replace(value, ~s("), ~s(\\"))}")
    else
      value
    end
  end

  @doc "Renders an nginx reverse-proxy site for the project."
  def render_nginx(%Project{} = project, domain) do
    port = project.http_port || 4000

    """
    # Managed by BEAM Control Panel
    upstream #{Project.unit_base(project)}_upstream {
      server 127.0.0.1:#{port} fail_timeout=0;
    }

    server {
      listen 80;
      listen [::]:80;
      server_name #{domain};

      client_max_body_size 20M;

      location / {
        proxy_pass http://#{Project.unit_base(project)}_upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
      }
    }
    """
  end
end
