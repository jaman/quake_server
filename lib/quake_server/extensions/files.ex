defmodule QuakeServer.Extensions.Files do
  @moduledoc """
  FTE's file builtins beyond opening, reading and writing (`QuakeServer.Extensions.Store`):

    * `fwrite` — bytes from memory added to a file open for writing; returns how many
    * `search_getfilemtime` — a search result's modification time as
      `YYYY-MM-DD HH:MM:SS` (local time), null when not known
    * `search_fopen` — a search result opened for reading: its handle, or -1
    * `fcopy` (650), `frename` (651), `fexists` (653), `rmtree` (654)

  Names pass FTE's `QC_FixFileName` (`fix_name/1`): a name with `:`, `\\`, `..` or a
  leading `/`, or an empty one, is refused; others go under `data/`, with the plain name
  read when `data/` lacks it unless it is a `.cfg` file outside a folder or in
  `configs/`. `fcopy` returns 0, or -1 when a name is refused or the source is missing;
  as FTE's does, it writes what it read to the source's `data/` name. `frename` moves one
  of the program's written files: 0, -5 when there is none, -1 for a refused name.
  `fexists` is whether the name, as given, is one of the program's written files.
  `rmtree` prints that it is not implemented and does nothing, as FTE's does.
  """

  alias QuakeServer.{Args, EntityTable, Events}
  alias QuakeServer.Extensions.{Memory, Store}

  @doc "Run file builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, "fwrite", argc) do
    offset = if argc > 3, do: Args.int(s, 3), else: 0
    data = Memory.bytes(s.qc, Args.int(s, 1) + offset, Args.int(s, 2))
    {s, written} = write(s, Args.int(s, 0), data)
    Args.return(s, written)
  end

  def call(s, "search_getfilemtime", _argc) do
    case search_name(s) do
      nil ->
        Args.return(s, 0)

      name ->
        case Store.modified(s, name) do
          nil -> Args.return(s, 0)
          seconds -> Args.return(s, local_time(seconds))
        end
    end
  end

  def call(s, "search_fopen", _argc) do
    with name when is_binary(name) <- search_name(s),
         data when is_binary(data) <- Store.read(s, name) do
      {s, handle} = Store.open_buffer(s, name, data, 0)
      Args.return(s, handle / 1)
    else
      _ -> Args.return(s, -1.0)
    end
  end

  def call(s, 650, _argc) do
    with {:ok, source, fallback} <- fix_name(Args.str(s, 0)),
         {:ok, _target, _} <- fix_name(Args.str(s, 1)),
         data when is_binary(data) <-
           Store.read(s, source) || (fallback && Store.read(s, fallback)) do
      s |> Store.write(source, data) |> Args.return(0.0)
    else
      _ -> Args.return(s, -1.0)
    end
  end

  def call(s, 651, _argc) do
    with {:ok, source, _} <- fix_name(Args.str(s, 0)),
         {:ok, target, _} <- fix_name(Args.str(s, 1)) do
      if Store.written?(s, source) do
        data = Store.read(s, source)

        s
        |> EntityTable.rename(source, target)
        |> Store.remove(source)
        |> Store.write(target, data)
        |> Args.return(0.0)
      else
        Args.return(s, -5.0)
      end
    else
      :error -> Args.return(s, -1.0)
    end
  end

  def call(s, 653, _argc), do: Args.return(s, Store.written?(s, Args.str(s, 0)))

  def call(s, 654, _argc) do
    name = Args.str(s, 0)
    Events.print(s, :notify, "rmtree(\"#{name}\"): rmtree is not implemented at this time\n")
  end

  @doc """
  A program's file name as FTE's `QC_FixFileName` takes it: `{:ok, name, fallback}`, the
  name to use and the one to read when it is missing (or `nil`), or `:error` for a
  refused name.
  """
  @spec fix_name(String.t()) :: {:ok, String.t(), String.t() | nil} | :error
  def fix_name("file:" <> _ = name), do: {:ok, name, nil}

  def fix_name(name) do
    cond do
      name == "" or String.contains?(name, [":", "\\", ".."]) or String.starts_with?(name, "/") ->
        :error

      String.starts_with?(name, "data/") ->
        {:ok, name, nil}

      sandboxed?(name) ->
        {:ok, "data/" <> name, nil}

      true ->
        {:ok, "data/" <> name, name}
    end
  end

  @doc """
  Add `data` to file `handle` when it is open for writing, as FTE's `PF_fwrite_internal`:
  the host and how many bytes were written (0 for a file not open for writing).
  """
  @spec write(map(), integer(), binary()) :: {map(), non_neg_integer()}
  def write(s, handle, data) do
    case Store.entry(s, :files, handle) do
      %{mode: :write} = file ->
        {Store.put_entry(s, :files, handle, %{file | data: file.data <> data}), byte_size(data)}

      _ ->
        {s, 0}
    end
  end

  defp sandboxed?(name) do
    (not String.contains?(name, "/") or String.starts_with?(String.downcase(name), "configs/")) and
      String.downcase(Path.extname(name)) == ".cfg"
  end

  defp search_name(s) do
    names = Store.entry(s, :searches, Args.int(s, 0)) || {}
    index = Args.int(s, 1)
    if index >= 0 and index < tuple_size(names), do: elem(names, index)
  end

  defp local_time(seconds) do
    {{year, month, day}, {hour, minute, second}} =
      seconds
      |> :calendar.system_time_to_universal_time(:second)
      |> :calendar.universal_time_to_local_time()

    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [
      year,
      month,
      day,
      hour,
      minute,
      second
    ])
    |> IO.iodata_to_binary()
  end
end
