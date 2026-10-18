defmodule Statifier.SessionTeardown do
  @moduledoc """
  Teardown for a session a test linked to itself.

  An `on_exit/1` callback runs after the test process has exited, and the
  session is linked to that process, so the session may exit at any moment
  while the callback runs. Checking `Process.alive?/1` and then calling
  `Statifier.Session.stop/1` races that exit: the stop then exits `:noproc`
  (or with the session's own exit reason) and fails the test after its
  assertions passed. A session that is already gone is what a teardown wants,
  so `stop/1` treats its exit as success.
  """

  # sabotage: n/a - teardown plumbing; it asserts no lib/ behaviour.
  @spec stop(session :: GenServer.server()) :: :ok
  def stop(session) do
    Statifier.Session.stop(session)
  catch
    :exit, _session_already_gone -> :ok
  end
end
