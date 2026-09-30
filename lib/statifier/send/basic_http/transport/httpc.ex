defmodule Statifier.Send.BasicHTTP.Transport.Httpc do
  @moduledoc """
  The default `Statifier.Send.BasicHTTP.Transport`, on OTP's `:httpc`
  (ADR-0075 decision 6). No dependency: `:inets`, `:ssl` and `:public_key`
  ship with OTP.

  This package's application list names none of them, so a host that
  registers nothing starts nothing. The adapter starts `:inets` and `:ssl`
  itself on its first POST.

  For an `https` URL it verifies the peer (`verify: :verify_peer`) against
  the system CA store (`:public_key.cacerts_get/0`) and checks the host
  name. Each request is bounded by a five-second connect timeout and a
  five-second request timeout, so a slow location holds the sending
  session no longer than that.
  """

  @behaviour Statifier.Send.BasicHTTP.Transport

  # `:inets`, `:ssl` and `:public_key` are applications this package does
  # not list (ADR-0075 decision 6: a host that registers nothing starts
  # nothing), so neither the compiler nor dialyzer's PLT sees their
  # modules. The calls into them are resolved at run time, after
  # `ensure_started/0` has started `:inets` and `:ssl`, and they are kept
  # to the two functions named here so no other function's warnings are
  # silenced.
  @compile {:no_warn_undefined, [:public_key]}
  @dialyzer {:nowarn_function, request: 2, ssl: 1}

  @timeout_ms 5_000

  @doc """
  POSTs `body` with `headers` to `url` through `:httpc`, once (see
  `c:Statifier.Send.BasicHTTP.Transport.post/3`).
  """
  @impl Statifier.Send.BasicHTTP.Transport
  @spec post(url :: String.t(), headers :: [{String.t(), String.t()}], body :: binary()) ::
          {:ok, 100..599} | {:error, term()}
  def post(url, headers, body) do
    with :ok <- ensure_started() do
      {content_type, rest} = content_type(headers)

      request =
        {String.to_charlist(url), Enum.map(rest, &charlist_header/1),
         String.to_charlist(content_type), body}

      http_options = [timeout: @timeout_ms, connect_timeout: @timeout_ms] ++ ssl(url)

      request(request, http_options)
    end
  end

  @spec request(request :: tuple(), http_options :: keyword()) ::
          {:ok, 100..599} | {:error, term()}
  defp request(request, http_options) do
    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_started() :: :ok | {:error, term()}
  defp ensure_started do
    with {:ok, _inets} <- Application.ensure_all_started(:inets),
         {:ok, _ssl} <- Application.ensure_all_started(:ssl),
         do: :ok
  end

  @spec content_type(headers :: [{String.t(), String.t()}]) ::
          {String.t(), [{String.t(), String.t()}]}
  defp content_type(headers) do
    case List.keytake(headers, "content-type", 0) do
      {{_name, content_type}, rest} -> {content_type, rest}
      nil -> {"application/octet-stream", headers}
    end
  end

  @spec charlist_header(header :: {String.t(), String.t()}) :: {charlist(), charlist()}
  defp charlist_header({name, value}), do: {String.to_charlist(name), String.to_charlist(value)}

  @spec ssl(url :: String.t()) :: keyword()
  defp ssl("https:" <> _rest) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp ssl(_url), do: []
end
