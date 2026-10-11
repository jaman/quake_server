defmodule QuakeServer.Extensions.Buffers do
  @moduledoc """
  FTE's string buffer builtins beyond making, reading and writing single strings
  (`QuakeServer.Extensions.Store`):

    * `buf_copy` (463) — the second buffer replaced by a copy of the first
    * `buf_sort` (464) — empty places dropped, then the strings sorted by their first
      `prefix` bytes (all when 0 or less), backwards when the third argument is set
    * `bufstr_find` (537) — the first index from `start`, stepping by `step`, whose string
      matches: method 1 exact, 2 starts with, 3 ends with, 4 contains, else a wildcard
      pattern (`*` stops at `/` and `\\`, `?` one character, case ignored); -1 for none
    * `buf_loadfile` (535) — a file's lines added to a buffer (1, or 0 when the buffer or
      file is missing or the name refused, `QuakeServer.Extensions.Files.fix_name/1`)
    * `buf_writefile` (536) — a buffer's strings, from an index for a count, written to a
      file open for writing, each followed by a newline (1, or 0 when either is missing)
  """

  alias QuakeServer.{Args, Events}
  alias QuakeServer.Extensions.{Files, Store}

  @doc "Run string buffer builtin `builtin`."
  @spec call(map(), integer(), non_neg_integer()) :: map()
  def call(s, 463, _argc) do
    from = Args.int(s, 0)
    to = Args.int(s, 1)
    source = Store.entry(s, :buffers, from)

    if from != to and source != nil and Store.entry(s, :buffers, to) != nil,
      do: Store.put_entry(s, :buffers, to, source),
      else: s
  end

  def call(s, 464, _argc) do
    handle = Args.int(s, 0)
    prefix = trunc(Args.num(s, 1))
    prefix = if prefix <= 0, do: 0x7FFFFFFF, else: prefix
    backwards = Args.num(s, 2) != 0

    case Store.entry(s, :buffers, handle) do
      nil ->
        s

      buffer ->
        sorted =
          buffer
          |> Enum.sort()
          |> Enum.map(&elem(&1, 1))
          |> Enum.sort_by(
            &binary_part(&1, 0, min(prefix, byte_size(&1))),
            if(backwards, do: :desc, else: :asc)
          )
          |> Enum.with_index()
          |> Map.new(fn {text, i} -> {i, text} end)

        Store.put_entry(s, :buffers, handle, sorted)
    end
  end

  def call(s, 537, argc) do
    pattern = Args.str(s, 1)
    method = trunc(Args.num(s, 2))
    start = trunc(Args.num(s, 3, argc, 0.0))
    step = trunc(Args.num(s, 4, argc, 1.0))

    with buffer when buffer != nil <- Store.entry(s, :buffers, Args.int(s, 0)),
         true <- start >= 0 and step > 0 do
      found =
        Enum.find(start..(Store.buffer_size(buffer) - 1)//step, -1, fn i ->
          (text = Map.get(buffer, i)) && matches?(text, pattern, method)
        end)

      Args.return(s, found / 1)
    else
      _ -> Args.return(s, -1.0)
    end
  end

  def call(s, 535, _argc) do
    given = Args.str(s, 0)
    handle = Args.int(s, 1)

    with buffer when buffer != nil <- Store.entry(s, :buffers, handle),
         {:ok, name, fallback} <- fixed(s, given),
         data when is_binary(data) <- Store.read(s, name) || (fallback && Store.read(s, fallback)) do
      buffer = Enum.reduce(lines(data), buffer, &Map.put(&2, Store.buffer_size(&2), &1))
      s |> Store.put_entry(:buffers, handle, buffer) |> Args.return(1.0)
    else
      {:denied, s} -> Args.return(s, 0.0)
      _ -> Args.return(s, 0.0)
    end
  end

  def call(s, 536, argc) do
    file = Args.int(s, 0)
    buffer = Store.entry(s, :buffers, Args.int(s, 1))

    if buffer == nil or Store.entry(s, :files, file) == nil do
      Args.return(s, 0.0)
    else
      size = Store.buffer_size(buffer)
      first = if argc >= 3, do: trunc(Args.num(s, 2)), else: 0
      last = if argc >= 4, do: first + trunc(Args.num(s, 3)), else: size - first
      last = min(last, size)
      first = first |> max(0) |> min(size)

      first..(last - 1)//1
      |> Enum.flat_map(&List.wrap(Map.get(buffer, &1)))
      |> Enum.reduce(s, fn text, s ->
        s |> Files.write(file, text) |> elem(0) |> Files.write(file, "\n") |> elem(0)
      end)
      |> Args.return(1.0)
    end
  end

  defp fixed(s, name) do
    case Files.fix_name(name) do
      :error -> {:denied, Events.print(s, :notify, "qcfopen: Access denied: #{name}\n")}
      ok -> ok
    end
  end

  defp lines(""), do: []

  defp lines(data) do
    data
    |> String.split("\n")
    |> then(fn parts -> if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts end)
    |> Enum.map(&String.trim_trailing(&1, "\r"))
  end

  defp matches?(text, pattern, 1), do: text == pattern
  defp matches?(text, pattern, 2), do: String.starts_with?(text, pattern)
  defp matches?(text, pattern, 3), do: String.ends_with?(text, pattern)
  defp matches?(text, pattern, 4), do: String.contains?(text, pattern)
  defp matches?(text, pattern, _method), do: wildcard?(pattern, text)

  @doc "Whether `text` matches wildcard `pattern` as FTE's `wildcmp`: `*` stops at `/` and `\\`, `?` is any one character, case ignored."
  @spec wildcard?(binary(), binary()) :: boolean()
  def wildcard?(pattern, text), do: wild(pattern, text)

  defp wild(<<?*, rest::binary>> = pattern, <<c, more::binary>> = text) do
    cond do
      c in [?/, ?\\] -> wild(rest, text)
      wild(rest, text) -> true
      true -> wild(pattern, more)
    end
  end

  defp wild(<<p, rest::binary>>, <<c, more::binary>>) do
    if p == ?? or lower(p) == lower(c), do: wild(rest, more), else: false
  end

  defp wild(pattern, <<>>), do: String.trim_leading(pattern, "*") == ""
  defp wild(<<>>, _text), do: false

  defp lower(c) when c in ?A..?Z, do: c + 32
  defp lower(c), do: c
end
