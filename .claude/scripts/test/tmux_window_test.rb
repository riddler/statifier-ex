# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../tmux_window"
require_relative "support/fake_sh"

# TmuxWindow::classify against captured fixtures, verbatim from
# cleanup-worktrees/SKILL.md's idle-classifier section: dim placeholder,
# half-typed draft, dialog, empty box, spinner frame, and a spinner frame
# whose verb is one not listed anywhere - proving the verb is never matched.
# Fixtures are raw bytes (real ESC 0x1b, not "\e" as literal backslash-e
# text) under test/fixtures/pane/, the same shape `tmux capture-pane -e -p`
# emits.
class TmuxWindowClassifyTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/pane", __dir__)

  def fixture(name)
    File.read(File.join(FIXTURES, name), mode: "rb")
  end

  def test_dim_placeholder_is_idle
    assert_equal "idle", TmuxWindow.classify(fixture("dim_placeholder.txt"))
  end

  def test_half_typed_draft_is_busy
    assert_equal "busy", TmuxWindow.classify(fixture("half_typed_draft.txt"))
  end

  def test_dialog_awaiting_an_answer_is_busy
    assert_equal "busy", TmuxWindow.classify(fixture("dialog.txt"))
  end

  def test_empty_box_is_idle
    assert_equal "idle", TmuxWindow.classify(fixture("empty_box.txt"))
  end

  def test_spinner_frame_is_busy
    assert_equal "busy", TmuxWindow.classify(fixture("spinner_frame.txt"))
  end

  # The verb ("Bamboozling…") appears nowhere in TmuxWindow - only the timer
  # chunk ("(12s · ") drives the match. If this ever started matching on the
  # verb text, this fixture (whose verb is invented and matches no known
  # spinner word) would flip to idle.
  def test_spinner_with_an_unlisted_verb_is_still_busy
    assert_equal "busy", TmuxWindow.classify(fixture("spinner_unlisted_verb.txt"))
  end

  def test_fixtures_carry_real_escape_bytes_not_the_literal_backslash_e_text
    dim = fixture("dim_placeholder.txt")
    refute_includes dim, "\\e[2m", "fixture should hold a real ESC byte, not the literal two-character sequence \\e"
    assert_includes dim, "\e[2m", "fixture is missing the real ESC (0x1b) byte tmux capture-pane -e actually emits"
  end

  def test_classify_takes_only_the_last_marker_line
    # dim_placeholder.txt's first ❯ line is real, visible, non-dim text
    # ("discard the model change") - if classify read that line instead of
    # the last one, this would come back busy.
    text = fixture("dim_placeholder.txt")
    assert_equal "idle", TmuxWindow.classify(text)
  end
end

