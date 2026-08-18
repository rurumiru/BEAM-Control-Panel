defmodule BeamPanel.Broadcast do
  @moduledoc """
  PubSub publishing that tolerates the PubSub server not being up.

  Contexts are also called from release tasks (`bin/beam_panel eval ...`), where
  only the repository is started — no endpoint, no PubSub, no supervision tree.
  Publishing must degrade to a no-op there instead of raising
  `unknown registry: BeamPanel.PubSub`.
  """

  @server BeamPanel.PubSub

  @doc "Broadcasts `message` on `topic`, or does nothing when PubSub is not running."
  @spec publish(String.t(), term()) :: :ok
  def publish(topic, message) do
    if running?() do
      Phoenix.PubSub.broadcast(@server, topic, message)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Whether the PubSub server is available in this VM."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(@server))
end
