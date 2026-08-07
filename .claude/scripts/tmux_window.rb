#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"

# TmuxWindow is the tmux mechanics shared by /new-worktree (open a seeded
# window) and /cleanup-worktrees (find, classify, quiesce, close one), per
# docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 5. It carries the
# most fragile logic in the extraction: a byte-level idle classifier, an
# empty-window-id trap that cost a live window on 2026-08-02, and the rule
# that a session is only ever asked to exit, never signaled.
#
# Subcommands: ensure-session, open, find, classify, quiesce, close.
#
# Never kill-pane, never `kill -9`/SIGKILL, no code path that does - a
# quiesce timeout is reported `blocked`, not escalated. (`kill-window` on a
# window every one of whose panes is already a bare shell, in `close`, is not
# this rule - it targets nothing alive.)
module TmuxWindow
  SESSION = "statifier-ex"
  # Exact-match target. Fish and zsh expand a leading `=` as a command path
  # (equals-expansion), so a bare `-t =statifier-ex:` typed at a shell dies
  # with "statifier-ex: not found" before tmux ever sees it (verified
  # 2026-08-02). Sh.run always uses argv with no shell in between, so that
  # quoting hazard cannot occur here - this comment stays anyway, because
  # anyone reading a rendered `commands` line will copy it into a shell.
  SESSION_TARGET = "=#{SESSION}"
  MAIN_REPO = "/Users/johnnyt/repos/github/statifier-ex"

  SHELL_COMMANDS = %w[fish zsh bash sh].freeze

  # --model is an explicit constant, never left to whatever
  # ~/.claude/settings.json's global default happens to be. A skill's own
  # `model:` frontmatter governs that skill's invocation once a session is
  # already running; it does not govern the CLI session itself being
  # launched here, which is why this flag exists and must not be
  # "simplified" away.
  MODEL = "opus"

  # The convergence point every caller relies on: editing this one template
  # reaches every seeded session without touching the calling skills. `%s`
  # is the bead id, substituted per call.
  FINISH_TEMPLATE = " When the work is complete, finish with /commit --auto " \
                     "- it writes the Refs trailer and refuses if the tree " \
                     "carries changes unrelated to %s. Do not run git commit directly."

  # Spinner match: the timer chunk or the literal "esc to interrupt" -
  # *never* the verb ("Cooking…", "Forging…", ...), which is randomized per
  # frame and is not an exhaustive list this script could match against.
  SPINNER_TIMER = /\(\d+s · /
  SPINNER_INTERRUPT = "esc to interrupt"
  SGR = /\e\[[0-9;]*m/.freeze
  DIM_SPAN = /\e\[2m.*?\e\[0m/m.freeze

  QUIESCE_MAX_POLLS = 15
  QUIESCE_POLL_INTERVAL_SECONDS = 1
  CLASSIFY_SAMPLE_INTERVAL_SECONDS = 3

  class << self
    # Swappable sleep, the same shape as Sh.runner= - tests inject a no-op so
    # the poll loops below run at full speed against FakeSh instead of
    # actually waiting up to 15 real seconds.
    attr_writer :sleep_fn

    def sleep_fn
      @sleep_fn ||= ->(seconds) { Kernel.sleep(seconds) }
    end

    def run(argv, io: $stdout)
      argv = argv.dup
      sub = argv.shift

      case sub
      when "ensure-session" then ensure_session(argv, io)
      when "open" then open_window(argv, io)
      when "find" then find_window(argv, io)
      when "classify" then classify_cmd(argv, io)
      when "quiesce" then quiesce(argv, io)
      when "close" then close_window(argv, io)
      else
        warn usage
        exit 2
      end
    end

    # The idle classifier, as a pure function over already-captured pane
    # text (`tmux capture-pane -e -p`'s stdout) - no I/O in here, which is
    # what makes it testable against byte-for-byte fixtures.
    #
    # -e is required upstream: Claude Code renders a greyed-out suggested
    # next prompt in an otherwise-empty input box, and without -e's ANSI
    # styling that placeholder is indistinguishable from real typed text -
    # every idle session with a suggestion reads as busy. Real typed text is
    # never wrapped in the dim/faint SGR span; only the placeholder is.
    #
    # Returns "busy" or "idle". Callers that need to tell an empty box apart
    # from a placeholder box can inspect the source; the sampling contract
    # (idle both times, ~3s apart) only ever needs this boolean.
    def classify(text)
      # tmux capture-pane's stdout is normally UTF-8, but a raw/binmode read
      # (as the fixture files use) comes back ASCII-8BIT; force it back so
      # the UTF-8 regex literals below (❯) can match against it.
      text = text.to_s.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub unless text.valid_encoding?
      return "busy" if text.include?(SPINNER_INTERRUPT) || text =~ SPINNER_TIMER

      last = last_prompt_line(text)
      return "idle" if last.nil?

      after_marker = last.sub(/\A.*?❯ ?/, "")
      return "idle" unless visible_text?(after_marker)

      wholly_dim_wrapped?(after_marker) ? "idle" : "busy"
    end

    private

    def usage
      "usage: tmux_window.rb <ensure-session|open|find|classify|quiesce|close> [options]"
    end

    # --- classify helpers ------------------------------------------------

    # The transcript echoes every user message with the same ❯ marker, so an
    # earlier line says nothing about the current state - only the last one
    # does.
    def last_prompt_line(text)
      lines = text.each_line.map(&:chomp).select { |l| l.include?("❯") }
      lines.last
    end

    # False when what follows the marker is nothing, or only SGR codes
    # (\e[39m, \e[0m, ...) with no visible characters.
    def visible_text?(after_marker)
      !after_marker.gsub(SGR, "").strip.empty?
    end

    # True when every visible character after the marker sits inside a
    # \e[2m ... \e[0m span - Claude's suggested-prompt placeholder. Strip
    # complete dim spans first; if anything visible survives outside them,
    # this is real typed text (a draft, or a dialog like " ❯ 1. Yes"), not a
    # placeholder.
    def wholly_dim_wrapped?(after_marker)
      remaining = after_marker.gsub(DIM_SPAN, "")
      remaining.gsub(SGR, "").strip.empty?
    end

    # --- ensure-session ----------------------------------------------------

    def ensure_session(argv, io)
      parser, options = Cli.build("tmux_window.rb ensure-session [options]")
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "tmux_window_ensure_session")
      dry_run = options[:dry_run]

      has_argv = ["tmux", "has-session", "-t", SESSION_TARGET]
      new_argv = ["tmux", "new-session", "-d", "-s", SESSION, "-c", MAIN_REPO]

      if dry_run
        env.commands << Sh.render(has_argv)
        env.commands << "(only if has-session fails) " + Sh.render(new_argv)
        env.data["session"] = SESSION
        return env.emit(io)
      end

      has_res = Sh.run(has_argv, envelope: env)
      if has_res.success?
        env.data["session"] = SESSION
        env.data["created"] = false
        return env.emit(io)
      end

      new_res = Sh.run(new_argv, envelope: env)
      unless new_res.success?
        env.block!(code: "session_create_failed", message: err_or(new_res, "tmux new-session failed"))
        return env.emit(io)
      end

      env.data["session"] = SESSION
      env.data["created"] = true
      env.emit(io)
    end

    # --- open --------------------------------------------------------------

    def open_window(argv, io)
      parser, options = Cli.build("tmux_window.rb open [options] <name> <path> <id> <seed>")
      args = Cli.parse!(parser, argv)
      name, path, id, seed = args
      if [name, path, id, seed].any? { |a| blank?(a) }
        usage_error!("tmux_window.rb open <name> <path> <id> <seed>", parser)
      end

      env = Envelope.new(script: "tmux_window_open")
      dry_run = options[:dry_run]

      # Guard on the window name, the same way worktree_create.rb refuses an
      # existing branch or directory - a hit here is a normal outcome
      # (report and skip), never a reason to create a second window with the
      # same name.
      list_argv = ["tmux", "list-windows", "-t", SESSION_TARGET, "-F", '#{window_name}']
      list_res = Sh.run(list_argv, envelope: env)
      if list_res.success? && list_res.out.to_s.each_line.map(&:chomp).include?(name)
        env.data["name"] = name
        env.data["path"] = path
        env.data["skipped"] = true
        env.data["reason"] = "window #{name} already exists"
        return env.emit(io)
      end

      keys = "claude --permission-mode auto --model #{MODEL} '#{seed}.#{FINISH_TEMPLATE % id}'"
      new_argv = ["tmux", "new-window", "-d", "-P", "-F", '#{window_id}', "-t", "#{SESSION_TARGET}:", "-n", name, "-c", path]

      if dry_run
        env.commands << Sh.render(new_argv)
        env.commands << Sh.render(["tmux", "send-keys", "-t", "$win", keys, "Enter"])
        env.data["name"] = name
        env.data["path"] = path
        env.data["model"] = MODEL
        env.data["skipped"] = false
        return env.emit(io)
      end

      new_res = Sh.run(new_argv, envelope: env)
      window_id = new_res.out.to_s.strip

      # Refuse to issue any -t command when the captured id is empty. An
      # empty -t "" does not error - tmux resolves it to the *current*
      # window, which cost a live window on 2026-08-02.
      if !new_res.success? || window_id.empty?
        env.block!(
          code: "window_id_empty",
          message: "tmux new-window produced no window id for #{name.inspect}; " \
                    "refusing to target -t with an empty id (#{err_or(new_res, 'no output')})"
        )
        return env.emit(io)
      end

      send_res = Sh.run(["tmux", "send-keys", "-t", window_id, keys, "Enter"], envelope: env)
      env.warn(code: "send_keys_failed", message: err_or(send_res, "tmux send-keys failed")) unless send_res.success?

      env.data["window_id"] = window_id
      env.data["name"] = name
      env.data["path"] = path
      env.data["model"] = MODEL
      env.data["skipped"] = false
      env.emit(io)
    end

    # --- find ----------------------------------------------------------------

    def find_window(argv, io)
      parser, = Cli.build("tmux_window.rb find [options] <name> <path>")
      args = Cli.parse!(parser, argv)
      name, path = args
      usage_error!("tmux_window.rb find <name> <path>", parser) if blank?(name) || blank?(path)

      env = Envelope.new(script: "tmux_window_find")
      list_argv = ["tmux", "list-panes", "-a", "-F", '#{window_id} #{window_name} #{pane_current_path}']
      res = Sh.run(list_argv, envelope: env)

      unless res.success?
        env.data["found"] = false
        env.data["window_id"] = nil
        env.warn(code: "list_panes_failed", message: err_or(res, "tmux list-panes failed"))
        return env.emit(io)
      end

      # Match on name and path together - matching on name alone would close
      # a window a human renamed onto something else; matching on path alone
      # would close a stray shell someone happened to cd there.
      matches = res.out.to_s.each_line.map(&:chomp).reject(&:empty?)
                   .map { |l| l.split(" ", 3) }
                   .select { |_wid, wname, wpath| wname == name && wpath == path }

      case matches.length
      when 0
        env.data["found"] = false
        env.data["window_id"] = nil
      when 1
        env.data["found"] = true
        env.data["window_id"] = matches.first[0]
      else
        env.block!(
          code: "ambiguous_window_match",
          message: "more than one window matches name=#{name.inspect} path=#{path.inspect}: " \
                    "#{matches.map { |m| m[0] }.join(', ')} - two windows claiming one worktree is a state a human should look at"
        )
      end

      env.emit(io)
    end

    # --- classify (subcommand: does the I/O, calls the pure classify) -----

    def classify_cmd(argv, io)
      parser, = Cli.build("tmux_window.rb classify [options] <window_id>")
      args = Cli.parse!(parser, argv)
      window_id = args.first

      env = Envelope.new(script: "tmux_window_classify")
      if blank?(window_id)
        env.block!(code: "empty_window_id", message: "refusing to capture: empty window id would target -t as the current window")
        return env.emit(io)
      end

      first = capture_and_classify(window_id, env)
      TmuxWindow.sleep_fn.call(CLASSIFY_SAMPLE_INTERVAL_SECONDS)
      second = capture_and_classify(window_id, env)

      # Sample twice, ~3s apart, and require idle both times - one capture
      # can land in the gap between a turn ending and the next tool call
      # starting.
      status = (first == "idle" && second == "idle") ? "idle" : "busy"

      env.data["window_id"] = window_id
      env.data["samples"] = [first, second]
      env.data["status"] = status
      env.emit(io)
    end

    def capture_and_classify(window_id, env)
      res = Sh.run(["tmux", "capture-pane", "-e", "-p", "-t", window_id], envelope: env)
      return "busy" unless res.success?

      TmuxWindow.classify(res.out)
    end

    # --- quiesce -----------------------------------------------------------

    def quiesce(argv, io)
      parser, options = Cli.build("tmux_window.rb quiesce [options] <window_id>")
      args = Cli.parse!(parser, argv)
      window_id = args.first

      env = Envelope.new(script: "tmux_window_quiesce")
      if blank?(window_id)
        env.block!(code: "empty_window_id", message: "refusing to quiesce: empty window id would target -t as the current window")
        return env.emit(io)
      end

      poll_argv = ["tmux", "list-panes", "-t", window_id, "-F", '#{pane_current_command}']

      if options[:dry_run]
        env.commands << Sh.render(["tmux", "send-keys", "-t", window_id, "C-u"])
        env.commands << Sh.render(["tmux", "send-keys", "-t", window_id, "/exit", "Enter"])
        env.commands << Sh.render(poll_argv)
        env.data["window_id"] = window_id
        return env.emit(io)
      end

      # C-u first, so /exit cannot land appended to leftover text in the
      # input line.
      Sh.run(["tmux", "send-keys", "-t", window_id, "C-u"], envelope: env)
      Sh.run(["tmux", "send-keys", "-t", window_id, "/exit", "Enter"], envelope: env)

      exited = poll_for_shell(window_id, poll_argv, env)

      env.data["window_id"] = window_id
      if exited
        env.data["status"] = "exited"
      else
        # Never kill-pane, never SIGKILL. A session that will not take
        # /exit is doing something, and the point of this step is to not be
        # the thing that interrupts it - a timeout is reported, not escalated.
        env.block!(
          code: "quiesce_timeout",
          message: "session in window #{window_id} did not exit within " \
                    "#{QUIESCE_MAX_POLLS * QUIESCE_POLL_INTERVAL_SECONDS}s of /exit"
        )
      end

      env.emit(io)
    end

    def poll_for_shell(window_id, poll_argv, env)
      QUIESCE_MAX_POLLS.times do |i|
        res = Sh.run(poll_argv, envelope: env)
        commands = res.out.to_s.each_line.map(&:chomp).reject(&:empty?)
        return true if res.success? && !commands.empty? && commands.all? { |c| SHELL_COMMANDS.include?(c) }

        TmuxWindow.sleep_fn.call(QUIESCE_POLL_INTERVAL_SECONDS) unless i == QUIESCE_MAX_POLLS - 1
      end
      false
    end

    # --- close ---------------------------------------------------------------

    def close_window(argv, io)
      parser, options = Cli.build("tmux_window.rb close [options] <window_id>")
      args = Cli.parse!(parser, argv)
      window_id = args.first

      env = Envelope.new(script: "tmux_window_close")
      if blank?(window_id)
        env.block!(code: "empty_window_id", message: "refusing to close: empty window id would target -t as the current window")
        return env.emit(io)
      end

      panes_argv = ["tmux", "list-panes", "-t", window_id, "-F", '#{pane_current_command}']
      res = Sh.run(panes_argv, envelope: env)
      unless res.success?
        env.block!(code: "list_panes_failed", message: err_or(res, "tmux list-panes failed for window #{window_id}"))
        return env.emit(io)
      end

      commands = res.out.to_s.each_line.map(&:chomp).reject(&:empty?)
      all_bare_shells = !commands.empty? && commands.all? { |c| SHELL_COMMANDS.include?(c) }

      unless all_bare_shells
        env.data["window_id"] = window_id
        env.data["closed"] = false
        env.data["reason"] = "window kept, other panes busy"
        return env.emit(io)
      end

      kill_argv = ["tmux", "kill-window", "-t", window_id]

      if options[:dry_run]
        env.commands << Sh.render(kill_argv)
        env.data["window_id"] = window_id
        env.data["closed"] = false
        env.data["reason"] = "all panes bare shell, would close"
        return env.emit(io)
      end

      kill_res = Sh.run(kill_argv, envelope: env)
      unless kill_res.success?
        env.warn(code: "kill_window_failed", message: err_or(kill_res, "tmux kill-window failed for #{window_id}"))
        env.data["window_id"] = window_id
        env.data["closed"] = false
        return env.emit(io)
      end

      env.data["window_id"] = window_id
      env.data["closed"] = true
      env.emit(io)
    end

    # --- shared helpers ------------------------------------------------------

    def blank?(value)
      value.to_s.strip.empty?
    end

    def err_or(result, fallback)
      msg = result.err.to_s.strip
      msg.empty? ? fallback : msg
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end
  end
end

exit TmuxWindow.run(ARGV) if __FILE__ == $PROGRAM_NAME