class TmuxWindowTest < Minitest::Test
  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    TmuxWindow.sleep_fn = ->(_seconds) {} # never really sleep in tests
  end

  def teardown
    Sh.runner = nil
    TmuxWindow.sleep_fn = nil
  end

  def run_tmux(argv)
    io = StringIO.new
    code = TmuxWindow.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # --- ensure-session ------------------------------------------------------

  def test_ensure_session_reuses_an_existing_session
    @fake.expect(["tmux", "has-session", "-t", "=statifier-ex"], exitstatus: 0)

    code, env = run_tmux(["ensure-session"])

    assert_equal 0, code
    assert_equal false, env["data"]["created"]
  end

  def test_ensure_session_creates_when_missing
    @fake.expect(["tmux", "has-session", "-t", "=statifier-ex"], exitstatus: 1)
    @fake.expect(
      ["tmux", "new-session", "-d", "-s", "statifier-ex", "-c", "/Users/johnnyt/repos/github/statifier-ex"],
      exitstatus: 0
    )

    code, env = run_tmux(["ensure-session"])

    assert_equal 0, code
    assert_equal true, env["data"]["created"]
  end

  def test_ensure_session_dry_run_issues_no_commands
    code, env = run_tmux(["ensure-session", "--dry-run"])

    assert_equal 0, code
    assert env["commands"].any? { |c| c.include?("has-session") }
    assert env["commands"].any? { |c| c.include?("new-session") }
  end

  # --- open ------------------------------------------------------------------

  def test_open_creates_a_window_and_seeds_it
    @fake.expect(["tmux", "list-windows", "-t", "=statifier-ex", "-F", '#{window_name}'], out: "other-window\n")
    @fake.expect(
      ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "=statifier-ex:", "-n", "st-abc-thing",
       "-c", "/Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-thing"],
      out: "@42\n"
    )
    @fake.expect(["tmux", "send-keys", "-t", "@42"], out: "")

    code, env = run_tmux([
                            "open", "st-abc-thing", "/Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-thing",
                            "st-abc", "/work st-abc --auto"
                          ])

    assert_equal 0, code
    assert_equal "@42", env["data"]["window_id"]
    assert_equal "opus", env["data"]["model"]
    assert_equal false, env["data"]["skipped"]

    send_call = @fake.calls.find { |c| c.argv[0, 2] == %w[tmux send-keys] }
    assert_equal "@42", send_call.argv[3]
    keys = send_call.argv[4]
    assert_includes keys, "claude --permission-mode auto --model opus"
    assert_includes keys, "/work st-abc --auto"
    assert_includes keys, "/commit --auto"
    assert_includes keys, "unrelated to st-abc"
    assert_equal "Enter", send_call.argv[5]
  end

  def test_open_skips_when_window_name_already_exists
    @fake.expect(["tmux", "list-windows", "-t", "=statifier-ex", "-F", '#{window_name}'], out: "st-abc-thing\n")
    # No new-window or send-keys expectation - a name hit must not create a
    # second window.

    code, env = run_tmux(["open", "st-abc-thing", "/some/path", "st-abc", "/work st-abc --auto"])

    assert_equal 0, code
    assert_equal true, env["data"]["skipped"]
  end

  def test_open_never_sends_keys_when_the_captured_window_id_is_empty
    @fake.expect(["tmux", "list-windows", "-t", "=statifier-ex", "-F", '#{window_name}'], out: "")
    @fake.expect(["tmux", "new-window"], out: "") # empty id despite success
    # No send-keys expectation registered at all - FakeSh raises if the code
    # tries. An empty -t "" resolves to the *current* window in real tmux,
    # which cost a live window on 2026-08-02.

    code, env = run_tmux(["open", "st-abc-thing", "/some/path", "st-abc", "/work st-abc --auto"])

    assert_equal 1, code
    assert_equal "window_id_empty", env["blocked"].first["code"]
  end

  def test_open_dry_run_renders_a_pasteable_command_line
    @fake.expect(["tmux", "list-windows", "-t", "=statifier-ex", "-F", '#{window_name}'], out: "")

    code, env = run_tmux([
                            "open", "--dry-run", "st-abc-thing",
                            "/Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-thing",
                            "st-abc", "/work st-abc --auto"
                          ])

    assert_equal 0, code
    send_line = env["commands"].find { |c| c.include?("send-keys") }
    refute_nil send_line
    assert_includes send_line, "claude --permission-mode auto --model opus"
    # Sh.render single-quotes the seeded-command argument, exactly what a
    # human would type at a fish prompt.
    assert_match(/'.*claude --permission-mode auto --model opus.*'/, send_line)
  end

  # --- find --------------------------------------------------------------

  def test_find_matches_on_name_and_path_together
    @fake.expect(
      ["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}'],
      out: "@1 other-name /some/other/path\n@2 st-abc-thing /Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-thing\n"
    )

    code, env = run_tmux(["find", "st-abc-thing", "/Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-thing"])

    assert_equal 0, code
    assert_equal true, env["data"]["found"]
    assert_equal "@2", env["data"]["window_id"]
  end

  def test_find_no_match_is_not_an_error
    @fake.expect(
      ["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}'],
      out: "@1 other-name /some/other/path\n"
    )

    code, env = run_tmux(["find", "st-abc-thing", "/nowhere"])

    assert_equal 0, code
    assert_equal false, env["data"]["found"]
    assert_nil env["data"]["window_id"]
  end

  def test_find_two_matching_windows_blocks
    out = "@1 st-abc-thing /Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-thing\n" \
          "@2 st-abc-thing /Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-thing\n"
    @fake.expect(["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}'], out: out)

    code, env = run_tmux(["find", "st-abc-thing", "/Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-thing"])

    assert_equal 1, code
    assert_equal "ambiguous_window_match", env["blocked"].first["code"]
  end

  # --- classify (subcommand) ------------------------------------------------

  def test_classify_cmd_requires_both_samples_idle
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf \e[39m\n")
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf \e[39m\n")

    code, env = run_tmux(["classify", "@2"])

    assert_equal 0, code
    assert_equal "idle", env["data"]["status"]
    assert_equal %w[idle idle], env["data"]["samples"]
  end

  def test_classify_cmd_one_busy_sample_is_enough_to_call_it_busy
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf half a draft\n")
    @fake.expect(["tmux", "capture-pane", "-e", "-p", "-t", "@2"], out: "\xe2\x9d\xaf \e[39m\n")

    code, env = run_tmux(["classify", "@2"])

    assert_equal 0, code
    assert_equal "busy", env["data"]["status"]
  end

  def test_classify_cmd_never_captures_with_an_empty_window_id
    code, env = run_tmux(["classify", ""])

    assert_equal 1, code
    assert_equal "empty_window_id", env["blocked"].first["code"]
    assert_empty @fake.calls
  end

  # --- quiesce -------------------------------------------------------------

  def test_quiesce_sends_ctrl_u_then_exit_then_polls_to_a_bare_shell
    @fake.expect(["tmux", "send-keys", "-t", "@2", "C-u"], out: "")
    @fake.expect(["tmux", "send-keys", "-t", "@2", "/exit", "Enter"], out: "")
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "2.1.220\n")
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")

    code, env = run_tmux(["quiesce", "@2"])

    assert_equal 0, code
    assert_equal "exited", env["data"]["status"]
  end

  def test_quiesce_timeout_is_blocked_not_escalated
    @fake.expect(["tmux", "send-keys", "-t", "@2", "C-u"], out: "")
    @fake.expect(["tmux", "send-keys", "-t", "@2", "/exit", "Enter"], out: "")
    15.times { @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "2.1.220\n") }
    # No further expectations - a timeout must not try anything else, kill
    # included.

    code, env = run_tmux(["quiesce", "@2"])

    assert_equal 1, code
    assert_equal "quiesce_timeout", env["blocked"].first["code"]
  end

  def test_quiesce_never_issues_a_command_with_an_empty_window_id
    code, env = run_tmux(["quiesce", ""])

    assert_equal 1, code
    assert_equal "empty_window_id", env["blocked"].first["code"]
    assert_empty @fake.calls
  end

  def test_quiesce_dry_run_issues_no_commands
    code, env = run_tmux(["quiesce", "--dry-run", "@2"])

    assert_equal 0, code
    assert env["commands"].any? { |c| c.include?("/exit") }
    assert_empty @fake.calls
  end

  # --- close -----------------------------------------------------------------

  def test_close_kills_the_window_when_every_pane_is_a_bare_shell
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "fish\n")
    @fake.expect(["tmux", "kill-window", "-t", "@2"], out: "")

    code, env = run_tmux(["close", "@2"])

    assert_equal 0, code
    assert_equal true, env["data"]["closed"]
  end

  def test_close_keeps_the_window_when_a_pane_is_busy
    @fake.expect(["tmux", "list-panes", "-t", "@2", "-F", '#{pane_current_command}'], out: "2.1.220\n")
    # No kill-window expectation - a live pane must never be closed.

    code, env = run_tmux(["close", "@2"])

    assert_equal 0, code
    assert_equal false, env["data"]["closed"]
    assert_match(/other panes busy/, env["data"]["reason"])
  end

  def test_close_never_issues_a_command_with_an_empty_window_id
    code, env = run_tmux(["close", ""])

    assert_equal 1, code
    assert_equal "empty_window_id", env["blocked"].first["code"]
    assert_empty @fake.calls
  end

  # --- source-level guarantees ------------------------------------------

  # The three banned kill operations are allowed to appear in the one
  # header comment in tmux_window.rb that forbids them (see the plan's own
  # grep check in docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase
  # 5), but never in a line that isn't a comment. The needles are assembled
  # at runtime, not spelled out contiguously here, so this test file itself
  # doesn't add a second grep hit next to the one that comment permits.
  def test_banned_kill_operations_appear_only_in_the_forbidding_comment
    needles = ["kill" + "-pane", "kill" + " -9", "SIG" + "KILL"]
    banned = Regexp.union(needles.map { |n| Regexp.new(Regexp.escape(n)) })

    source = File.read(File.expand_path("../tmux_window.rb", __dir__))
    hits = source.each_line.select { |l| l =~ banned }

    refute_empty hits, "expected the forbidding comment to be present"
    hits.each do |line|
      assert_match(/\A\s*#/, line, "found a banned kill operation outside a comment: #{line.inspect}")
    end
  end

  def test_kill_window_only_targets_a_window_confirmed_all_bare_shells
    # tmux's window-level close (distinct from the banned pane/signal kills
    # above) is legitimate in close_window, but only ever issued after
    # list-panes confirms every pane is a bare shell.
    @fake.expect(["tmux", "list-panes", "-t", "@2", '-F', '#{pane_current_command}'], out: "fish\nzsh\n")
    @fake.expect(["tmux", "kill-window", "-t", "@2"], out: "")

    code, env = run_tmux(["close", "@2"])

    assert_equal 0, code
    assert_equal true, env["data"]["closed"]
  end
end
