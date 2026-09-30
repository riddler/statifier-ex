defmodule Statifier.Send.BasicHTTP.Transport do
  @moduledoc """
  How `Statifier.Send.BasicHTTP` POSTs a message (ADR-0075 decision 6): one
  callback that sends a body with headers to a URL and answers the status
  code, or an error when no status came back.

  The default is `Statifier.Send.BasicHTTP.Transport.Httpc`, on OTP's
  `:httpc`, which this package always compiles and adds no dependency for.
  A host injects any other module through the registration's `:transport`
  option. An adapter makes one attempt: retrying is not the transport's
  job, and a status outside 2xx is answered as `{:ok, status}`, not as an
  error, so the processor reports it as a miss.

  A host that uses `req` writes an adapter of its own:

      defmodule MyApp.ReqTransport do
        @behaviour Statifier.Send.BasicHTTP.Transport

        @impl true
        def post(url, headers, body) do
          case Req.post(url, headers: headers, body: body, retry: false) do
            {:ok, %Req.Response{status: status}} -> {:ok, status}
            {:error, exception} -> {:error, exception}
          end
        end
      end
  """

  @doc """
  POSTs `body` with `headers` (lower-case names, `content-type` among
  them) to `url`, once. Answers `{:ok, status}` for any HTTP status, or
  `{:error, reason}` when the request got no response.
  """
  @callback post(url :: String.t(), headers :: [{String.t(), String.t()}], body :: binary()) ::
              {:ok, 100..599} | {:error, term()}
end
