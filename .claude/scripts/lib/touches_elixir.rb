# frozen_string_literal: true

# Two related predicates that are deliberately *not* the same question.
#
# `any?` - does this change touch the Elixir build? A change touching none
# of PATTERNS has no Elixir build to break: skills, docs, ADRs, and beads
# exports cannot break a compile. repo_state.rb reports this under
# `touches_elixir`.
#
# `gate_applicable?` - does `mix quality` have anything to measure? This is
# the carve-out predicate stated in /commit's Step 0 and /merge-request's
# gate step, and it is strictly wider than `any?`, because the gate covers
# more than the Elixir build. The `Script tests` stage (.quality.exs, ledger
# entry st-hzf) runs the Ruby suite under `.claude/scripts/`, so a branch
# touching only those files does have a gate to run.
#
# The two were one predicate until st-hzf added that stage. Conflating them
# is what let this branch - ~8k lines of new Ruby, no Elixir - report "no
# gate applicable" and skip the only check that covered it. Keep them
# separate: `any?` answers a question about the build, `gate_applicable?`
# answers a question about the gate, and the gate is free to grow stages
# that have nothing to do with Elixir.
#
# gate.rb reuses `gate_applicable?` so the skills' carve-outs cannot drift
# apart the way the `^Refs:` extraction (see lib/refs.rb) once did.
module TouchesElixir
  PATTERNS = [
    %r{\Alib/},
    %r{\Atest/},
    %r{\Aconfig/},
    /\Amix\.exs\z/,
    /\Amix\.lock\z/
  ].freeze

  # Paths that no longer carve out, even though they touch no Elixir,
  # because a gate stage now measures them.
  GATED_NON_ELIXIR_PATTERNS = [
    %r{\A\.claude/scripts/}
  ].freeze

  GATE_PATTERNS = (PATTERNS + GATED_NON_ELIXIR_PATTERNS).freeze

  class << self
    def any?(paths)
      match?(paths, PATTERNS)
    end

    def gate_applicable?(paths)
      match?(paths, GATE_PATTERNS)
    end

    private

    def match?(paths, patterns)
      Array(paths).any? { |path| patterns.any? { |pattern| path =~ pattern } }
    end
  end
end
