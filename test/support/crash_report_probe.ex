# sabotage: n/a - test plumbing, no lib/ behavior of its own
defmodule Statifier.CrashReportProbe do
  @moduledoc """
  A test-only `:logger` handler that forwards every OTP `{:proc_lib, :crash}`
  report to one process, as `{:crash_report, report}`.

  Elixir's primary `:logger_translator` filter drops SASL-domain reports
  (`handle_sasl_reports: false`), and a proc_lib crash report is one, so a
  `ExUnit.CaptureLog` capture never sees it. `attach/0` lifts that filter
  and adds this handler for the calling test; the `on_exit/1` it registers
  puts both back. Use it from an `async: false` test module only, because
  it changes the node's primary logger configuration.
  """

  @handler_id :statifier_crash_report_probe

  @doc """
  Forwards `{:proc_lib, :crash}` reports to the calling process until the
  test exits.
  """
  @spec attach() :: :ok
  def attach do
    test_pid = self()
    translator = Keyword.fetch(:logger.get_primary_config().filters, :logger_translator)

    if translator != :error, do: :ok = :logger.remove_primary_filter(:logger_translator)

    :ok = :logger.add_handler(@handler_id, __MODULE__, %{level: :all, config: %{pid: test_pid}})

    ExUnit.Callbacks.on_exit(fn ->
      :logger.remove_handler(@handler_id)

      with {:ok, filter} <- translator,
           do: :logger.add_primary_filter(:logger_translator, filter)
    end)

    :ok
  end

  @doc false
  @spec log(event :: :logger.log_event(), config :: :logger.handler_config()) :: :ok
  def log(%{msg: {:report, %{label: {:proc_lib, :crash}} = report}}, %{config: %{pid: pid}}) do
    send(pid, {:crash_report, report})
    :ok
  end

  def log(_event, _config), do: :ok
end
