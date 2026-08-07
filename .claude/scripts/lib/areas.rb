# frozen_string_literal: true

# Areas is the closed `area:` vocabulary from docs/workflow.md:147-191 -
# the label set, the `area:build`-lands-alone rule, and the `upstream`
# escape hatch. It holds no inference from file paths: an area label is a
# prediction written before the work exists, so deriving one from a diff
# would invert the design (docs/plans/260806-st-hzf-skill-mechanics-scripts.md
# Phase 6). select_batch.rb is the only caller.
module Areas
  # The closed vocabulary. A label outside this list is not an area this
  # module recognizes - callers treat an unrecognized `area:*` label the
  # same as no area label at all (see docs/workflow.md's table).
  VALID = %w[
    area:interpreter
    area:parser
    area:datamodel
    area:corpus
    area:test-harness
    area:skills
    area:docs
    area:build
  ].freeze

  # `area:build` moves mix.lock and the credo config every other worktree's
  # warmed build depends on, so a bead carrying it batches with nothing
  # else and lands on main alone (docs/workflow.md).
  LANDS_ALONE = "area:build"

  # The one class of bead with no area label: work that changes no files in
  # this repo (docs/workflow.md). Always batchable - it collides with
  # nothing here by definition.
  UPSTREAM_LABEL = "upstream"

  class << self
    # The subset of `labels` that are recognized area: labels, in the order
    # they appear. No path inference, ever - this is a filter over labels
    # already on the bead.
    def areas_of(labels)
      Array(labels).select { |l| VALID.include?(l) }
    end

    def upstream?(labels)
      Array(labels).include?(UPSTREAM_LABEL)
    end

    def lands_alone?(labels)
      Array(labels).include?(LANDS_ALONE)
    end

    # Two beads are batchable iff their area sets are disjoint - the whole
    # rule (docs/workflow.md). Plain set intersection; there is no bespoke
    # compatibility table because the area globs themselves are already
    # disjoint by construction.
    def disjoint?(areas_a, areas_b)
      (Array(areas_a) & Array(areas_b)).empty?
    end
  end
end
