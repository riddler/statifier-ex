defmodule Statifier.BasicHTTPTestTransport do
  @moduledoc """
  A test-only `Statifier.Send.BasicHTTP.Transport` that makes no request.
  It reports each POST to the process registered under this module's name,
  when there is one, as `{:basichttp_post, url, headers, body}`, and answers
  from the URL's path: `/answer/<status>` answers `{:ok, status}`,
  `/answer/error` answers `{:error, :econnrefused}`, `/answer/raise` raises
  a `RuntimeError` (after reporting the POST), and anything else
  `{:ok, 204}`.
  """

  @behaviour Statifier.Send.BasicHTTP.Transport

  @impl Statifier.Send.BasicHTTP.Transport
  @spec post(url :: String.t(), headers :: [{String.t(), String.t()}], body :: binary()) ::
          {:ok, 100..599} | {:error, term()}
  def post(url, headers, body) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {:basichttp_post, url, headers, body})
    end

    case URI.parse(url).path do
      "/answer/error" -> {:error, :econnrefused}
      "/answer/raise" -> raise "the test transport raised"
      "/answer/" <> status -> {:ok, String.to_integer(status)}
      _other -> {:ok, 204}
    end
  end
end
