defmodule BeamPanelWeb.Format do
  @moduledoc "Presentation helpers shared by every template."

  @doc "Formats a byte count as B / KB / MB / GB / TB."
  def bytes(nil), do: "—"
  def bytes(0), do: "0 B"

  def bytes(value) when is_number(value) do
    units = ["B", "KB", "MB", "GB", "TB", "PB"]

    {value, unit} =
      Enum.reduce_while(units, {value * 1.0, "B"}, fn unit, {acc, _} ->
        if acc < 1024, do: {:halt, {acc, unit}}, else: {:cont, {acc / 1024, unit}}
      end)

    precision = if unit in ["B", "KB"], do: 0, else: 1
    "#{:erlang.float_to_binary(value, decimals: precision)} #{unit}"
  end

  def bytes(_), do: "—"

  @doc "Formats a per-second byte rate."
  def rate(nil), do: "—"
  def rate(value), do: bytes(value) <> "/s"

  @doc "Formats a percentage."
  def percent(nil), do: "—"

  def percent(value) when is_number(value),
    do: "#{:erlang.float_to_binary(value * 1.0, decimals: 1)}%"

  def percent(_), do: "—"

  @doc "Formats a duration given in seconds as `12д 4ч 5м`."
  def uptime(nil), do: "—"

  def uptime(seconds) when is_number(seconds) do
    seconds = trunc(seconds)
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      days > 0 -> "#{days}д #{hours}ч"
      hours > 0 -> "#{hours}ч #{minutes}м"
      minutes > 0 -> "#{minutes}м"
      true -> "#{seconds}с"
    end
  end

  def uptime(_), do: "—"

  @doc "Formats a millisecond duration."
  def duration_ms(nil), do: "—"
  def duration_ms(ms) when ms < 1000, do: "#{ms} мс"
  def duration_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)} с"
  def duration_ms(ms), do: "#{div(ms, 60_000)}м #{rem(div(ms, 1000), 60)}с"

  @doc "Absolute timestamp in local ISO-ish form."
  def datetime(nil), do: "—"

  def datetime(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> Calendar.strftime("%d.%m.%Y %H:%M:%S")
  end

  def datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%d.%m.%Y %H:%M:%S")
  def datetime(_), do: "—"

  @doc "Relative time such as `3 мин назад`."
  def relative(nil), do: "—"

  def relative(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "только что"
      diff < 60 -> "#{diff} с назад"
      diff < 3600 -> "#{div(diff, 60)} мин назад"
      diff < 86_400 -> "#{div(diff, 3600)} ч назад"
      diff < 2_592_000 -> "#{div(diff, 86_400)} дн назад"
      true -> datetime(dt)
    end
  end

  def relative(_), do: "—"

  @doc "Large number with thin-space grouping."
  def number(nil), do: "—"

  def number(value) when is_integer(value) do
    value
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(" ", &to_string/1)
    |> String.reverse()
  end

  def number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  def number(value), do: to_string(value)

  @doc "daisyUI badge class for a server or project status."
  def status_class("online"), do: "badge-success"
  def status_class("running"), do: "badge-success"
  def status_class("success"), do: "badge-success"
  def status_class("rolled_back"), do: "badge-warning"
  def status_class("provisioning"), do: "badge-info"
  def status_class("deploying"), do: "badge-info"
  def status_class("pending"), do: "badge-info"
  def status_class("stopped"), do: "badge-neutral"
  def status_class("offline"), do: "badge-neutral"
  def status_class("cancelled"), do: "badge-neutral"
  def status_class("failed"), do: "badge-error"
  def status_class("unreachable"), do: "badge-error"
  def status_class(_), do: "badge-ghost"

  @doc "Russian label for a status."
  def status_label("online"), do: "онлайн"
  def status_label("offline"), do: "офлайн"
  def status_label("unreachable"), do: "недоступен"
  def status_label("provisioning"), do: "провижининг"
  def status_label("unknown"), do: "неизвестно"
  def status_label("running"), do: "работает"
  def status_label("stopped"), do: "остановлен"
  def status_label("failed"), do: "ошибка"
  def status_label("deploying"), do: "деплой"
  def status_label("pending"), do: "в очереди"
  def status_label("success"), do: "успешно"
  def status_label("rolled_back"), do: "откат"
  def status_label("cancelled"), do: "отменён"
  def status_label(other), do: to_string(other)

  @doc "Colour class for a utilisation gauge."
  def gauge_class(value) when is_number(value) do
    cond do
      value >= 90 -> "text-error"
      value >= 75 -> "text-warning"
      true -> "text-success"
    end
  end

  def gauge_class(_), do: "text-base-content"

  @doc "Progress bar class for a utilisation percentage."
  def progress_class(value) when is_number(value) do
    cond do
      value >= 90 -> "progress-error"
      value >= 75 -> "progress-warning"
      true -> "progress-primary"
    end
  end

  def progress_class(_), do: "progress-primary"

  @doc "Truncates long text for table cells."
  def truncate(nil, _length), do: "—"

  def truncate(text, length) do
    text = to_string(text)
    if String.length(text) > length, do: String.slice(text, 0, length) <> "…", else: text
  end
end
