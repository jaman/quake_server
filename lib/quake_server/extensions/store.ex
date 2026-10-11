defmodule QuakeServer.Extensions.Store do
  @moduledoc """
  FTE's builtins that keep things: hash tables, allocated memory, files, file searches and
  string buffers.

  Files are read from the game (`QuakeServer.Source`'s optional `read/1` and `list/1`)
  and, under `data/`, from the files the program wrote; `fopen` of a name without
  `data/` reads `data/name` first, then `name`. Written files are kept in the
  host's `ext.written` and, when the host has a `data_dir`, also written there. Each
  written file keeps the entity table of its blocks, and a file carried from an earlier
  level is read with its entity numbers translated (`QuakeServer.EntityTable`).

  State lives in the host's `ext`: `hashes`, `files`, `searches`, `buffers`, each a map
  from handle to contents, and `next_handle`. The game's files a search pattern matches
  are kept in `listings`, by pattern, for the host's life.
  """

  import Bitwise

  alias QuakeServer.{Args, EntityTable}

  @replace 256
  @add 512

  @doc "Run storage builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 287, _argc) do
    {s, handle} = handle(s)
    s |> put(:hashes, handle, %{}) |> Args.return(handle)
  end

  def call(s, 288, _argc), do: drop(s, :hashes, Args.int(s, 0))

  def call(s, 289, argc) do
    table = Args.int(s, 0)
    key = Args.str(s, 1)
    flags = if argc > 3, do: Args.int(s, 3), else: 0
    type = band(flags, 0xFF)
    entry = {type, hash_value(s, type)}
    entries = s |> get(:hashes, table, %{}) |> Map.get(key, [])

    entries =
      cond do
        band(flags, @replace) != 0 -> [entry]
        band(flags, @add) != 0 -> entries ++ [entry]
        entries == [] -> [entry]
        true -> entries
      end

    update(s, :hashes, table, %{}, &Map.put(&1, key, entries))
  end

  def call(s, 290, argc) do
    entries = s |> get(:hashes, Args.int(s, 0), %{}) |> Map.get(Args.str(s, 1), [])
    type = if argc > 3, do: Args.int(s, 3), else: 0
    index = if argc > 4, do: Args.int(s, 4), else: 0
    matching = if type == 0, do: entries, else: Enum.filter(entries, &(elem(&1, 0) == type))

    case Enum.at(matching, index) do
      {_type, value} -> put_return(s, value)
      nil -> put_return(s, Args.vec_raw(s, 2))
    end
  end

  def call(s, 291, _argc) do
    table = Args.int(s, 0)
    key = Args.str(s, 1)
    found = s |> get(:hashes, table, %{}) |> Map.get(key, [])
    s = update(s, :hashes, table, %{}, &Map.delete(&1, key))

    case found do
      [{_type, value} | _] -> put_return(s, value)
      [] -> Args.return(s, 0)
    end
  end

  def call(s, 292, _argc) do
    keys = s |> get(:hashes, Args.int(s, 0), %{}) |> Map.keys()
    Args.return(s, Enum.at(keys, Args.int(s, 1)) || 0)
  end

  def call(s, 384, _argc) do
    {qc, address} = QuakeC.alloc(s.qc, Args.int(s, 0))
    Args.return(%{s | qc: qc}, address)
  end

  def call(s, 385, _argc), do: %{s | qc: QuakeC.free(s.qc, Args.int(s, 0))}

  def call(s, 386, argc) do
    words = div(Args.int(s, 2) + 3, 4)
    to = Args.int(s, 0) + if(argc > 3, do: Args.int(s, 3), else: 0)
    from = Args.int(s, 1) + if(argc > 4, do: Args.int(s, 4), else: 0)
    %{s | qc: QuakeC.move(s.qc, from, to, words)}
  end

  def call(s, 387, argc) do
    byte = band(Args.int(s, 1), 0xFF)
    word = byte * 0x01010101
    word = if word >= 0x80000000, do: word - 0x100000000, else: word
    at = Args.int(s, 0) + if(argc > 3, do: Args.int(s, 3), else: 0)
    words = div(Args.int(s, 2) + 3, 4)
    %{s | qc: QuakeC.fill(s.qc, at, words, word)}
  end

  def call(s, 388, _argc),
    do: Args.return(s, QuakeC.load(s.qc, Args.int(s, 0) + trunc(Args.num(s, 1))))

  def call(s, 389, _argc),
    do: %{s | qc: QuakeC.store(s.qc, Args.int(s, 0) + trunc(Args.num(s, 1)), Args.slot(s, 2))}

  def call(s, 390, _argc), do: Args.return(s, Args.int(s, 0) + trunc(Args.num(s, 1)))

  def call(s, 110, _argc) do
    name = Args.str(s, 0)
    mode = trunc(Args.num(s, 1))

    case open(s, name, mode) do
      {:ok, file} ->
        {s, handle} = handle(s)

        s
        |> put(:files, handle, Map.delete(file, :path))
        |> EntityTable.open(handle, file.path)
        |> Args.return(handle / 1)

      :error ->
        Args.return(s, -1.0)
    end
  end

  def call(s, 111, _argc) do
    handle = Args.int(s, 0)
    file = get(s, :files, handle, nil)

    s
    |> flush(file)
    |> EntityTable.keep(file)
    |> EntityTable.finish(handle)
    |> drop(:files, handle)
  end

  def call(s, 112, _argc) do
    handle = Args.int(s, 0)

    case get(s, :files, handle, nil) do
      %{mode: :read, data: data, at: at} = file when at < byte_size(data) ->
        {line, next} = line(data, at, file.whole?)

        s
        |> put(:files, handle, %{file | at: next})
        |> EntityTable.read(handle, line)
        |> Args.return(line)

      _ ->
        s |> EntityTable.finish(handle) |> Args.return(0)
    end
  end

  def call(s, 113, argc) do
    handle = Args.int(s, 0)
    text = Enum.map_join(1..(max(argc, 2) - 1), &Args.str(s, &1))
    writer = Args.self(s)

    update(s, :files, handle, nil, fn
      %{mode: :write} = file ->
        EntityTable.record(%{file | data: file.data <> text}, text, writer)

      other ->
        other
    end)
  end

  def call(s, "fsize", _argc) do
    case get(s, :files, Args.int(s, 0), nil) do
      %{data: data} -> Args.return(s, byte_size(data))
      nil -> Args.return(s, -1)
    end
  end

  def call(s, "fseek", argc) do
    handle = Args.int(s, 0)

    case get(s, :files, handle, nil) do
      %{at: at} = file when argc > 1 ->
        s |> put(:files, handle, %{file | at: Args.int(s, 1)}) |> Args.return(at)

      %{at: at} ->
        Args.return(s, at)

      nil ->
        Args.return(s, -1)
    end
  end

  def call(s, "fread", argc) do
    handle = Args.int(s, 0)
    size = Args.int(s, 2)

    case get(s, :files, handle, nil) do
      %{data: data, at: at} = file ->
        at = if argc > 3, do: Args.int(s, 3), else: at
        count = size |> min(byte_size(data) - at) |> max(0)
        bytes = binary_part(data, at, count) <> :binary.copy(<<0>>, rem(4 - rem(count, 4), 4))
        qc = write_words(s.qc, Args.int(s, 1), bytes)
        %{s | qc: qc} |> put(:files, handle, %{file | at: at + count}) |> Args.return(count)

      nil ->
        Args.return(s, -1)
    end
  end

  def call(s, 652, _argc), do: s |> remove("data/" <> Args.str(s, 0)) |> Args.return(0.0)

  def call(s, 444, _argc) do
    pattern = Args.str(s, 0)

    {names, s} = pattern |> String.split(":") |> Enum.flat_map_reduce(s, &search/2)
    names = names |> Enum.uniq() |> Enum.sort()

    {s, handle} = handle(s)
    s |> put(:searches, handle, List.to_tuple(names)) |> Args.return(handle / 1)
  end

  def call(s, 445, _argc), do: drop(s, :searches, Args.int(s, 0))

  def call(s, 446, _argc),
    do: Args.return(s, tuple_size(get(s, :searches, Args.int(s, 0), {})) / 1)

  def call(s, 447, _argc) do
    names = get(s, :searches, Args.int(s, 0), {})
    index = Args.int(s, 1)
    Args.return(s, if(index >= 0 and index < tuple_size(names), do: elem(names, index), else: 0))
  end

  def call(s, "search_getpackagename", _argc) do
    names = get(s, :searches, Args.int(s, 0), {})
    index = Args.int(s, 1)
    name = if index >= 0 and index < tuple_size(names), do: elem(names, index)
    Args.return(s, (name && package(s, name)) || 0)
  end

  def call(s, "search_getfilesize", _argc) do
    names = get(s, :searches, Args.int(s, 0), {})
    index = Args.int(s, 1)

    size =
      if index >= 0 and index < tuple_size(names),
        do: byte_size(read(s, elem(names, index)) || ""),
        else: 0

    Args.return(s, size / 1)
  end

  def call(s, 503, _argc), do: Args.return(s, package(s, Args.str(s, 0)) || 0)

  def call(s, 460, _argc) do
    {s, handle} = handle(s)
    s |> put(:buffers, handle, %{}) |> Args.return(handle / 1)
  end

  def call(s, 461, _argc), do: drop(s, :buffers, Args.int(s, 0))

  def call(s, 462, _argc),
    do: Args.return(s, buffer_size(get(s, :buffers, Args.int(s, 0), %{})) / 1)

  def call(s, 465, _argc) do
    buffer = get(s, :buffers, Args.int(s, 0), %{})

    text =
      0..(buffer_size(buffer) - 1)//1
      |> Enum.map_join(Args.str(s, 1), &Map.get(buffer, &1, ""))

    Args.return(s, text)
  end

  def call(s, 466, _argc),
    do: Args.return(s, s |> get(:buffers, Args.int(s, 0), %{}) |> Map.get(Args.int(s, 1), 0))

  def call(s, 467, _argc),
    do: update(s, :buffers, Args.int(s, 0), %{}, &Map.put(&1, Args.int(s, 1), Args.str(s, 2)))

  def call(s, 468, _argc) do
    buffer = get(s, :buffers, Args.int(s, 0), %{})
    index = if Args.num(s, 2) != 0, do: free_index(buffer), else: buffer_size(buffer)

    s
    |> update(:buffers, Args.int(s, 0), %{}, &Map.put(&1, index, Args.str(s, 1)))
    |> Args.return(index / 1)
  end

  def call(s, 469, _argc),
    do: update(s, :buffers, Args.int(s, 0), %{}, &Map.delete(&1, Args.int(s, 1)))

  @doc """
  Open `data` as file `name` for the program to read from byte `at`, as FTE's
  `PR_QCFile_From_Buffer` hands an engine buffer to the program; returns the host and
  the file's handle.
  """
  @spec open_buffer(map(), String.t(), binary(), non_neg_integer()) :: {map(), pos_integer()}
  def open_buffer(s, name, data, at) do
    {s, handle} = handle(s)
    file = %{mode: :read, name: name, data: data, at: at, whole?: false}
    {put(s, :files, handle, file), handle}
  end

  @doc """
  Open file `name` for the program to write after `data`, as FTE's `PR_QCFile_From_VFS`
  hands it an engine file; closed by the program, it is kept as the program's written
  files are. Returns the host and the file's handle.
  """
  @spec open_output(map(), String.t(), binary()) :: {map(), pos_integer()}
  def open_output(s, name, data) do
    {s, handle} = handle(s)
    file = %{mode: :write, name: name, data: data, at: 0, whole?: false}
    {put(s, :files, handle, file), handle}
  end

  @doc """
  What file `handle`, opened by `open_output/3` as `name`, holds: its text while open,
  the written file `name` once the program has closed it.
  """
  @spec output(map(), pos_integer(), String.t()) :: binary()
  def output(s, handle, name) do
    case get(s, :files, handle, nil) do
      %{mode: :write, name: ^name, data: data} -> data
      _ -> s.ext |> Map.get(:written, %{}) |> Map.get(name, "")
    end
  end

  @doc "What handle `handle` of `kind` (`:files`, `:buffers`, `:searches` or `:hashes`) holds, or `nil`."
  @spec entry(map(), atom(), integer()) :: term()
  def entry(s, kind, handle), do: get(s, kind, handle, nil)

  @doc "Make handle `handle` of `kind` hold `value`."
  @spec put_entry(map(), atom(), integer(), term()) :: map()
  def put_entry(s, kind, handle, value), do: put(s, kind, handle, value)

  @doc "A handle number not yet given out, and the host that has given it."
  @spec new_handle(map()) :: {map(), pos_integer()}
  def new_handle(s), do: handle(s)

  @doc """
  Keep `data` as the program's written file `name`: in the host's `ext.written` and,
  when the host has a `data_dir`, under it.
  """
  @spec write(map(), String.t(), binary()) :: map()
  def write(s, name, data), do: flush(s, %{mode: :write, name: name, data: data})

  @doc "Drop the program's written file `name`, from `ext.written` and from the host's `data_dir`."
  @spec remove(map(), String.t()) :: map()
  def remove(s, name) do
    if dir = data_dir(s), do: File.rm(Path.join(dir, name))
    s = %{s | ext: Map.update(s.ext, :written, %{}, &Map.delete(&1, name))}
    EntityTable.forget(s, name)
  end

  @doc "Whether `name` is one of the program's written files, kept or under the host's `data_dir`."
  @spec written?(map(), String.t()) :: boolean()
  def written?(s, name) do
    s.ext |> Map.get(:written, %{}) |> Map.has_key?(name) or
      ((dir = data_dir(s)) && File.regular?(Path.join(dir, name))) == true
  end

  @doc "The modification time of written file `name` under the host's `data_dir`, as seconds since 1970, or `nil`."
  @spec modified(map(), String.t()) :: integer() | nil
  def modified(s, name) do
    with dir when is_binary(dir) <- data_dir(s),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(Path.join(dir, name), time: :posix) do
      mtime
    else
      _ -> nil
    end
  end

  @doc "How many places string buffer `buffer` has: one past its highest index, 0 when empty."
  @spec buffer_size(map()) :: non_neg_integer()
  def buffer_size(buffer) when map_size(buffer) == 0, do: 0
  def buffer_size(buffer), do: (buffer |> Map.keys() |> Enum.max()) + 1

  @doc "The bytes of game file `name`, the program's own written files first; `nil` when there is none."
  @spec read(map(), String.t()) :: binary() | nil
  def read(s, name) do
    written = s.ext |> Map.get(:written, %{}) |> Map.get(name)

    on_disk =
      (dir = data_dir(s)) && File.exists?(Path.join(dir, name)) &&
        File.read!(Path.join(dir, name))

    written || on_disk || source_read(s, name)
  end

  defp package(s, name) do
    source = Map.get(s, :source)
    written? = s.ext |> Map.get(:written, %{}) |> Map.has_key?(name)

    cond do
      written? ->
        "data"

      source && Code.ensure_loaded?(source) && function_exported?(source, :package, 1) ->
        source.package(name)

      read(s, name) ->
        ""

      true ->
        nil
    end
  end

  defp source_read(s, name) do
    source = Map.get(s, :source)

    if source && Code.ensure_loaded?(source) && function_exported?(source, :read, 1),
      do: source.read(name) || source.read(String.trim_leading(name, "data/")),
      else: nil
  end

  defp search(pattern, s) do
    regex = glob(pattern)

    written =
      s.ext |> Map.get(:written, %{}) |> Map.keys() |> Enum.filter(&Regex.match?(regex, &1))

    {listed, s} = listed(s, pattern, regex)
    {listed ++ written, s}
  end

  defp listed(s, pattern, regex) do
    case s.ext |> Map.get(:listings, %{}) |> Map.fetch(pattern) do
      {:ok, names} ->
        {names, s}

      :error ->
        names = s |> source_list(pattern) |> Enum.filter(&Regex.match?(regex, &1))
        listings = s.ext |> Map.get(:listings, %{}) |> Map.put(pattern, names)
        {names, %{s | ext: Map.put(s.ext, :listings, listings)}}
    end
  end

  defp source_list(s, pattern) do
    source = Map.get(s, :source)
    prefix = pattern |> String.split(["*", "?"]) |> hd()

    if source && Code.ensure_loaded?(source) && function_exported?(source, :list, 1),
      do: source.list(prefix),
      else: []
  end

  defp glob(pattern) do
    body =
      pattern
      |> String.downcase()
      |> Regex.escape()
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", ".")

    Regex.compile!("^" <> body <> "$", "i")
  end

  defp open(s, name, mode) when mode in [0, 4] do
    case Enum.find_value(read_names(name), &found(s, &1)) do
      nil ->
        :error

      {path, data} ->
        {:ok, %{mode: :read, name: name, path: path, data: data, at: 0, whole?: mode == 4}}
    end
  end

  defp open(s, name, mode) when mode in [1, 2] do
    path = if String.starts_with?(name, "data/"), do: name, else: "data/" <> name
    data = if mode == 1, do: read(s, path) || "", else: ""
    file = %{mode: :write, name: path, path: path, data: data, at: 0, whole?: false}
    {:ok, EntityTable.record(file, data, 0)}
  end

  defp open(_s, _name, _mode), do: :error

  defp found(s, name) do
    case read(s, name) do
      nil -> nil
      data -> {name, data}
    end
  end

  defp read_names("data/" <> _ = name), do: [name]
  defp read_names(name), do: ["data/" <> name, name]

  defp flush(s, %{mode: :write, name: name, data: data}) do
    if dir = data_dir(s) do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, data)
    end

    %{s | ext: Map.update(s.ext, :written, %{name => data}, &Map.put(&1, name, data))}
  end

  defp flush(s, _file), do: s

  defp line(data, at, true), do: {binary_part(data, at, byte_size(data) - at), byte_size(data)}

  defp line(data, at, false) do
    case :binary.match(data, "\n", scope: {at, byte_size(data) - at}) do
      {stop, _} -> {data |> binary_part(at, stop - at) |> String.trim_trailing("\r"), stop + 1}
      :nomatch -> {binary_part(data, at, byte_size(data) - at), byte_size(data)}
    end
  end

  defp write_words(qc, at, bytes) do
    for(<<word::little-signed-32 <- bytes>>, do: word)
    |> Enum.with_index()
    |> Enum.reduce(qc, fn {word, i}, qc -> QuakeC.store(qc, at + 4 * i, word) end)
  end

  defp data_dir(s), do: Map.get(s, :data_dir)

  defp hash_value(s, 1), do: Args.str(s, 2)
  defp hash_value(s, 3), do: Args.vec(s, 2)
  defp hash_value(s, 2), do: Args.num(s, 2)
  defp hash_value(s, _type), do: Args.vec_raw(s, 2)

  defp put_return(s, {_, _, _} = value), do: Args.return(s, value)
  defp put_return(s, value), do: Args.return(s, value)

  defp free_index(buffer),
    do: Enum.find(0..buffer_size(buffer), &(not Map.has_key?(buffer, &1)))

  defp handle(s) do
    handle = Map.get(s.ext, :next_handle, 1)
    {%{s | ext: Map.put(s.ext, :next_handle, handle + 1)}, handle}
  end

  defp get(s, kind, handle, default), do: s.ext |> Map.get(kind, %{}) |> Map.get(handle, default)

  defp put(s, kind, handle, value),
    do: %{s | ext: Map.update(s.ext, kind, %{handle => value}, &Map.put(&1, handle, value))}

  defp update(s, kind, handle, default, change),
    do: put(s, kind, handle, change.(get(s, kind, handle, default)))

  defp drop(s, kind, handle),
    do: %{s | ext: Map.update(s.ext, kind, %{}, &Map.delete(&1, handle))}
end
