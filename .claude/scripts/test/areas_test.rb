# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/areas"

class AreasTest < Minitest::Test
  def test_valid_is_the_closed_vocabulary_from_workflow_md
    assert_equal(
      %w[area:interpreter area:parser area:datamodel area:corpus area:test-harness area:skills area:docs area:build],
      Areas::VALID
    )
  end

  def test_areas_of_keeps_only_recognized_area_labels_in_order
    labels = ["area:interpreter", "priority:1", "area:docs", "unrelated"]
    assert_equal ["area:interpreter", "area:docs"], Areas.areas_of(labels)
  end

  def test_areas_of_never_infers_from_anything_but_labels
    # No file-path argument exists anywhere on this API - the only input is
    # the label list already on the bead (docs/workflow.md:147-191).
    assert_equal [], Areas.areas_of([])
    assert_equal [], Areas.areas_of(nil)
  end

  def test_upstream_bead_carries_no_area_label
    assert Areas.upstream?(["upstream"])
    refute Areas.upstream?(["area:corpus"])
  end

  def test_area_build_lands_alone
    assert Areas.lands_alone?(["area:build"])
    refute Areas.lands_alone?(["area:interpreter"])
  end

  def test_disjoint_is_plain_set_intersection
    assert Areas.disjoint?(["area:interpreter"], ["area:parser"])
    refute Areas.disjoint?(["area:interpreter", "area:docs"], ["area:docs"])
    assert Areas.disjoint?([], ["area:corpus"])
  end
end
