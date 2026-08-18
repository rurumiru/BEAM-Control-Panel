defmodule BeamPanel.Beam do
  @moduledoc """
  Deep introspection of a running BEAM node.

  Code is evaluated **inside** the target node through `bin/<release> rpc`, and
  the result is shipped back as a base64-encoded Erlang term, which is decoded
  locally with `:erlang.binary_to_term/2` in `:safe` mode. That gives structured
  data — no output scraping — without requiring Erlang distribution between the
  panel and the target host.
  """

  alias BeamPanel.Projects
  alias BeamPanel.Projects.Project
  alias BeamPanel.Remote.Result

  @marker "BCP_TERM:"

  ## ------------------------------------------------------------------ public

  @doc "Scheduler, memory and process counters for the node."
  @spec system_info(Project.t()) :: {:ok, map()} | {:error, term()}
  def system_info(project) do
    eval_term(project, """
    memory = Enum.into(:erlang.memory(), %{})
    %{
      otp_release: to_string(:erlang.system_info(:otp_release)),
      erts_version: to_string(:erlang.system_info(:version)),
      elixir_version: System.version(),
      node: to_string(Node.self()),
      cookie_set: :erlang.get_cookie() != :nocookie,
      uptime_ms: elem(:erlang.statistics(:wall_clock), 0),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      ets_count: length(:ets.all()),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      run_queue: :erlang.statistics(:run_queue),
      reductions: elem(:erlang.statistics(:reductions), 0),
      memory: memory,
      connected_nodes: Enum.map(Node.list(), &to_string/1),
      distribution: to_string(:erlang.system_info(:system_architecture))
    }
    """)
  end

  @doc "All applications loaded on the node, with running state."
  @spec applications(Project.t()) :: {:ok, [map()]} | {:error, term()}
  def applications(project) do
    eval_term(project, """
    running = Map.new(:application.which_applications(), fn {app, desc, vsn} ->
      {app, %{description: to_string(desc), version: to_string(vsn)}}
    end)

    :application.loaded_applications()
    |> Enum.map(fn {app, desc, vsn} ->
      info = Map.get(running, app)
      %{
        name: to_string(app),
        description: to_string(desc),
        version: to_string(vsn),
        running: info != nil,
        master: (case :application_controller.get_master(app) do
          :undefined -> nil
          pid -> inspect(pid)
        end)
      }
    end)
    |> Enum.sort_by(& &1.name)
    """)
  end

  @doc "Supervision tree of `app`, up to `depth` levels."
  @spec supervision_tree(Project.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def supervision_tree(project, app, depth \\ 6) do
    eval_term(project, """
    app = String.to_existing_atom(#{inspect(app)})
    max_depth = #{depth}

    describe = fn pid when is_pid(pid) ->
      case Process.info(pid, [:registered_name, :memory, :message_queue_len, :reductions, :dictionary]) do
        nil -> %{alive: false}
        info ->
          dict = Keyword.get(info, :dictionary, [])
          %{
            alive: true,
            registered_name: (case Keyword.get(info, :registered_name) do
              [] -> nil
              name -> to_string(name)
            end),
            memory: Keyword.get(info, :memory, 0),
            message_queue_len: Keyword.get(info, :message_queue_len, 0),
            reductions: Keyword.get(info, :reductions, 0),
            initial_call: (case Keyword.get(dict, :"$initial_call") do
              {m, f, a} -> "\#{inspect(m)}.\#{f}/\#{a}"
              _ -> nil
            end)
          }
      end
    end

    walk = fn walk, pid, level ->
      base = %{pid: inspect(pid), info: describe.(pid), level: level}

      children =
        if level >= max_depth do
          []
        else
          try do
            pid
            |> :supervisor.which_children()
            |> Enum.map(fn {id, child, type, mods} ->
              child_map = %{
                id: (case id do
                  id when is_atom(id) -> to_string(id)
                  id -> inspect(id)
                end),
                type: to_string(type),
                modules: Enum.map(List.wrap(mods), &inspect/1)
              }

              case child do
                child_pid when is_pid(child_pid) ->
                  case type do
                    :supervisor -> Map.merge(child_map, walk.(walk, child_pid, level + 1))
                    _ -> Map.merge(child_map, %{pid: inspect(child_pid), info: describe.(child_pid), children: [], level: level + 1})
                  end

                other ->
                  Map.merge(child_map, %{pid: inspect(other), info: %{alive: false}, children: [], level: level + 1})
              end
            end)
          catch
            _, _ -> []
          end
        end

      Map.put(base, :children, children)
    end

    case :application_controller.get_master(app) do
      :undefined -> %{error: "application not running"}
      master ->
        case :application_master.get_child(master) do
          {root, _} when is_pid(root) ->
            walk.(walk, root, 0) |> Map.put(:application, to_string(app))
          _ -> %{error: "no root supervisor"}
        end
    end
    """)
  end

  @doc "Top processes ordered by `sort` (`:memory`, `:reductions`, `:message_queue_len`)."
  @spec processes(Project.t(), atom(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def processes(project, sort \\ :memory, limit \\ 40) do
    eval_term(project, """
    sort_key = #{inspect(sort)}
    limit = #{limit}

    Process.list()
    |> Enum.map(fn pid ->
      case Process.info(pid, [:registered_name, :memory, :message_queue_len, :reductions, :current_function, :dictionary, :status]) do
        nil -> nil
        info ->
          dict = Keyword.get(info, :dictionary, [])
          %{
            pid: inspect(pid),
            name: (case Keyword.get(info, :registered_name) do
              [] -> nil
              name -> to_string(name)
            end),
            memory: Keyword.get(info, :memory, 0),
            message_queue_len: Keyword.get(info, :message_queue_len, 0),
            reductions: Keyword.get(info, :reductions, 0),
            status: to_string(Keyword.get(info, :status, :unknown)),
            current_function: (case Keyword.get(info, :current_function) do
              {m, f, a} -> "\#{inspect(m)}.\#{f}/\#{a}"
              _ -> nil
            end),
            initial_call: (case Keyword.get(dict, :"$initial_call") do
              {m, f, a} -> "\#{inspect(m)}.\#{f}/\#{a}"
              _ -> nil
            end)
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&Map.get(&1, sort_key, 0), :desc)
    |> Enum.take(limit)
    """)
  end

  @doc "ETS tables ordered by memory."
  @spec ets_tables(Project.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def ets_tables(project, limit \\ 50) do
    eval_term(project, """
    word = :erlang.system_info(:wordsize)

    :ets.all()
    |> Enum.map(fn tab ->
      try do
        info = :ets.info(tab)
        %{
          name: to_string(Keyword.get(info, :name, "?")),
          id: inspect(tab),
          size: Keyword.get(info, :size, 0),
          memory: Keyword.get(info, :memory, 0) * word,
          type: to_string(Keyword.get(info, :type, :set)),
          protection: to_string(Keyword.get(info, :protection, :protected)),
          owner: inspect(Keyword.get(info, :owner))
        }
      catch
        _, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory, :desc)
    |> Enum.take(#{limit})
    """)
  end

  @doc "Ports (sockets, drivers) held by the node."
  @spec ports(Project.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def ports(project, limit \\ 50) do
    eval_term(project, """
    Port.list()
    |> Enum.map(fn port ->
      case Port.info(port) do
        nil -> nil
        info ->
          %{
            port: inspect(port),
            name: to_string(Keyword.get(info, :name, "")),
            id: Keyword.get(info, :id),
            connected: inspect(Keyword.get(info, :connected)),
            input: Keyword.get(info, :input, 0),
            output: Keyword.get(info, :output, 0),
            os_pid: Keyword.get(info, :os_pid)
          }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(#{limit})
    """)
  end

  @doc "Distribution view: this node plus every connected node."
  @spec cluster(Project.t()) :: {:ok, map()} | {:error, term()}
  def cluster(project) do
    eval_term(project, """
    self_node = Node.self()

    peers =
      Node.list()
      |> Enum.map(fn node ->
        %{
          node: to_string(node),
          reachable: :net_adm.ping(node) == :pong,
          otp_release: (try do
            to_string(:erpc.call(node, :erlang, :system_info, [:otp_release], 5000))
          catch
            _, _ -> nil
          end),
          process_count: (try do
            :erpc.call(node, :erlang, :system_info, [:process_count], 5000)
          catch
            _, _ -> nil
          end)
        }
      end)

    %{
      self: to_string(self_node),
      alive: Node.alive?(),
      hidden: Enum.map(Node.list(:hidden), &to_string/1),
      peers: peers,
      epmd_port: :erlang.system_info(:dist_ctrl) |> inspect()
    }
    """)
  end

  @doc """
  Evaluates arbitrary Elixir code on the node and returns `inspect/1` of the
  result. Restricted to admins by the calling layer.
  """
  @spec eval(Project.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def eval(project, code) do
    Projects.rpc(project, code)
  end

  @doc "Whether the node is reachable through the release script."
  @spec ping(Project.t()) :: :ok | {:error, term()}
  def ping(project) do
    case Projects.release_command(project, "ping", timeout: 20_000) do
      {:ok, %Result{exit_status: 0, stdout: out}} ->
        if String.contains?(out, "pong"), do: :ok, else: {:error, String.trim(out)}

      {:ok, %Result{} = result} ->
        {:error, Result.combined(result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## --------------------------------------------------------------- internals

  @doc false
  def eval_term(project, code) do
    wrapped = """
    result = (fn -> #{code} end).()
    IO.puts("#{@marker}" <> Base.encode64(:erlang.term_to_binary(result)))
    """

    case Projects.rpc(project, wrapped) do
      {:ok, output} -> decode(output)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(output) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.find_value(fn line ->
      line = String.trim(line)

      case String.starts_with?(line, @marker) do
        true -> String.replace_prefix(line, @marker, "")
        false -> nil
      end
    end)
    |> case do
      nil ->
        {:error, {:no_term_in_output, String.slice(output, 0, 800)}}

      encoded ->
        with {:ok, binary} <- Base.decode64(encoded),
             {:ok, term} <- safe_binary_to_term(binary) do
          {:ok, term}
        else
          _ -> {:error, :decode_failed}
        end
    end
  end

  defp safe_binary_to_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _ -> {:ok, :erlang.binary_to_term(binary)}
  catch
    _, _ -> {:error, :bad_term}
  end
end
