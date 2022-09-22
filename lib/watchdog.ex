defmodule Watchdog do
  require Logger
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(processes: processes) when is_list(processes) do
    children =
      [
        Watchdog.Supervisor,
        Watchdog.Watcher
      ] ++ Enum.map(processes, fn process -> {Watchdog.Starter, process} end)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def start_child(%{} = child_spec) do
    GenServer.call(Watchdog.Watcher, {:start_child, child_spec})
  end

  def via_tuple(module) do
    {:via, Watchdog.Registry, module}
  end

  def start_on_another_node(name, existing_pid, state) do
    Node.list()
    |> case do
      [] ->
        Logger.debug("nowhere to transfer process #{name} to, terminating")
        :ok

      nodes ->
        Enum.reduce(nodes, nil, fn node, acc ->
          {:ok, node_uptime} = GenServer.call({Watchdog.Watcher, node}, {:get_uptime})

          cond do
            !acc -> {node, node_uptime}
            node_uptime < elem(acc, 1) -> {node, node_uptime}
            true -> acc
          end
        end)
        |> case do
          {newest_node, _} ->
            Logger.debug("requesting process #{name} transfer to node #{inspect(newest_node)}")

            GenServer.call(
              {Watchdog.Watcher, newest_node},
              {:start_replacement_process, name, existing_pid, state}
            )
        end
    end
  end
end
