defmodule Watchdog.Starter do
  use GenServer

  require Logger

  def start_link(module) do
    GenServer.start_link(__MODULE__, module)
  end

  def init(module) do
    Logger.info("starting singleton task #{module}")

    Watchdog.start_child(%{
      id: module,
      start: {module, :start_link, []},
      shutdown: 30_000
    })

    wait_for_process_to_be_up(module)

    :ignore
  end

  defp wait_for_process_to_be_up(process) do
    Logger.debug("waiting for #{process} to be up")

    wait_for_process_to_be_up(process, 0)
  end

  @spec wait_for_process_to_be_up(any, any) :: :ok
  def wait_for_process_to_be_up(process, attempt) do
    if attempt > 10_000 / 200 do
      raise "process #{process} never became up"
    else
      Watchdog.Registry.whereis_name(process)
      |> case do
        :undefined ->
          Process.sleep(200)
          wait_for_process_to_be_up(process, attempt + 1)

        _ ->
          Logger.debug("process #{process} is ready")
          :ok
      end
    end
  end
end
