defmodule Demoapp.TestServer do
  use Watchdog.SingletonGenServer

  require Logger

  def initial_state do
    %{times_started_at: [DateTime.utc_now()]}
  end

  def setup(state, %{was_imported: was_imported}) do
    if was_imported do
      Logger.info("started test server with imported state #{inspect(state)}")
    else
      Logger.info("started test server with state #{inspect(state)}")
    end

    {:ok, state}
  end

  # def handle_call({:sleep}, _, state) do
  #   Logger.info("sleeping")
  #   Process.sleep(5_000)
  #   {:reply, :ok, state}
  # end

  def import_state(initial_state, imported_state) do
    Map.put(
      initial_state,
      :times_started_at,
      initial_state.times_started_at ++ imported_state.times_started_at
    )
  end
end
