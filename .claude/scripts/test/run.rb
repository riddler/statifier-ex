#!/usr/bin/env ruby
# frozen_string_literal: true

# The whole test harness for .claude/scripts/. Stdlib only - minitest ships
# with Ruby 2.6, no gem install required. Run:
#
#   ruby .claude/scripts/test/run.rb
#   ruby .claude/scripts/test/run.rb -n /pattern/
#
# mix quality does NOT run this suite (see README.md: adding a stage would
# edit .quality.exs and needs an ADR-0011 ledger entry, which is a human's
# call). A phase touching .claude/scripts/ must run both this and
# mix quality separately.

require "minitest/autorun"

here = File.expand_path(__dir__)
Dir.glob(File.join(here, "**", "*_test.rb")).sort.each { |f| require f }
