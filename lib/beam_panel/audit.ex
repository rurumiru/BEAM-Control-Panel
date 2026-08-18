defmodule BeamPanel.Audit do
  @moduledoc "Audit log context."

  import Ecto.Query
  alias BeamPanel.Repo
  alias BeamPanel.Audit.AuditLog

  @topic "audit"

  @doc """
  Records an action.

  `actor` may be a `%User{}`, a string, or `nil` for system-originated events.
  """
  def log(actor, action, opts \\ []) do
    attrs = %{
      user_id: actor_id(actor),
      actor: actor_label(actor),
      action: to_string(action),
      resource_type: opts[:resource_type] && to_string(opts[:resource_type]),
      resource_id: opts[:resource_id] && to_string(opts[:resource_id]),
      metadata: stringify(opts[:metadata] || %{}),
      ip: opts[:ip],
      result: to_string(opts[:result] || :ok)
    }

    {:ok, log} =
      %AuditLog{}
      |> AuditLog.changeset(attrs)
      |> Repo.insert()

    BeamPanel.Broadcast.publish(@topic, {:audit_log, log})
    log
  end

  def topic, do: @topic

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    AuditLog
    |> maybe_filter(:action, opts[:action])
    |> maybe_filter(:resource_type, opts[:resource_type])
    |> maybe_filter(:resource_id, opts[:resource_id])
    |> maybe_filter(:user_id, opts[:user_id])
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> preload(:user)
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [l], field(l, ^field) == ^value)

  defp actor_id(%BeamPanel.Accounts.User{id: id}), do: id
  defp actor_id(_), do: nil

  defp actor_label(%BeamPanel.Accounts.User{email: email}), do: email
  defp actor_label(actor) when is_binary(actor), do: actor
  defp actor_label(_), do: "system"

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp stringify_value(v) when is_atom(v), do: to_string(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v) when is_map(v), do: stringify(v)
  defp stringify_value(v), do: inspect(v)
end
