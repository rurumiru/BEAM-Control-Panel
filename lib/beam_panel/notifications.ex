defmodule BeamPanel.Notifications do
  @moduledoc """
  Fan-out of panel events to webhooks, Telegram, Slack, Discord and email.

  Delivery happens in a supervised task, so a slow or broken endpoint never
  blocks a deployment.
  """

  import Ecto.Query, warn: false
  require Logger

  alias BeamPanel.Repo
  alias BeamPanel.Notifications.Channel
  alias BeamPanel.Deploy.Deployment
  alias BeamPanel.Projects.Project

  ## ------------------------------------------------------------------- CRUD

  def list_channels, do: Repo.all(from c in Channel, order_by: [asc: c.name])

  def get_channel!(id), do: Repo.get!(Channel, id)

  def change_channel(%Channel{} = channel, attrs \\ %{}), do: Channel.changeset(channel, attrs)

  def create_channel(attrs), do: %Channel{} |> Channel.changeset(attrs) |> Repo.insert()

  def update_channel(%Channel{} = channel, attrs),
    do: channel |> Channel.changeset(attrs) |> Repo.update()

  def delete_channel(%Channel{} = channel), do: Repo.delete(channel)

  ## --------------------------------------------------------------- dispatch

  @doc "Sends `event` to every enabled channel subscribed to it."
  def dispatch(event, payload) do
    event = to_string(event)
    message = render(event, payload)

    if is_pid(Process.whereis(BeamPanel.TaskSupervisor)) do
      Repo.all(from c in Channel, where: c.enabled == true)
      |> Enum.filter(&(&1.events == [] or event in &1.events))
      |> Enum.each(fn channel ->
        Task.Supervisor.start_child(BeamPanel.TaskSupervisor, fn ->
          deliver(channel, event, message, payload)
        end)
      end)
    end

    :ok
  rescue
    error ->
      Logger.warning("notification dispatch failed: #{Exception.message(error)}")
      :ok
  end

  @doc "Sends a test message through a channel."
  def test(%Channel{} = channel) do
    deliver(
      channel,
      "test",
      %{
        title: "BEAM Control Panel",
        text: "Тестовое уведомление из канала «#{channel.name}».",
        level: :info
      },
      %{}
    )
  end

  ## --------------------------------------------------------------- rendering

  defp render("deploy_success", %{deployment: %Deployment{} = d, project: %Project{} = p}) do
    %{
      title: "✅ Деплой успешен: #{p.name}",
      text:
        "Проект #{p.name} развёрнут на #{server_name(p)}.\n" <>
          "Версия: #{d.release_version || "—"}\nКоммит: #{d.commit_sha || "—"} #{d.commit_message || ""}",
      level: :success
    }
  end

  defp render("deploy_failed", %{deployment: %Deployment{} = d, project: %Project{} = p}) do
    %{
      title: "❌ Деплой провален: #{p.name}",
      text: "Проект #{p.name} на #{server_name(p)}.\nОшибка: #{d.error || "неизвестна"}",
      level: :error
    }
  end

  defp render("server_unreachable", %{server: server}) do
    %{
      title: "⚠️ Сервер недоступен: #{server.name}",
      text: "#{server.hostname}: #{server.status_message || "нет связи"}",
      level: :warning
    }
  end

  defp render("server_online", %{server: server}) do
    %{title: "✅ Сервер снова онлайн: #{server.name}", text: server.hostname, level: :success}
  end

  defp render("provision_finished", %{server: server, status: status}) do
    %{
      title: "🛠 Провижининг #{status}: #{server.name}",
      text: "#{server.hostname}",
      level: if(status == "success", do: :success, else: :error)
    }
  end

  defp render(event, payload) do
    %{title: "BEAM Control Panel: #{event}", text: inspect(payload, limit: 20), level: :info}
  end

  defp server_name(%Project{server: %{name: name}}), do: name
  defp server_name(_), do: "сервере"

  ## ---------------------------------------------------------------- delivery

  defp deliver(%Channel{kind: "telegram", config: config} = channel, _event, message, _payload) do
    url = "https://api.telegram.org/bot#{config["bot_token"]}/sendMessage"

    body = %{
      chat_id: config["chat_id"],
      text: "*#{escape_md(message.title)}*\n#{escape_md(message.text)}",
      parse_mode: "MarkdownV2",
      disable_web_page_preview: true
    }

    post(channel, url, body)
  end

  defp deliver(%Channel{kind: "slack", config: config} = channel, _event, message, _payload) do
    post(channel, config["url"], %{text: "*#{message.title}*\n#{message.text}"})
  end

  defp deliver(%Channel{kind: "discord", config: config} = channel, _event, message, _payload) do
    post(channel, config["url"], %{content: "**#{message.title}**\n#{message.text}"})
  end

  defp deliver(%Channel{kind: "webhook", config: config} = channel, event, message, payload) do
    body = %{
      event: event,
      title: message.title,
      text: message.text,
      level: message.level,
      timestamp: DateTime.utc_now(),
      data: summarize(payload)
    }

    post(channel, config["url"], body, headers(config))
  end

  defp deliver(%Channel{kind: "email", config: config} = channel, _event, message, _payload) do
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(config["to"])
      |> Swoosh.Email.from({"BEAM Control Panel", config["from"] || "panel@localhost"})
      |> Swoosh.Email.subject(message.title)
      |> Swoosh.Email.text_body(message.text)

    case BeamPanel.Mailer.deliver(email) do
      {:ok, _} -> mark_sent(channel)
      {:error, reason} -> mark_error(channel, inspect(reason))
    end
  end

  defp deliver(channel, _event, _message, _payload),
    do: mark_error(channel, "неподдерживаемый тип канала")

  defp post(channel, url, body, extra_headers \\ []) do
    case Req.post(url, json: body, headers: extra_headers, receive_timeout: 15_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 ->
        mark_sent(channel)

      {:ok, %{status: status, body: body}} ->
        mark_error(channel, "HTTP #{status}: #{inspect(body, limit: 5)}")

      {:error, reason} ->
        mark_error(channel, inspect(reason))
    end
  rescue
    error -> mark_error(channel, Exception.message(error))
  end

  defp headers(config) do
    case config["secret"] do
      nil -> []
      "" -> []
      secret -> [{"x-beam-panel-secret", secret}]
    end
  end

  defp mark_sent(channel) do
    channel
    |> Ecto.Changeset.change(
      last_sent_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_error: nil
    )
    |> Repo.update()

    :ok
  end

  defp mark_error(channel, reason) do
    Logger.warning("notification channel #{channel.name} failed: #{reason}")

    channel
    |> Ecto.Changeset.change(last_error: String.slice(to_string(reason), 0, 500))
    |> Repo.update()

    {:error, reason}
  end

  defp summarize(%{deployment: d, project: p}),
    do: %{deployment_id: d.id, project: p.name, status: d.status}

  defp summarize(%{server: s}), do: %{server: s.name, status: s.status}
  defp summarize(_), do: %{}

  defp escape_md(text) do
    Regex.replace(~r/([_*\[\]()~`>#+\-=|{}.!])/, to_string(text), "\\\\\\1")
  end
end
