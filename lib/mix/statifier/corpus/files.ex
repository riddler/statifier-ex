defmodule Mix.Statifier.Corpus.Files do
  @moduledoc """
  The corpus emitter's file reads and writes, in one place, each returning a
  sentence naming the file instead of raising.

  Mix task support, run under `mix` on a developer's machine against paths in
  this repository or its gitignored scratch tree: no path here is
  attacker-controlled, and nothing under `lib/mix/` is in the released package
  (`mix.exs`'s package files list). That is the justification for the
  `@sobelow_skip` on each function below; every other Sobelow check stays live
  on the module.
  """

  # `@sobelow_skip` is read out of this file's AST by Sobelow, never at
  # runtime, so the compiler would see an attribute that is set and never
  # used; registering it as persisted makes it a declaration rather than dead
  # code (the same mechanism as Mix.Statifier.Corpus.Exclusions).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc "Reads `path`, or returns a sentence naming it."
  @spec read(path :: Path.t()) :: {:ok, binary()} | {:error, String.t()}
  @sobelow_skip ["Traversal.FileModule"]
  def read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Writes `content` to `path`, creating its directory, or returns a sentence naming it."
  @spec write(path :: Path.t(), content :: iodata()) :: :ok | {:error, String.t()}
  @sobelow_skip ["Traversal.FileModule"]
  def write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} -> {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
