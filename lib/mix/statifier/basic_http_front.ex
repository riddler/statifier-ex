defmodule Mix.Statifier.BasicHTTPFront do
  @moduledoc """
  The loopback inbound front this repository's own runs deliver Basic HTTP
  sends through (ADR-0075), on OTP's `:inets` httpd, with no dependency. It
  is repository tooling, not part of the package.

  `start/0` binds a free port on 127.0.0.1 and answers the base URL a
  `Statifier.Send.BasicHTTP` registration takes as its `:base_url`, so a
  session's `_ioprocessors` location is `base_url <> "/" <> session_id`.
  A request to that location is resolved to the live session registered
  under the id in `Statifier.Registry`, decoded by
  `Statifier.Send.BasicHTTP.decode/1`, and enqueued on the session as an
  external event, with the request's `scxml-send-key` header handed to the
  decoder. This front does not deduplicate on that header (ADR-0075's
  Amendment of 2026-09-30 leaves that to a front that outlives a restart).
  The status rule is the decoder's (ADR-0075 decision 5):

    - 204 once the event is enqueued, before it is processed;
    - 405 with `Allow: POST` for any other method;
    - 400 for a request that forms no event;
    - 404 for a path that names no live session.
  """

  alias Statifier.Send.BasicHTTP
  alias Statifier.Session

  require Record

  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  # `:inets` is not an application this package lists (ADR-0075 decision 6),
  # so dialyzer's PLT does not see httpd; the calls into it are kept to the
  # two functions named here.
  @dialyzer {:nowarn_function, start: 0, stop: 1}

  @prefix "/basichttp"

  @typedoc "A running front: the httpd process and the base URL it answers at."
  @type t :: %{pid: pid(), base_url: String.t()}

  @doc """
  Starts a front on a free loopback port. Starts `:inets` first.
  """
  @spec start() :: {:ok, t()} | {:error, term()}
  def start do
    root = String.to_charlist(System.tmp_dir!())

    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, pid} <-
           :inets.start(:httpd,
             port: 0,
             bind_address: {127, 0, 0, 1},
             server_name: ~c"statifier-basichttp",
             server_root: root,
             document_root: root,
             modules: [__MODULE__]
           ) do
      [port: port] = :httpd.info(pid, [:port])
      {:ok, %{pid: pid, base_url: "http://127.0.0.1:#{port}#{@prefix}"}}
    end
  end

  @doc "Stops a front `start/0` started."
  @spec stop(front :: t()) :: :ok | {:error, term()}
  def stop(%{pid: pid}), do: :inets.stop(:httpd, pid)

  @doc """
  The httpd callback, `do/1` (a name only `unquote/1` can define):
  answers one request by the status rule in the moduledoc, through
  `respond/1`.
  """
  @spec unquote(:do)(mod_data :: tuple()) :: {:proceed, list()}
  defdelegate unquote(:do)(mod_data), to: __MODULE__, as: :respond

  @doc "Answers one httpd request by the status rule in the moduledoc."
  @spec respond(mod_data :: tuple()) :: {:proceed, list()}
  def respond(mod_data) do
    %URI{path: path, query: query} = mod_data |> mod(:request_uri) |> to_string() |> URI.parse()

    headers = mod(mod_data, :parsed_header)

    request = %{
      method: mod_data |> mod(:method) |> to_string(),
      content_type: header(headers, ~c"content-type"),
      send_key: header(headers, ~c"scxml-send-key"),
      body: mod_data |> mod(:entity_body) |> IO.iodata_to_binary(),
      query: query
    }

    {:proceed, [{:response, {:response, head(answer(path, request)), []}}]}
  end

  @spec answer(path :: String.t() | nil, request :: BasicHTTP.request()) ::
          204 | 400 | 404 | 405
  defp answer(@prefix <> "/" <> session_id, request) do
    with {:ok, pid} <- whereis(session_id),
         {:ok, event} <- BasicHTTP.decode(request) do
      :ok = Session.send_event(pid, event)
      204
    else
      :no_session -> 404
      {:error, {:method_not_allowed, _method}} -> 405
      {:error, _reason} -> 400
    end
  end

  defp answer(_path, _request), do: 404

  @spec head(status :: 204 | 400 | 404 | 405) :: keyword()
  defp head(405), do: [code: 405, allow: ~c"POST", content_length: ~c"0"]
  defp head(status), do: [code: status, content_length: ~c"0"]

  @spec whereis(session_id :: String.t()) :: {:ok, pid()} | :no_session
  defp whereis(session_id) do
    case Registry.lookup(Statifier.Registry, session_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :no_session
    end
  end

  @spec header(headers :: [{charlist(), charlist()}], name :: charlist()) :: String.t() | nil
  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_name, value} -> to_string(value)
      nil -> nil
    end
  end
end
