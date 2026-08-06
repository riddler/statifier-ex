# frozen_string_literal: true

# Refs is the single definition site for extracting bead ids from `Refs:`
# trailer lines in commit/PR messages. Before this extraction the same
# pattern was written twice, independently: `/merge-request` SKILL.md
# (over `git log origin/main..HEAD --pretty=%B`) and `/cleanup-worktrees`
# SKILL.md (over `gh pr view <n> --json commits --jq
# '.commits[].messageBody'`). A drift between the two would mean a PR body's
# `Closes` lines and the beads `/cleanup-worktrees` actually closes disagree
# - see docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 2.
#
# The anchor (`^Refs:`) is load-bearing, not tidiness: a commit body
# routinely names other beads in prose (citing a design note, crediting a
# discovery), and an unanchored match would close every one of them. See the
# 146c69f fixture in test/refs_test.rb for a real example.
module Refs
  # A bead id: "st-" followed by lowercase alphanumerics, optionally dotted
  # (e.g. "st-00p.3"). The single definition site - every other file that
  # needs this shape requires this constant rather than re-deriving it.
  BEAD_ID = /st-[a-z0-9]+(?:\.[0-9]+)?/.freeze

  class << self
    # Extracts bead ids from the `Refs:` trailer line(s) of one or more
    # messages. Each message is split into lines; only lines matching
    # /^Refs:/ are scanned for bead ids. A bead id named elsewhere in the
    # message (ordinary prose) is deliberately ignored. Returns a sorted,
    # deduplicated array of bead id strings.
    def beads_from_messages(texts)
      ids = []
      Array(texts).each do |text|
        next if text.nil?

        text.to_s.each_line do |line|
          next unless line =~ /\ARefs:/

          ids.concat(line.scan(BEAD_ID))
        end
      end
      ids.uniq.sort
    end

    # Builds a "Refs: id1 id2 ..." trailer line for message construction.
    def trailer_line(ids)
      "Refs: #{Array(ids).join(' ')}"
    end
  end
end
