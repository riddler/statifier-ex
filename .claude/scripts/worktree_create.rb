#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/sh"
require_relative "lib/cli"

# WorktreeCreate replaces /new-worktree Steps 1-4 (Guard, create the worktree
# and branch, trust it with mise, warm the build caches, verify green) - see
# docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 4. Step 5 (the
# tmux window) is a separate script (Phase 5), invoked by the SKILL.md only
# after this script reports success.
#
# Never force: a pre-existing branch or worktree directory is `blocked` with
# needs: "human" - see new-worktree/SKILL.md Step 1. This script has no path
# that deletes a branch or a directory to make room for a new one.
module WorktreeCreate
  WORKTREES_DIR_NAME = "statifier-ex-worktrees"
  PLT_GLOB = "dialyxir_erlang-*_elixir-*_deps-dev.plt*"

  class << self
    def run(argv, io: $stdout)
      parser, options = Cli.build("worktree_create.rb [options] <name>")
      args = Cli.parse!(parser, argv)
      name = args.first
      usage_error!("worktree_create.rb [options] <name>", parser) if name.to_s.strip.empty?

      env = Envelope.new(script: "worktree_create")
      dry_run = options[:dry_run]

      root = main_checkout_root(env)
      unless root
        env.block!(code: "not_main_checkout", message: "worktree_create.rb must be run from the main checkout, not a worktree")
        return env.emit(io)
      end

      worktrees_root = File.expand_path(WORKTREES_DIR_NAME, File.dirname(root))
      path = File.join(worktrees_root, name)

      # --- Guard ----------------------------------------------------------

      branch_res = Sh.run(["git", "branch", "--list", name], chdir: root, envelope: env)
      if branch_res.success? && !branch_res.out.to_s.strip.empty?
        env.block!(code: "branch_exists", message: "branch #{name} already exists", needs: "human")
        return env.emit(io)
      end

      if Dir.exist?(path)
        env.block!(code: "worktree_dir_exists", message: "#{path} already exists", needs: "human")
        return env.emit(io)
      end

      base_ref = "origin/main"
      fetch_res = Sh.run(%w[git fetch origin], chdir: root, envelope: env)
      unless fetch_res.success?
        base_ref = "main"
        env.warn(
          code: "fetch_failed",
          message: "git fetch origin failed (offline?); cutting #{name} from local main instead of origin/main"
        )
      end

      env.data[:name] = name
      env.data[:path] = path
      env.data[:base_ref] = base_ref
      env.data[:dry_run] = dry_run

      if dry_run
        record_dry_run_steps(env, root: root, path: path, worktrees_root: worktrees_root, base_ref: base_ref, name: name)
        return env.emit(io)
      end

      create_and_warm(env, io, root: root, path: path, worktrees_root: worktrees_root, base_ref: base_ref, name: name)
    end

    private

    # A pre-existing branch or directory is blocked before this ever runs, so
    # the guard checks above always execute for real (they are reads, not
    # mutations, and dry-run reporting an accurate guard result is more
    # useful than a guess). Only what follows here - the worktree add, the
    # mise trust, the cache warm, and the verify - is mutating, and that is
    # what --dry-run records without executing.
    def record_dry_run_steps(env, root:, path:, worktrees_root:, base_ref:, name:)
      env.commands << Sh.render(["mkdir", "-p", worktrees_root])
      env.commands << Sh.render(["git", "worktree", "add", path, "-b", name, "--no-track", base_ref], chdir: root)
      env.commands << Sh.render(["mise", "trust", path])
      env.commands << Sh.render(["cp", "-Rfc", "deps", "_build", "#{path}/"], chdir: root)
      env.commands << "(fallback if -c is unsupported) " +
                       Sh.render(["cp", "-Rf", "deps", "_build", "#{path}/"], chdir: root)
      env.commands << Sh.render(%w[mix deps.get], chdir: path)
      env.commands << Sh.render(%w[mix quality --profile loop], chdir: path)
    end

    def create_and_warm(env, io, root:, path:, worktrees_root:, base_ref:, name:)
      mkdir_res = Sh.run(["mkdir", "-p", worktrees_root], envelope: env)
      unless mkdir_res.success?
        env.block!(code: "mkdir_failed", message: err_or(mkdir_res, "mkdir -p #{worktrees_root} failed"))
        return env.emit(io)
      end

      add_res = Sh.run(["git", "worktree", "add", path, "-b", name, "--no-track", base_ref], chdir: root, envelope: env)
      unless add_res.success?
        env.block!(code: "worktree_add_failed", message: err_or(add_res, "git worktree add failed"))
        return env.emit(io)
      end

      # mise trusts mise.toml per directory path, not per repo, so the freshly
      # created worktree path is untrusted even though it's the same repo
      # content - without this, the first mise-managed command run there
      # (mix deps.get, below) prompts to trust the config and hangs a
      # non-interactive session the same way an unaliased -i flag does.
      trust_res = Sh.run(["mise", "trust", path], envelope: env)
      env.warn(code: "mise_trust_failed", message: err_or(trust_res, "mise trust #{path} failed")) unless trust_res.success?

      warm(env, root: root, path: path)

      deps_res = Sh.run(%w[mix deps.get], chdir: path, envelope: env)
      env.warn(code: "deps_get_failed", message: err_or(deps_res, "mix deps.get failed")) unless deps_res.success?

      quality_res = Sh.run(%w[mix quality --profile loop], chdir: path, envelope: env)
      env.data[:quality_green] = quality_res.success?
      env.data[:quality_output] = quality_res.out.to_s unless quality_res.success?
      env.fail! unless quality_res.success?

      env.emit(io)
    end

    # On APFS, cp -c uses copy-on-write clonefiles, so this is nearly instant
    # and costs almost no disk; not every filesystem supports -c, so a plain
    # recursive copy is the fallback.
    def warm(env, root:, path:)
      cp_res = Sh.run(["cp", "-Rfc", "deps", "_build", "#{path}/"], chdir: root, envelope: env)
      cp_res = Sh.run(["cp", "-Rf", "deps", "_build", "#{path}/"], chdir: root, envelope: env) unless cp_res.success?

      env.data[:caches_cloned] = cp_res.success?
      env.warn(code: "cache_clone_failed", message: err_or(cp_res, "could not clone deps/_build into #{path}")) unless cp_res.success?

      plt_matches = Dir.glob(File.join(root, "_build", "dev", PLT_GLOB))
      env.data[:plt_present] = !plt_matches.empty?
      unless plt_matches.empty?
        return
      end

      env.warn(
        code: "plt_missing",
        message: "no dialyzer PLT found in #{root}/_build/dev; the first full `mix quality` in the worktree will build one"
      )
    end

    def main_checkout_root(env)
      git_dir = Sh.run(%w[git rev-parse --git-dir], envelope: env)
      common_dir = Sh.run(%w[git rev-parse --git-common-dir], envelope: env)
      toplevel = Sh.run(%w[git rev-parse --show-toplevel], envelope: env)
      return nil unless git_dir.success? && common_dir.success? && toplevel.success?

      is_main = File.expand_path(git_dir.out.to_s.strip) == File.expand_path(common_dir.out.to_s.strip)
      return nil unless is_main

      toplevel.out.to_s.strip
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

exit WorktreeCreate.run(ARGV) if __FILE__ == $PROGRAM_NAME
