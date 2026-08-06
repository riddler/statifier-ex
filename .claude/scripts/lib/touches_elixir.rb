# frozen_string_literal: true

# The carve-out predicate stated identically in /commit's Step 0 (L97-98)
# and /merge-request's gate step (L130-131): a change touching none of
# these paths has no Elixir build to break, so mix quality has nothing to
# measure - skills, docs, ADRs, and beads exports cannot break a build.
#
# repo_state.rb reports the result under `touches_elixir`. A later phase's
# gate.rb wrapper reuses this same predicate so the two skills' carve-outs
# cannot drift apart the way the `^Refs:` extraction (see lib/refs.rb) once
# did.
module TouchesElixir
  PATTERNS = [
    %r{\Alib/},
    %r{\Atest/},
    %r{\Aconfig/},
    /\Amix\.exs\z/,
    /\Amix\.lock\z/
  ].freeze

  class << self
    def any?(paths)
      Array(paths).any? { |path| PATTERNS.any? { |pattern| path =~ pattern } }
    end
  end
end
