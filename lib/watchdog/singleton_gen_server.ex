defmodule Watchdog.SingletonGenServer do
  @moduledoc """
  This module provides a singleton GenServer. Watchdog will automatically monitor the process and transfer state between processes when shutting down.

  The functions that need to be implemented in the GenServer to make this work are:

    initial_state/0: return a map with the initial state of the GenServer (or %{})

    setup/2: receives {state, %{was_imported: true/false}} as arguments, performs any necessary setup and returns the same arguments as init normally would

    import_state/2: receives {current_state, state_to_import}, does any necessary work to get the import state into the current state, then returns the new state
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer
      require Logger

      def via_tuple(), do: Watchdog.via_tuple(__MODULE__)

      def start_link() do
        GenServer.start_link(__MODULE__, [], name: via_tuple())
      end

      def start_link(state) do
        GenServer.start_link(__MODULE__, state, name: via_tuple())
      end

      def init(%{state_to_import: %{state: state_to_import, mailbox: messages_to_import}}) do
        Process.flag(:trap_exit, true)

        Enum.each(messages_to_import, fn message ->
          send(self(), message)
        end)

        setup(import_state(initial_state(), state_to_import), %{was_imported: true})
      end

      def init(_) do
        Process.flag(:trap_exit, true)

        setup(initial_state(), %{was_imported: false})
      end

      def handle_info({:EXIT, _from, :name_conflict}, state) do
        {:stop, {:shutdown, :name_conflict}, state}
      end

      def handle_cast(
            {:import_state, %{state: state_to_import, mailbox: messages_to_import}},
            state
          ) do
        Logger.debug(
          "importing state #{inspect(state_to_import)} into current process from terminating process"
        )

        Enum.each(messages_to_import, fn message ->
          send(self(), message)
        end)

        {:noreply, import_state(state, state_to_import)}
      end

      def handle_cast({:debug_dump_state}, state) do
        IO.inspect(state)

        {:noreply, state}
      end

      def terminate(:shutdown, state) do
        Logger.info(
          "#{__MODULE__} pid #{inspect(self())} is shutting down, starting replacement on another node"
        )

        Watchdog.start_on_another_node(__MODULE__, self(), %{
          state: state,
          mailbox: get_process_mailbox()
        })
      end

      def terminate({:shutdown, :name_conflict}, state) do
        Watchdog.Registry.sync()
        main_process = Watchdog.Registry.whereis_name(__MODULE__)

        Logger.info(
          "#{__MODULE__} pid #{inspect(self())} terminating due to name conflict, exporting state to current leader process #{inspect(main_process)}"
        )

        GenServer.cast(
          main_process,
          {:import_state, %{state: state, mailbox: get_process_mailbox()}}
        )
      end

      def terminate(reason, _state) do
        Logger.info(
          "#{__MODULE__} pid #{inspect(self())} terminating with reason #{inspect(reason)}, not exporting state"
        )
      end

      defp get_process_mailbox do
        Process.info(self(), :messages) |> elem(1)
      end
    end
  end
end
