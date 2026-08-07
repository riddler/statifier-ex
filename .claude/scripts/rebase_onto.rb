#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"

# RebaseOnto is the shared rebase-with-repair block that /merge-request
# deferred to /refresh-worktree by prose cross-reference - defined once here
# so it cannot drift, and reused directly (as a library call, not shelled out
# to) by worktree_refresh.rb and, in a later phase, /merge-request's own
# script. See docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 4.
#
# A conflict is always blocked with needs: "human", the conflicting files
# named. There is no resolve path - CLAUDE.md's authority table is explicit
# that resolving a rebase conflict unasked is unauthorized, so this script
# does not offer one even as dead code.
#
# Assumes `origin/main` has already been fetched by the caller: a standalone
# run does no fetch of its own (see #run), and worktree_refresh.rb fetches
# once for the whole sweep rather than once per worktree.
module RebaseOnto
  PLT_GLOB = "dialyxir_erlang-*_elixir-*_deps-dev.plt*"

  class << self
    # Runs the block against the worktree at `path`, recording every command
    # into `env`. Returns a result hash:
    #   {status: "rebased", target: <sha>, lock_changed: bool, repaired: bool|nil}
    #   {status: "conflict", files: [...]}
    #   {status: "dry_run"} when dry_run: true - nothing was executed.
    def perform(path, env, dry_run: false)
      return dry_run_steps(path, env) if dry_run

      before_res = Sh.run(%w[git rev-parse HEAD], chdir: path, envelope: env)
      before = before_res.out.to_s.strip

      rebase_res = Sh.run(%w[git rebase origin/main], chdir: path, envelope: env)

      unless rebase_res.success?
        # Capture the conflicting files first, then abort - the abort clears
        # the conflict state, so a report assembled afterward has nothing
        # left to name if this order is reversed. This ordering is the whole
        # point of the extraction; see rebase_onto_test.rb.
        diff_res = Sh.run(%w[git diff --name-only --diff-filter=U], chdir: path, envelope: env)
        files = diff_res.out.to_s.each_line.map(&:strip).reject(&:empty?)
        Sh.run(%w[git rebase --abort], chdir: path, envelope: env)
        env.block!(code: "rebase_conflict", message: "conflict in #{files.join(', ')}", needs: "human")
        return { status: "conflict", files: files }
      end

      target_res = Sh.run(%w[git rev-parse origin/main], chdir: path, envelope: env)
      target = target_res.out.to_s.strip

      # git diff --quiet exits 0 when there is no difference (the fast path:
      # no deps.get, no PLT work) and non-zero when mix.lock moved.
      lock_res = Sh.run(["git", "diff", "--quiet", before, "HEAD", "--", "mix.lock"], chdir: path, envelope: env)
      lock_changed = !lock_res.success?

      repaired = nil
      if lock_changed
        deps_res = Sh.run(%w[mix deps.get], chdir: path, envelope: env)
        repaired = deps_res.success?
        copy_plt(path, env)
      end

      { status: "rebased", target: target, lock_changed: lock_changed, repaired: repaired }
    end

    def run(argv, io: $stdout)
      parser, options = Cli.build("rebase_onto.rb [options] <path>")
      args = Cli.parse!(parser, argv)
      path = args.first
      usage_error!("rebase_onto.rb [options] <path>", parser) if path.to_s.strip.empty?

      env = Envelope.new(script: "rebase_onto")
      result = perform(path, env, dry_run: options[:dry_run])

      env.data[:path] = path
      result.each { |k, v| env.data[k.to_s] = v }

      env.emit(io)
    end

    private

    def dry_run_steps(path, env)
      env.commands << Sh.render(%w[git rev-parse HEAD], chdir: path)
      env.commands << Sh.render(%w[git rebase origin/main], chdir: path)
      env.commands << "(on conflict) " + Sh.render(%w[git diff --name-only --diff-filter=U], chdir: path)
      env.commands << "(on conflict) " + Sh.render(%w[git rebase --abort], chdir: path)
      env.commands << "(if mix.lock moved) " + Sh.render(%w[mix deps.get], chdir: path)
      { status: "dry_run" }
    end

    # Targeted PLT copy, never a wholesale re-clone of deps/ or _build/ - that
    # would clobber a worktree's own incremental build state and force a full
    # recompile. Best-effort: a missing or stale PLT is a warning, never a
    # block, because the next full `mix quality` in the worktree rebuilds it.
    def copy_plt(path, env)
      main = main_checkout_for(path, env)
      unless main
        env.warn(code: "plt_source_unknown", message: "could not determine the main checkout to copy the PLT from")
        return
      end

      matches = Dir.glob(File.join(main, "_build", "dev", PLT_GLOB))
      if matches.empty?
        env.warn(
          code: "plt_missing",
          message: "no PLT found in #{main}/_build/dev to copy; the next full gate run in #{path} will rebuild it"
        )
        return
      end

      dest_dir = File.join(path, "_build", "dev")
      matches.each do |src|
        result = Sh.run(["cp", "-f", src, File.join(dest_dir, File.basename(src))], envelope: env)
        env.warn(code: "plt_copy_failed", message: "cp #{src} -> #{dest_dir} failed") unless result.success?
      end
    end

    def main_checkout_for(path, env)
      list_res = Sh.run(%w[git worktree list --porcelain], chdir: path, envelope: env)
      return nil unless list_res.success?

      # git-worktree(1): the main working tree is always listed first.
      first_line = list_res.out.to_s.each_line.first.to_s
      return nil unless first_line.start_with?("worktree ")

      first_line.sub("worktree ", "").strip
    end

    def usage_error!(usage_line, parser)
      warn "usage: #{usage_line}\n\n#{parser}"
      exit 2
    end
  end
end

exit RebaseOnto.run(ARGV) if __FILE__ == $PROGRAM_NAME
