defmodule Watchdog.Watcher do
  require Logger

  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    {:ok, %{age: DateTime.utc_now(), pids_to_process_specs: %{}}}
  end

  def handle_info({:DOWN, _, :process, pid, :normal}, state) do
    # stopped cleanly, so remove from monitoring

    {child_spec, new_state} = remove_pid_from_state(state, pid)

    if child_spec do
      Logger.info(
        "received notification that process #{pretty_print_child_spec(child_spec)} has terminated normally, not restarting"
      )
    end

    {:noreply, new_state}
  end

  def handle_info({:DOWN, _, :process, pid, _reason}, state) do
    # managed process exited with an error, so try restarting
    {child_spec, new_state} = remove_pid_from_state(state, pid)

    if is_nil(child_spec) do
      {:noreply, new_state}
    else
      if check_if_replacement_already_monitored(state, pid, child_spec) do
        Logger.info(
          "received notification that process #{pretty_print_child_spec(child_spec)} has gone down, replacement already monitored"
        )

        {:noreply, state}
      else
        Logger.info(
          "received notification that process #{pretty_print_child_spec(child_spec)} has gone down, attempting restart"
        )

        {:noreply, start_and_monitor(new_state, child_spec)}
      end
    end
  end

  def handle_call({:start_child, child_spec}, _from, state) do
    {:reply, :ok, start_and_monitor(state, child_spec)}
  end

  def handle_call(
        {:start_replacement_process, name, existing_pid, imported_state},
        _from,
        state
      ) do
    Logger.info("starting replacement process for #{name} on local node with imported state")

    if state[:pids_to_process_specs][existing_pid] do
      :ok = Watchdog.Registry.unregister_name(name)

      {:reply, :ok,
       start_and_monitor(state, state[:pids_to_process_specs][existing_pid], imported_state)}
    else
      {:reply, {:error, :unknown_pid}, state}
    end
  end

  def handle_call({:get_uptime}, _from, state) do
    {:reply, {:ok, DateTime.diff(DateTime.utc_now(), state.age, :millisecond)}, state}
  end

  defp remove_pid_from_state(state, pid) do
    Kernel.pop_in(state[:pids_to_process_specs][pid])
  end

  defp start_and_monitor(state, child_spec, imported_state \\ %{}) do
    # we force the child to never be automatically restarted by the supervisor
    # because otherwise an {:error, :already_started} would send the supervisor
    # into a restart loop.

    # we monitor and handle restarts in the watcher, so the supervisor handling it
    # is not necessary

    start_result =
      DynamicSupervisor.start_child(
        Watchdog.Supervisor,
        if map_size(imported_state) > 0 do
          Map.merge(child_spec, %{
            restart: :temporary,
            start:
              child_spec.start
              |> put_elem(2, [%{state_to_import: imported_state}])
          })
        else
          Map.merge(child_spec, %{restart: :temporary})
        end
      )

    pid =
      case start_result do
        {:ok, pid} ->
          Logger.info(
            "watchdog started #{pretty_print_child_spec(child_spec)} process with pid #{inspect(pid)}"
          )

          pid

        {:error, {:already_started, pid}} ->
          Logger.info(
            "#{pretty_print_child_spec(child_spec)} process already started with pid #{inspect(pid)}, monitoring"
          )

          pid
      end

    Process.monitor(pid)

    Kernel.put_in(state, [:pids_to_process_specs, pid], child_spec)
  end

  defp pretty_print_child_spec(%{id: id}) do
    id
  end

  defp process_name_from_child_spec(%{start: {name, _, _}}) do
    name
  end

  defp check_if_replacement_already_monitored(state, existing_pid, child_spec) do
    process_name = process_name_from_child_spec(child_spec)

    Watchdog.Registry.sync()

    Watchdog.Registry.whereis_name(process_name)
    |> case do
      pid when is_pid(pid) and pid != existing_pid ->
        if state[:pids_to_process_specs][pid] do
          true
        else
          false
        end

      _ ->
        false
    end
  end
end
