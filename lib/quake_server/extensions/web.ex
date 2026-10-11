defmodule QuakeServer.Extensions.Web do
  @moduledoc """
  FTE's network builtins:

    * `uri_get` (513, also as `uri_post`) — an HTTP request: a GET, or with a MIME type a
      POST of the fourth argument (or of string buffer five's strings joined by the
      fourth). Returns 1 and runs the request apart; `run/1` hands each reply to the
      program's `URI_Get_Callback(id, code, data, length)` with `self` as it was, the
      code 0 for HTTP 200 and the status otherwise (0 when there was no reply). Returns
      0, printing why, while `pr_enable_uriget` is 0 or 32 requests are waiting.
    * `netaddress_resolve` (625) — an address as `a.b.c.d:port` (`[v6]:port` for IPv6,
      no port when it is 0), `QLoopBack:port` for `internalserver` or `QLoopBack`, the
      default port used when none is given; the empty string when it cannot be resolved
      or `net_enabled` is 0
    * `sendpacket` (242) — an out-of-band packet: the server holds no network sockets,
      so nothing is sent and it returns 0

  Replies wait in a table belonging to the host's process (`ext.uri_replies`).
  """

  alias QuakeC.Exec
  alias QuakeServer.{Args, Cvars, Events, Server}
  alias QuakeServer.Extensions.Store

  @limit 32
  @timeout 30_000

  @doc "Run network builtin `builtin`."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 513, argc) do
    url = Args.str(s, 0)
    id = Args.num(s, 1)

    cond do
      cvar_int(s, "pr_enable_uriget", 1) == 0 ->
        s |> Events.print(:notify, "pr_enable_uriget: blocking \"#{url}\"\n") |> Args.return(0.0)

      pending(s) > @limit ->
        s
        |> Events.print(
          :notify,
          "PF_uri_get(\"#{url}\",#{format(id)}): too many pending downloads\n"
        )
        |> Args.return(0.0)

      true ->
        {s, table} = table(s)
        request = request(s, url, argc)
        self = trunc(QuakeC.float(QuakeC.global(s.qc, "self")))
        key = make_ref()
        :ets.insert(table, {key, :waiting, id, self})
        spawn(fn -> fetch(table, key, request) end)
        Args.return(s, 1.0)
    end
  end

  def call(s, 625, argc) do
    port = if argc > 1, do: trunc(Args.num(s, 1)), else: 0
    Args.return(s, resolve(s, Args.str(s, 0), port))
  end

  def call(s, 242, _argc), do: Args.return(s, 0.0)

  def call(s, "uri_post", argc), do: call(s, 513, argc)

  @doc "Hand every reply that has come since the last call to the program's `URI_Get_Callback`, in the order they came."
  @spec run(map()) :: map()
  def run(%{ext: %{uri_replies: table}} = s) do
    table
    |> :ets.tab2list()
    |> Enum.filter(&match?({_key, {:done, _at, _code, _body}, _id, _self}, &1))
    |> Enum.sort_by(fn {_key, {:done, at, _code, _body}, _id, _self} -> at end)
    |> Enum.reduce(s, fn {key, {:done, _at, code, body}, id, self}, s ->
      :ets.delete(table, key)
      callback(s, id, code, body, self)
    end)
  end

  def run(s), do: s

  defp callback(s, id, code, body, self) do
    case QuakeC.Progs.function(s.qc.progs, "URI_Get_Callback") do
      nil ->
        Events.print(s, :notify, "URI_Get_Callback missing\n")

      function ->
        old_self = QuakeC.global(s.qc, "self")

        qc =
          s.qc
          |> QuakeC.put_global("self", self)
          |> QuakeC.put_slot(4, id)
          |> QuakeC.put_slot(7, if(code == 200, do: 0.0, else: code / 1))
          |> QuakeC.put_slot(10, body || 0)
          |> QuakeC.put_slot(13, byte_size(body || ""))

        s = Exec.call(%{s | qc: qc}, function, s.builtins, Server.exec_opts(s))
        %{s | qc: QuakeC.put_global(s.qc, "self", old_self)}
    end
  end

  defp request(s, url, argc) do
    mime = if argc >= 3, do: Args.str(s, 2), else: ""
    data = if argc >= 4, do: Args.str(s, 3), else: ""
    buffer = if argc >= 5, do: trunc(Args.num(s, 4)), else: 0

    cond do
      mime == "" -> {:get, url}
      buffer != 0 -> post(s, url, mime, buffer, data)
      true -> {:post, url, mime, data}
    end
  end

  defp post(s, url, mime, buffer, glue) do
    case Store.entry(s, :buffers, buffer) do
      nil -> {:none, url}
      strings -> {:post, url, mime, strings |> Enum.sort() |> Enum.map_join(glue, &elem(&1, 1))}
    end
  end

  defp fetch(table, key, request) do
    {code, body} = http(request)

    if :ets.info(table) != :undefined,
      do: :ets.update_element(table, key, {2, {:done, System.monotonic_time(), code, body}})
  end

  defp http({:none, _url}), do: {0, nil}

  defp http(request) do
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])

    result =
      case request do
        {:get, url} ->
          :httpc.request(:get, {String.to_charlist(url), []}, options(url), body_format: :binary)

        {:post, url, mime, data} ->
          :httpc.request(
            :post,
            {String.to_charlist(url), [], String.to_charlist(mime), data},
            options(url),
            body_format: :binary
          )
      end

    case result do
      {:ok, {{_version, status, _reason}, _headers, body}} -> {status, body}
      {:error, _reason} -> {0, nil}
    end
  end

  defp options(url) do
    ssl =
      if String.starts_with?(url, "https:"),
        do: [
          ssl: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ],
        else: []

    [timeout: @timeout, connect_timeout: @timeout] ++ ssl
  end

  defp table(%{ext: %{uri_replies: table}} = s), do: {s, table}

  defp table(s) do
    table = :ets.new(__MODULE__, [:set, :public])
    {%{s | ext: Map.put(s.ext, :uri_replies, table)}, table}
  end

  defp pending(%{ext: %{uri_replies: table}}), do: :ets.info(table, :size)
  defp pending(_s), do: 0

  defp resolve(_s, "internalserver", _port), do: "QLoopBack:0"

  defp resolve(_s, "QLoopBack" <> rest, port) do
    case rest do
      ":" <> number -> "QLoopBack:#{leading_integer(number)}"
      _ -> "QLoopBack:#{port}"
    end
  end

  defp resolve(s, address, port) do
    with true <- net?(s),
         {host, port} <- split_port(address, port),
         {:ok, ip} <- lookup(host) do
      format_address(ip, port)
    else
      _ -> ""
    end
  end

  defp split_port("[" <> rest, port) do
    case String.split(rest, "]", parts: 2) do
      [host, ":" <> number] -> {host, leading_integer(number)}
      [host, _] -> {host, port}
      _ -> nil
    end
  end

  defp split_port(address, port) do
    case String.split(address, ":") do
      [host, number] -> {host, leading_integer(number)}
      [host] -> {host, port}
      _ -> {address, port}
    end
  end

  defp lookup(""), do: :error

  defp lookup(host) do
    chars = String.to_charlist(host)

    with {:error, _} <- :inet.parse_address(chars),
         {:error, _} <- :inet.getaddr(chars, :inet),
         {:error, _} <- :inet.getaddr(chars, :inet6) do
      :error
    end
  end

  defp format_address({a, b, c, d}, 0), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_address({a, b, c, d}, port), do: "#{a}.#{b}.#{c}.#{d}:#{port}"

  defp format_address(ip, port) do
    text = ip |> :inet.ntoa() |> to_string()
    if port == 0, do: text, else: "[#{text}]:#{port}"
  end

  defp net?(s), do: cvar_int(s, "net_enabled", 1) != 0

  defp leading_integer(text) do
    case Integer.parse(text) do
      {value, _} -> value
      :error -> 0
    end
  end

  defp format(number) do
    if number == trunc(number),
      do: Integer.to_string(trunc(number)),
      else: Float.to_string(number)
  end

  defp cvar_int(%{cvars: %Cvars{} = cvars}, name, default) do
    case Cvars.fetch(cvars, name) do
      nil -> default
      cvar -> cvar.ival
    end
  end

  defp cvar_int(_s, _name, default), do: default
end
