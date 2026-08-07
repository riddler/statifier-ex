defmodule Statifier.Parser.ParseError do
  @moduledoc """
  The parser's own error shape: never `%Saxy.ParseError{}` directly, so
  callers get one error type regardless of what failed inside.

  `reason` carries Saxy's own reason term unchanged (`{:token, _}`,
  `{:wrong_closing_tag, _, _}`, `{:invalid_pi, _}`, `{:invalid_encoding, _}`,
  `{:bad_return, _}`) plus the v2-only `{:location_desync, expected, got}`,
  raised when the markup scanner's queue and the Saxy event stream disagree
  about which element comes next (see `Statifier.Parser.Markup`). `location`
  is a zero-width `Statifier.Parser.Location.t()` at the failing byte offset -
  the same span type every DOM node uses, so callers have one shape to
  handle - and is `nil` exactly when Saxy reports no `position` (observed
  upstream on at least one `:bad_return` case), which `byte_offset` mirrors.
  """

  alias Statifier.Parser.Location

  @type reason ::
          Saxy.ParseError.reason()
          | {:location_desync, expected :: binary(), got :: binary()}

  @enforce_keys [:reason, :message]
  defexception [:reason, :message, :location, :byte_offset]

  @type t :: %__MODULE__{
          reason: reason(),
          message: binary(),
          location: Location.t() | nil,
          byte_offset: non_neg_integer() | nil
        }

  @doc """
  Converts a `%Saxy.ParseError{}` raised against `source` into `t()`.

  Tolerates a `nil` position (Saxy's own `:bad_return` reason can arrive with
  `binary: nil, position: nil`): `location` and `byte_offset` are `nil` in
  that case rather than raising on the offset conversion.
  """
  @spec from_saxy(error :: Saxy.ParseError.t(), source :: binary()) :: t()
  def from_saxy(%Saxy.ParseError{position: nil} = error, source) when is_binary(source) do
    %__MODULE__{
      reason: error.reason,
      message: Exception.message(error),
      location: nil,
      byte_offset: nil
    }
  end

  def from_saxy(%Saxy.ParseError{position: position} = error, source)
      when is_binary(source) and is_integer(position) do
    %__MODULE__{
      reason: error.reason,
      message: Exception.message(error),
      location: Location.at_offset(source, position),
      byte_offset: position
    }
  end

  @doc """
  Builds the `{:location_desync, expected, got}` error the handler raises
  when the popped markup record's name does not match the Saxy event's name
  at `location` - the guard that turns a mismatched two-pass zip into a
  reported error instead of a silently wrong location.
  """
  @spec desync(expected :: binary(), got :: binary(), location :: Location.t()) :: t()
  def desync(expected, got, %Location{} = location) do
    %__MODULE__{
      reason: {:location_desync, expected, got},
      message: "location desync: expected element #{inspect(expected)}, got #{inspect(got)}",
      location: location,
      byte_offset: location.start_offset
    }
  end
end
