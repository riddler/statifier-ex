defmodule Statifier.Session.HaltNoticeTest do
  use ExUnit.Case, async: true

  # `Statifier.Session.HaltNotice.watch/2` called inside a session that has
  # already halted: the moduledoc's "a process watched after the session
  # has halted is sent the notice at once". No send processor's
  # `perform/2` runs once a session has halted, so the test runs `watch/2`
  # in the halted session's own process through `:sys.replace_state/2`,
  # which runs the function there and answers only after it returns.

  alias Statifier.Session
  alias Statifier.Session.HaltNotice

  @returned """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
        <state id="on_loan">
          <transition target="returned"/>
        </state>
        <final id="returned"/>
      </scxml>
  """

  # Runs `HaltNotice.watch/2` in `session`'s own process and answers what it
  # answered, leaving the session's state as it was.
  defp watch_inside(session, key, pid) do
    test = self()

    :sys.replace_state(session, fn state ->
      send(test, {:watch_answered, HaltNotice.watch(key, pid)})
      state
    end)

    assert_receive {:watch_answered, answer}, 5_000
    answer
  end

  describe "watch/2 after the session has halted" do
    # sabotage: `watch/2` calls `notify_halted(:running, [pid])` instead of
    # passing the session's halted status -> no notice is sent and the
    # `assert_received` of `{:statifier_halted, ...}` reddens
    test "the watched process is sent the halted notice at once" do
      {:ok, machine} = Statifier.compile(@returned)
      {:ok, session} = Statifier.start_session(machine, subscribers: [self()])
      on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
      session_id = Session.session_id(session)

      assert_receive {:statifier, ^session_id, {:halted, :done}}, 5_000
      assert Process.alive?(session)

      watcher = self()
      assert :ok == watch_inside(session, :loan_timer, watcher)

      # The notice is sent inside `watch/2`, before the answer the session sends
      # this process after it, so it is already in the mailbox: at once.
      assert_received {:statifier_halted, ^session, :done}
    end
  end
end
