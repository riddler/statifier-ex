#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"
require_relative "lib/touches_elixir"

# Gate wraps `mix gate.verify` and `mix quality --format json --report -`,
# serving /commit, /merge-request, /implement-plan, and /work. See
# docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 7 - this is the
# most constrained script in the set: it must make the gate easier to read
# without making it easier to weaken.
#
# Three rules that are load-bearing, not incidental:
#
# 1. `data.skipped_stages` always stays in the payload, and `ok` is false
#    whenever the gate ran (`data.applicable`) and any stage came back
#    skipped, for any reason. CLAUDE.md: "a skipped stage is not a passing
#    one" - a summary that drops it launders exactly what that rule
#    protects. This is *stricter* than `mix gate.verify`'s own
#    `data.attested`, which lets a project-level skip (e.g. `adr_judge`
#    disabled) still attest - the two fields answer different questions on
#    purpose: `attested` mirrors ADR-0011's narrowing test, `ok` mirrors
#    CLAUDE.md's "say so, don't summarize it away" rule.
# 2. This script accepts exactly one profile argument, `--profile loop`, and
#    forwarding it always sets `attested: false`. Every other `--profile`
#    value, and `--skip`/`--quick` in any form, are simply not options this
#    parser defines - OptionParser rejects them as usage errors (exit 2)
#    before any envelope is built. There is no flag this script owns that
#    narrows what `mix quality` runs beyond that one case.
# 3. `data.sabotage.missing` and `data.gate_guard` are reports. Neither ever
#    flips `ok`, and there is no code path anywhere in this file that writes
#    docs/quality-gate-changes.md - see test/contract_test.rb.
module Gate
  LEDGER_PATH = "docs/quality-gate-changes.md"

  SABOTAGE_DIFF_ARGS = %w[
    git diff main...HEAD -U0 -- test/ :!test/scion_tests :!test/scxml_tests
  ].freeze

  # Matches both accepted note forms - a real mutation
  # (`# sabotage: <what> -> red`) and a stated exemption
  # (`# sabotage: n/a - <why>`) - because both start with the same prefix.
  # Presence is all this checks: docs/testing.md and /commit's Step 0 own the
  # judgment call about whether the mutation was actually run.
  SABOTAGE_NOTE_RE = /#\s*sabotage:/.freeze
  TEST_LINE_RE = /\btest\s+"/.freeze

  # Defense in depth: the pathspec on SABOTAGE_DIFF_ARGS already keeps these
  # out of the diff at the git level. Filtering them again here means the
  # scan is still correct even if this method is ever handed diff text from
  # somewhere else.
  EXEMPT_TEST_DIR_PREFIXES = ["test/scion_tests/", "test/scxml_tests/"].freeze

  class << self
    def parse_status_porcelain(out)
      out.to_s.each_line.map do |line|
        line = line.chomp
        next nil if line.empty?

        path = line[3..-1].to_s
        path.include?(" -> ") ? path.split(" -> ").last : path
      end.compact
    end

    # The carve-out predicate, computed identically to repo_state.rb's
    # `touches_elixir` (see lib/touches_elixir.rb) so /commit's Step 0 and
    # this script cannot drift apart the way the `^Refs:` extraction once
    # did.
    def touches_elixir?(env)
      diff_res = Sh.run(%w[git diff --name-only main...HEAD], envelope: env)
      diff_files =
        if diff_res.success?
          diff_res.out.to_s.each_line.map(&:strip).reject(&:empty?)
        else
          env.warn(code: "no_main_ref", message: "could not diff against local main ref")
          []
        end

      status_res = Sh.run(%w[git status --porcelain], envelope: env)
      dirty_files = parse_status_porcelain(status_res.out)

      TouchesElixir.any?((diff_files + dirty_files).uniq)
    end

    # Parses a -U0 unified diff for added `test "..."` lines with no
    # `# sabotage:` note on the line immediately above them within the same
    # hunk. Report-only - see the module doc.
    def scan_sabotage(diff_text)
      missing = []
      current_file = nil
      prev_added = nil

      diff_text.to_s.each_line do |raw|
        line = raw.chomp

        if line.start_with?("+++ ")
          current_file = line.sub(%r{\A\+\+\+ (b/)?}, "")
          prev_added = nil
          next
        end

        if line.start_with?("@@")
          prev_added = nil
          next
        end

        next unless line.start_with?("+")

        content = line[1..-1].to_s
        exempt = EXEMPT_TEST_DIR_PREFIXES.any? { |prefix| current_file.to_s.start_with?(prefix) }

        if !exempt && content =~ TEST_LINE_RE && !(prev_added && prev_added =~ SABOTAGE_NOTE_RE)
          missing << { file: current_file, text: content.strip }
        end

        prev_added = content
      end

      missing
    end

    def sabotage_missing(env)
      diff_res = Sh.run(SABOTAGE_DIFF_ARGS, envelope: env)
      return [] unless diff_res.success?

      scan_sabotage(diff_res.out)
    end

    def skipped_from(stages)
      Array(stages)
        .select { |s| s["status"] == "skipped" }
        .map { |s| { name: s["name"], summary: s["summary"] } }
    end

    # `data.gate_guard` is a report, never repaired: the ledger existence
    # check below is read-only (File.exist?), and the guarded-path findings
    # (if any) come straight from the "Gate guard" stage `mix quality`
    # itself already ran - this method adds no write path of its own. See
    # test/contract_test.rb, which asserts that mechanically.
    def gate_guard_from(stages)
      stage = Array(stages).find { |s| s["name"] == "Gate guard" }

      {
        ledger_path: LEDGER_PATH,
        ledger_exists: File.exist?(LEDGER_PATH),
        stage: stage && { status: stage["status"], summary: stage["summary"], findings: stage["findings"] }
      }
    end

    def run_quality(env, extra_args)
      res = Sh.run(["mix", "quality", "--report", "-"] + extra_args, envelope: env, timeout: 600)
      report = begin
        JSON.parse(res.out)
      rescue JSON::ParserError
        nil
      end
      [res, report]
    end

    def build_parser(options)
      Cli.build("gate.rb [--profile loop]", options) do |opts|
        opts.separator ""
        opts.separator "Wraps mix gate.verify and mix quality --format json --report -."
        opts.separator "The only --profile value accepted is 'loop' (inner-loop iteration; sets"
        opts.separator "data.attested to false so the caller cannot mistake it for a full green)."
        opts.separator "No --skip, no --quick, and no other --profile value is defined by this"
        opts.separator "parser, so OptionParser rejects them as a usage error (exit 2) - there is"
        opts.separator "no way to narrow what mix quality runs beyond the one --profile loop case."
        opts.separator ""
        opts.separator "data.sabotage.missing is a report, not a gate: it never blocks and never"
        opts.separator "flips ok. A present '# sabotage:' note is not evidence the mutation was"
        opts.separator "actually run against broken code - see docs/testing.md."
        opts.on("--profile PROFILE", "only 'loop' is accepted") do |v|
          raise OptionParser::InvalidArgument, "profile must be 'loop' (got #{v.inspect})" if v != "loop"

          options[:profile] = v
        end
      end
    end

    def run(argv, io: $stdout)
      options = {}
      parser, options = build_parser(options)
      Cli.parse!(parser, argv)

      env = Envelope.new(script: "gate")
      loop_mode = options[:profile] == "loop"

      applicable = touches_elixir?(env)

      missing = sabotage_missing(env)
      env.data[:sabotage] = { missing: missing }
      missing.each do |m|
        env.warn(
          code: "sabotage_note_missing",
          message: "#{m[:file]}: #{m[:text]} has no `# sabotage:` note directly above it " \
                    "(a present note is not evidence the mutation was run)"
        )
      end

      env.data[:applicable] = applicable
      env.data[:carve_out_reason] =
        applicable ? nil : (
          "no changes under lib/, test/, config/, mix.exs, or mix.lock - nothing for the quality gate to measure"
        )

      # The carve-out ("skip mix quality and review the diff instead") is a
      # pre-commit decision about the full gate - see /commit's Step 0. It
      # does not apply to --profile loop: that flag is a deliberate ask for
      # inner-loop feedback, not a request to decide whether a commit needs
      # the gate, so it always runs and always reports attested: false.
      if !applicable && !loop_mode
        env.data[:ran] = nil
        env.data[:attested] = nil
        env.data[:attestation_message] = nil
        env.data[:status] = nil
        env.data[:scope] = nil
        env.data[:profile] = nil
        env.data[:stages] = []
        env.data[:skipped_stages] = []
        env.data[:gate_guard] = { ledger_path: LEDGER_PATH, ledger_exists: File.exist?(LEDGER_PATH), stage: nil }
        return env.emit(io)
      end

      quality_args = loop_mode ? ["--profile", "loop"] : []
      _res, report = run_quality(env, quality_args)
      report ||= {}
      stages = report["stages"] || []
      skipped = skipped_from(stages)

      env.data[:ran] = loop_mode ? "loop" : "all"
      env.data[:status] = report["status"]
      env.data[:scope] = report["scope"]
      env.data[:profile] = report["profile"]
      env.data[:stages] = stages
      env.data[:skipped_stages] = skipped
      env.data[:gate_guard] = gate_guard_from(stages)

      if loop_mode
        env.data[:attested] = false
        env.data[:attestation_message] = nil
      else
        verify_res = Sh.run(%w[mix gate.verify], envelope: env, timeout: 600)
        env.data[:attested] = verify_res.success?
        env.data[:attestation_message] =
          (verify_res.success? || verify_res.err.to_s.strip.empty? ? verify_res.out : verify_res.err).to_s.strip
      end

      env.fail! if report["status"] && report["status"] != "ok"

      skipped.each do |s|
        env.block!(
          code: "stage_skipped",
          message: "#{s[:name]} was skipped (#{s[:summary]}) - a skipped stage is not a passing one"
        )
      end

      env.emit(io)
    end
  end
end

exit Gate.run(ARGV) if __FILE__ == $PROGRAM_NAME
