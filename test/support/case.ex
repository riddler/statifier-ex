defmodule Statifier.Case do
  @moduledoc """
  Compatibility shim: the real case template is `Statifier.Testing.Case`, in
  `lib/`. This name is kept so the 281 generated corpus files need no
  regeneration (ADR-0053 decision 5).
  """

  @doc false
  @spec __using__(opts :: keyword()) :: Macro.t()
  defmacro __using__(opts) do
    quote do
      use Statifier.Testing.Case, unquote(opts)
    end
  end
end
