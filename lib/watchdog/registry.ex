defmodule Watchdog.Registry do
  require Logger

  def register_name(name, pid) do
    :global.register_name(name, pid, &resolve_conflict/3)
  end

  def whereis_name(name) do
    :global.whereis_name(name)
  end

  def re_register_name(name, pid) do
    :global.re_register_name(name, pid, &resolve_conflict/3)
  end

  def unregister_name(name) do
    :global.unregister_name(name)
  end

  def send(name, message) do
    :global.send(name, message)
  end

  def sync() do
    :global.sync()
  end

  def resolve_conflict(name, pid1, pid2) do
    # kill the older PID
    node1 = :erlang.node(pid1)
    node2 = :erlang.node(pid2)

    {:ok, node1_uptime} = GenServer.call({Watchdog.Watcher, node1}, {:get_uptime})
    {:ok, node2_uptime} = GenServer.call({Watchdog.Watcher, node2}, {:get_uptime})

    if node1_uptime > node2_uptime do
      Logger.debug("resolving name conflict for #{name} - terminating older pid #{inspect(pid1)}")
      Process.exit(pid1, :name_conflict)
      pid2
    else
      Logger.debug("resolving name conflict for #{name} - terminating older pid #{inspect(pid2)}")
      Process.exit(pid2, :name_conflict)
      pid1
    end
  end
end
