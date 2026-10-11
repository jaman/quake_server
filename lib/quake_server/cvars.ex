defmodule QuakeServer.Cvars do
  @moduledoc """
  FTE's console variables: one table every process of a game reads and writes, the
  server, its client program and its menu alike, as FTE's single process has one set.

      cvars = QuakeServer.Cvars.new()
      QuakeServer.Cvars.register(cvars, "sv_gravity", "800")
      {:ok, _prints} = QuakeServer.Cvars.set(cvars, "sv_gravity", "600")
      QuakeServer.Cvars.value(cvars, "sv_gravity")
      #=> 600.0

  The table is an ETS table belonging to the process that called `new/0`; it lives as
  long as that process and `delete/1` frees it sooner. Reads never wait on another
  process. Names are matched without regard to ASCII case, and a variable registered
  with an `:alias` answers to both names.

  A variable holds its value as text (`string`), with `value` the text read as FTE's
  `Q_atof` reads it (a 32-bit float) and `ival` as `Q_atoi` reads it. Each has a default
  (the value `cvarreset` gives back) and, for one the engine registers, the engine's own
  default.

  Flags are FTE's (`flags/0`): `:archive` (written by `cfg_save`, set by `seta`),
  `:userinfo` and `:serverinfo` (the value is the player's or the server's info key of
  the same name), `:noset` (read only), `:maplatch` (a change while a server runs waits
  for the next map), `:rendererlatch` and `:videolatch` (a change while the renderer is
  up waits for `vid_reload` or `vid_restart`), `:notfromserver` (no program or server
  may set it), `:nounsafeexpand` (no program may read it), `:usercreated` (made by a
  config or a program rather than the engine) and the rest of FTE's.

  Every change is stamped and counts up the table's generation (`generation/1`), so a
  program's `autocvar_` globals and a server's info keys follow it
  (`QuakeServer.Autocvars`).

  The table also holds what FTE keeps beside its cvars: whether a server or a renderer
  is running (`put_running/3`), whether an archived variable changed since the last save
  (`unsaved?/1`), the directory configs are written to (`home/1`), the console aliases
  (`command_alias/2`) and the key bindings with their bind maps (`binding/3`,
  `bindmaps/1`).
  """

  import Bitwise

  alias QuakeServer.Cvars.Cvar

  @enforce_keys [:table, :generation]
  defstruct [:table, :generation, release: false]

  @type t :: %__MODULE__{
          table: :ets.tid(),
          generation: :atomics.atomics_ref(),
          release: boolean()
        }
  @type flag ::
          :archive
          | :userinfo
          | :serverinfo
          | :noset
          | :maplatch
          | :notfromserver
          | :usercreated
          | :cheat
          | :semicheat
          | :rendererlatch
          | :serveroverride
          | :renderercallback
          | :nounsafeexpand
          | :rulesetlatch
          | :shadersystem
          | :tellgamecode
          | :configdefault
          | :nosave
          | :noreset
          | :teamplaytaint
          | :watched
          | :videolatch
          | :warnonchange
          | :rendereroverride

  @flags %{
    archive: 1,
    userinfo: 2,
    serverinfo: 4,
    noset: 8,
    maplatch: 16,
    notfromserver: 128,
    usercreated: 256,
    cheat: 512,
    semicheat: 1024,
    rendererlatch: 2048,
    serveroverride: 4096,
    renderercallback: 8192,
    nounsafeexpand: 16_384,
    rulesetlatch: 32_768,
    shadersystem: 65_536,
    tellgamecode: 131_072,
    configdefault: 262_144,
    nosave: 524_288,
    noreset: 1_048_576,
    teamplaytaint: 2_097_152,
    watched: 4_194_304,
    videolatch: 8_388_608,
    warnonchange: 16_777_216,
    rendereroverride: 33_554_432
  }

  @key 0
  @name 1
  @string 2
  @value 3
  @ival 4
  @default 5
  @engine 6
  @bits 7
  @latched 8
  @description 9
  @stamp 10
  @group 11
  @alias 12
  @float32_max 3.4028234663852886e38

  @doc "A new, empty table belonging to the calling process."
  @spec new() :: t()
  def new do
    %__MODULE__{
      table: :ets.new(__MODULE__, [:set, :public, read_concurrency: true]),
      generation: :atomics.new(1, signed: false)
    }
  end

  @doc "Free the table; it may not be used after."
  @spec delete(t()) :: :ok
  def delete(%__MODULE__{table: table}) do
    :ets.delete(table)
    :ok
  end

  @doc "FTE's flag bits by name."
  @spec flags() :: %{flag() => pos_integer()}
  def flags, do: @flags

  @doc "The bitmask of flag names `names`."
  @spec bits([flag()]) :: non_neg_integer()
  def bits(names), do: Enum.reduce(names, 0, &(&2 ||| Map.fetch!(@flags, &1)))

  @doc "Whether `cvar` has flag `name`."
  @spec flag?(Cvar.t(), flag()) :: boolean()
  def flag?(%Cvar{flags: bits}, name), do: (bits &&& Map.fetch!(@flags, name)) != 0

  @doc "How many changes the table has seen; it counts up with every change."
  @spec generation(t()) :: non_neg_integer()
  def generation(%__MODULE__{generation: generation}), do: :atomics.get(generation, 1)

  @doc "The variable `name`, or `nil` when there is none."
  @spec fetch(t(), String.t()) :: Cvar.t() | nil
  def fetch(%__MODULE__{} = cvars, name) do
    case row(cvars, name) do
      nil -> nil
      row -> to_cvar(row)
    end
  end

  @doc "Whether there is a variable `name`."
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = cvars, name), do: row_key(cvars, name) != nil

  @doc "The value of `name` as a number, 0.0 when there is no such variable."
  @spec value(t(), String.t()) :: float()
  def value(%__MODULE__{} = cvars, name), do: element(cvars, name, @value, 0.0)

  @doc "The value of `name` as text, `\"\"` when there is no such variable."
  @spec string(t(), String.t()) :: String.t()
  def string(%__MODULE__{} = cvars, name), do: element(cvars, name, @string, "")

  @doc "The change stamp of `name`, or `nil` when there is no such variable."
  @spec stamp(t(), String.t()) :: integer() | nil
  def stamp(%__MODULE__{} = cvars, name), do: element(cvars, name, @stamp, nil)

  @doc """
  Register an engine variable, as FTE's `Cvar_Register`: one not there is made with
  `default` as its value, its default and its engine default; one a config or a program
  made first becomes the engine's, keeping its value (its latched one, if any) and its
  `:archive` flag; one the engine registered already is left as it is.

  Options: `:flags` (a list of `t:flag/0`), `:alias`, `:description`, `:group`.
  """
  @spec register(t(), String.t(), String.t(), keyword()) :: Cvar.t()
  def register(%__MODULE__{} = cvars, name, default, opts \\ []) do
    bits = bits(Keyword.get(opts, :flags, []))

    registered =
      case row(cvars, name) do
        nil ->
          insert(cvars, new_row(name, default, default, default, bits, opts))

        row when (elem(row, @bits) &&& @flags.usercreated) != 0 ->
          value = elem(row, @latched) || elem(row, @string)
          bits = bits ||| (elem(row, @bits) &&& @flags.archive)
          insert(cvars, new_row(name, value, default, default, bits, opts))

        row ->
          to_cvar(row)
      end

    remember_alias(cvars, Keyword.get(opts, :alias), key(name))
    registered
  end

  @doc """
  The variable `name`, made when there is none, as FTE's `Cvar_Get2`: one that is there
  takes on `:userinfo` and `:serverinfo` from `flags`; one made is created by a config or
  a program (`:usercreated`) with `default` as its value and default and the other
  `flags`. A name with a quote, `^`, `$`, `;` or whitespace in it, or an empty one, makes
  nothing: `nil`. Options: `:description`, `:group` (default `"Custom variables"`).
  """
  @spec get(t(), String.t(), String.t(), [flag()], keyword()) :: Cvar.t() | nil
  def get(%__MODULE__{} = cvars, name, default, flags \\ [], opts \\ []) do
    bits = bits(flags)

    case row(cvars, name) do
      nil ->
        if valid_name?(name) do
          opts = Keyword.put_new(opts, :group, "Custom variables")
          insert(cvars, new_row(name, default, default, nil, bits ||| @flags.usercreated, opts))
        end

      row ->
        info = bits &&& (@flags.userinfo ||| @flags.serverinfo)
        old = elem(row, @bits)

        if (old &&& info) == info,
          do: to_cvar(row),
          else: insert(cvars, put_elem(row, @bits, old ||| info))
    end
  end

  @doc """
  Make `value` variable `name`'s engine default, as FTE's `Cvar_SetEngineDefault`: its
  default follows when it was the engine's; its value is left as it is. Nothing when
  there is no such variable.
  """
  @spec put_engine_default(t(), String.t(), String.t()) :: :ok
  def put_engine_default(%__MODULE__{} = cvars, name, value) do
    case row(cvars, name) do
      nil ->
        :ok

      row ->
        row =
          if elem(row, @default) == elem(row, @engine),
            do: put_elem(row, @default, value),
            else: row

        insert(cvars, put_elem(row, @engine, value))
        :ok
    end
  end

  @doc "Give `name` the flags `flags` besides its own; nothing when there is no such variable."
  @spec add_flags(t(), String.t(), [flag()]) :: :ok
  def add_flags(%__MODULE__{} = cvars, name, flags) do
    bits = bits(flags)

    case row(cvars, name) do
      nil -> :ok
      row when (elem(row, @bits) &&& bits) == bits -> :ok
      row -> put_bits(cvars, row, elem(row, @bits) ||| bits)
    end
  end

  @doc "Take the flags `flags` off `name`; nothing when there is no such variable."
  @spec remove_flags(t(), String.t(), [flag()]) :: :ok
  def remove_flags(%__MODULE__{} = cvars, name, flags) do
    bits = bits(flags)

    case row(cvars, name) do
      nil -> :ok
      row when (elem(row, @bits) &&& bits) == 0 -> :ok
      row -> put_bits(cvars, row, elem(row, @bits) &&& bnot(bits))
    end
  end

  @doc """
  Set `name` to `value` (`nil` for its default), as FTE's `Cvar_Set`: a read-only
  variable is refused; a variable latched by its flags keeps `value` for later (a
  `:maplatch` one while a server runs, a `:rendererlatch` or `:videolatch` one while the
  renderer is up); otherwise the value changes, any latched value is dropped, and an
  engine variable's own check runs (`r_meshpitch` and `r_meshroll` become 1 or -1, `fov`
  at least 10, `viewsize` 30 to 120).

  `{:ok, lines}` gives the lines FTE prints about it (latching while `cl_warncmd` is set,
  read only); `{:error, :missing}` when there is no such variable. Option `force: true`
  sets past the latches and `:noset`.
  """
  @spec set(t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, [String.t()]} | {:error, :missing}
  def set(%__MODULE__{} = cvars, name, value, opts \\ []) do
    case row(cvars, name) do
      nil -> {:error, :missing}
      row -> {:ok, set_row(cvars, row, value, Keyword.get(opts, :force, false))}
    end
  end

  @doc """
  The server takes the variable over, as FTE's `Cvar_LockFromServer`: it is set to
  `value` past its latches and flagged `:serveroverride`, its own value kept as the
  latched one to come back to (`apply_latches/3` with `:serveroverride`).
  """
  @spec lock_from_server(t(), String.t(), String.t()) :: :ok
  def lock_from_server(%__MODULE__{} = cvars, name, value) do
    case row(cvars, name) do
      nil ->
        :ok

      row ->
        bits = (elem(row, @bits) ||| @flags.serveroverride) &&& bnot(@flags.rendereroverride)
        kept = elem(row, @latched) || elem(row, @string)
        insert(cvars, row |> put_elem(@bits, bits) |> put_elem(@latched, nil))
        set_row(cvars, row(cvars, name), value, true)
        insert(cvars, put_elem(row(cvars, name), @latched, kept))
        :ok
    end
  end

  @doc """
  Give every variable with any of the flags `flags` (one flag or a list) its latched
  value, as FTE's `Cvar_ApplyLatches`, and with `clear: true` take those flags off them
  all. Returns how many had a latched value.
  """
  @spec apply_latches(t(), flag() | [flag()], keyword()) :: non_neg_integer()
  def apply_latches(%__MODULE__{} = cvars, flags, opts \\ []) do
    bit = bits(List.wrap(flags))
    clear? = Keyword.get(opts, :clear, false)

    cvars
    |> rows()
    |> Enum.filter(&((elem(&1, @bits) &&& bit) != 0))
    |> Enum.count(&apply_latch(cvars, &1, bit, clear?))
  end

  @doc "Every variable's default becomes its value, unless read only or a cheat (FTE's `cvar_lockdefaults`)."
  @spec lock_defaults(t()) :: :ok
  def lock_defaults(%__MODULE__{} = cvars) do
    for row <- rows(cvars),
        (elem(row, @bits) &&& (@flags.noset ||| @flags.cheat)) == 0,
        elem(row, @string) != elem(row, @default),
        do: insert(cvars, put_elem(row, @default, elem(row, @string)))

    :ok
  end

  @doc "Every engine variable's default goes back to the engine's (FTE's `cvar_purgedefaults`); values stay."
  @spec purge_defaults(t()) :: :ok
  def purge_defaults(%__MODULE__{} = cvars) do
    for row <- rows(cvars),
        elem(row, @engine) != nil,
        (elem(row, @bits) &&& @flags.noset) == 0,
        elem(row, @default) != elem(row, @engine),
        do: insert(cvars, put_elem(row, @default, elem(row, @engine)))

    :ok
  end

  @doc """
  The defaults of engine variables go back to the engine's, as FTE's
  `cvar_resettodefaults_*`: `:all`, `:saved` (archived only) or `:unsaved`; read only and
  `:noreset` variables are left.
  """
  @spec reset_defaults(t(), :all | :saved | :unsaved) :: :ok
  def reset_defaults(%__MODULE__{} = cvars, which) do
    {mask, wanted} =
      case which do
        :saved -> {@flags.noreset ||| @flags.noset ||| @flags.archive, @flags.archive}
        :unsaved -> {@flags.noreset ||| @flags.noset ||| @flags.archive, 0}
        :all -> {@flags.noreset ||| @flags.noset, 0}
      end

    for row <- rows(cvars),
        elem(row, @engine) != nil,
        (elem(row, @bits) &&& mask) == wanted,
        elem(row, @default) != elem(row, @engine),
        do: insert(cvars, put_elem(row, @default, elem(row, @engine)))

    :ok
  end

  @doc """
  Set back to their defaults the variables whose names match `pattern` (`*` and `?`
  wildcards; `*` or `nil` is every one), as FTE's `cvarreset`. Options: `:group` (only
  variables of a group matching it), `alt: true` (second names match too), `:exclude`
  (flag names; variables with any are left). `:noreset` variables are left, as are read
  only ones when every variable is reset. Returns the lines printed.
  """
  @spec reset(t(), String.t() | nil, keyword()) :: [String.t()]
  def reset(%__MODULE__{} = cvars, pattern, opts \\ []) do
    filter = %{
      pattern: wildcard(pattern),
      group: wildcard(Keyword.get(opts, :group)),
      exclude: bits(Keyword.get(opts, :exclude, [])),
      alt: Keyword.get(opts, :alt, false)
    }

    cvars
    |> rows()
    |> Enum.filter(&resettable?(&1, filter))
    |> Enum.flat_map(fn row ->
      reset_to = elem(row, @default) || elem(row, @engine)
      pending = elem(row, @latched) || elem(row, @string)
      if reset_to && reset_to != pending, do: set_row(cvars, row, reset_to, false), else: []
    end)
  end

  @doc "Every variable, sorted by name."
  @spec list(t()) :: [Cvar.t()]
  def list(%__MODULE__{} = cvars),
    do: cvars |> rows() |> Enum.map(&to_cvar/1) |> Enum.sort_by(& &1.name)

  @doc "The server's info keys from its `:serverinfo` variables: every one with a value."
  @spec serverinfo(t()) :: %{String.t() => String.t()}
  def serverinfo(%__MODULE__{} = cvars), do: info(cvars, @flags.serverinfo)

  @doc "The player's info keys from the `:userinfo` variables: every one with a value."
  @spec userinfo(t()) :: %{String.t() => String.t()}
  def userinfo(%__MODULE__{} = cvars), do: info(cvars, @flags.userinfo)

  @doc "The variables flagged `:serverinfo` or `:userinfo`, as `{name, stamp}`."
  @spec info_stamps(t()) :: [{String.t(), integer()}]
  def info_stamps(%__MODULE__{table: table}) do
    bits = @flags.serverinfo ||| @flags.userinfo

    :ets.select(table, [
      {{:"$1", :"$2", :_, :_, :_, :_, :_, :"$3", :_, :_, :"$4", :_, :_},
       [{:is_binary, :"$1"}, {:"/=", {:band, :"$3", bits}, 0}], [{{:"$2", :"$4"}}]}
    ])
  end

  @doc """
  The variables as FTE's `cfg_save` writes them (`Cvar_WriteVariables`): the archived
  ones, or with `all?` every one but `cl_warncmd`; never read only or `:nosave` ones.
  Each group is headed by a `// group` line; an engine variable is written as `name
  "value"`, one a config or program made as `seta` or `set`, with its description after
  `//` at the next multiple of eight columns (at least 24), each of its lines so.
  """
  @spec archive_text(t(), boolean()) :: String.t()
  def archive_text(%__MODULE__{} = cvars, all? \\ false) do
    cvars
    |> rows()
    |> Enum.filter(&saved?(&1, all?))
    |> Enum.group_by(&elem(&1, @group))
    |> Enum.sort()
    |> Enum.map_join(fn {group, rows} ->
      "\n// " <>
        group <> "\n" <> Enum.map_join(Enum.sort_by(rows, &elem(&1, @name)), &archive_line/1)
    end)
  end

  @doc "Mark whether a server (`:server`) or the renderer (`:renderer`) is running, for the latching flags."
  @spec put_running(t(), :server | :renderer, boolean()) :: :ok
  def put_running(%__MODULE__{table: table}, what, running?) do
    :ets.insert(table, {{:state, what}, running?})
    :ok
  end

  @doc "Whether a server (`:server`) or the renderer (`:renderer`) is running."
  @spec running?(t(), :server | :renderer) :: boolean()
  def running?(%__MODULE__{table: table}, what),
    do: :ets.lookup_element(table, {:state, what}, 2, false)

  @doc "Whether an archived variable changed since the last save (FTE's `cvars_haveunsaved`)."
  @spec unsaved?(t()) :: boolean()
  def unsaved?(%__MODULE__{table: table}),
    do: :ets.lookup_element(table, {:state, :unsaved}, 2, false)

  @doc "Mark the archived variables saved."
  @spec saved(t()) :: :ok
  def saved(%__MODULE__{table: table}) do
    :ets.insert(table, {{:state, :unsaved}, false})
    :ok
  end

  @doc "The directory `cfg_save` writes configs to and `exec` reads them from first, or `nil`."
  @spec home(t()) :: Path.t() | nil
  def home(%__MODULE__{table: table}), do: :ets.lookup_element(table, {:state, :home}, 2, nil)

  @doc "Use `directory` as the place configs are written to and read from first."
  @spec put_home(t(), Path.t()) :: :ok
  def put_home(%__MODULE__{table: table}, directory) do
    :ets.insert(table, {{:state, :home}, directory})
    :ok
  end

  @doc "The console alias `name`'s commands, or `nil` when there is none."
  @spec command_alias(t(), String.t()) :: String.t() | nil
  def command_alias(%__MODULE__{table: table}, name),
    do: :ets.lookup_element(table, {:command_alias, name}, 3, nil)

  @doc "Make console alias `name` run `commands`, as FTE's `alias` command."
  @spec put_command_alias(t(), String.t(), String.t()) :: :ok
  def put_command_alias(%__MODULE__{table: table}, name, commands) do
    :ets.insert(table, {{:command_alias, name}, name, commands})
    :ok
  end

  @doc "Every console alias as `{name, commands}`, sorted by name."
  @spec command_aliases(t()) :: [{String.t(), String.t()}]
  def command_aliases(%__MODULE__{table: table}) do
    table
    |> :ets.match({{:command_alias, :_}, :"$1", :"$2"})
    |> Enum.map(fn [name, commands] -> {name, commands} end)
    |> Enum.sort()
  end

  @doc """
  The key binding of key number `keynum` in modifier state `modifier` (0 to 15, as
  `QuakeServer.Keys` numbers them) as `{command, level}`, or `nil` when it is unbound.
  """
  @spec binding(t(), integer(), non_neg_integer()) :: {String.t(), integer()} | nil
  def binding(%__MODULE__{table: table}, keynum, modifier) do
    case :ets.lookup(table, {:binding, keynum, modifier}) do
      [{_, command, level}] -> {command, level}
      [] -> nil
    end
  end

  @doc """
  Bind key number `keynum` in modifier state `modifier` to `command` at restriction
  `level`, or unbind it with `nil`; either way the configuration counts as changed
  (`unsaved?/1`).
  """
  @spec put_binding(t(), integer(), non_neg_integer(), String.t() | nil, integer()) :: :ok
  def put_binding(%__MODULE__{table: table} = cvars, keynum, modifier, command, level) do
    mark_unsaved(cvars)

    if command,
      do: :ets.insert(table, {{:binding, keynum, modifier}, command, level}),
      else: :ets.delete(table, {:binding, keynum, modifier})

    :ok
  end

  @doc "Every key binding as `{keynum, modifier, command, level}`, by key number then modifier."
  @spec bindings(t()) :: [{integer(), non_neg_integer(), String.t(), integer()}]
  def bindings(%__MODULE__{table: table}) do
    table
    |> :ets.match({{:binding, :"$1", :"$2"}, :"$3", :"$4"})
    |> Enum.map(fn [keynum, modifier, command, level] -> {keynum, modifier, command, level} end)
    |> Enum.sort()
  end

  @doc "The two modifier states key presses read their bindings from (FTE's `key_bindmaps`), `{0, 0}` at first."
  @spec bindmaps(t()) :: {non_neg_integer(), non_neg_integer()}
  def bindmaps(%__MODULE__{table: table}),
    do: :ets.lookup_element(table, {:state, :bindmaps}, 2, {0, 0})

  @doc "Set the two modifier states key presses read their bindings from."
  @spec put_bindmaps(t(), {non_neg_integer(), non_neg_integer()}) :: :ok
  def put_bindmaps(%__MODULE__{table: table}, {first, second}) do
    :ets.insert(table, {{:state, :bindmaps}, {first, second}})
    :ok
  end

  @doc "Text read as a number, as C's `atof`: leading spaces, a sign, digits, a point and an exponent; a 32-bit float."
  @spec c_atof(String.t()) :: float()
  def c_atof(text) do
    [sign, whole, fraction, exponent] =
      ~r/\A\s*([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?/
      |> Regex.run(text, capture: :all_but_first)
      |> Kernel.++(["", "", "", ""])
      |> Enum.take(4)

    digits = whole <> fraction

    scale =
      if exponent == "", do: 0, else: exponent |> String.to_integer() |> max(-60) |> min(60)

    magnitude =
      if digits == "",
        do: 0.0,
        else: String.to_integer(digits) * :math.pow(10, scale - byte_size(fraction))

    float32(if sign == "-", do: -magnitude, else: magnitude)
  end

  @doc "Text read as a number, as FTE's `Q_atof`: a 32-bit float."
  @spec atof(String.t()) :: float()
  def atof(text) do
    {sign, rest} = sign(String.trim_leading(text, " "))
    float32(sign * unsigned_float(rest))
  end

  @doc "Text read as a whole number, as FTE's `Q_atoi`."
  @spec atoi(String.t()) :: integer()
  def atoi(text) do
    {sign, rest} = sign(text)
    wrap32(sign * unsigned_int(rest))
  end

  @doc "A number as FTE's `Cvar_SetValue` writes it: six decimals, trailing zeros and point dropped."
  @spec format_number(number()) :: String.t()
  def format_number(value) do
    text = :erlang.float_to_binary(value / 1, decimals: 6)
    text |> String.trim_trailing("0") |> String.trim_trailing(".")
  end

  defp element(%__MODULE__{table: table}, name, index, default) do
    key = key(name)

    case :ets.lookup_element(table, key, index + 1, :none) do
      :none ->
        case :ets.lookup_element(table, {:alias, key}, 2, nil) do
          nil -> default
          target -> :ets.lookup_element(table, target, index + 1, default)
        end

      found ->
        found
    end
  end

  defp key(name), do: String.downcase(name, :ascii)

  defp row_key(%__MODULE__{table: table}, name) do
    key = key(name)

    cond do
      :ets.member(table, key) -> key
      target = :ets.lookup_element(table, {:alias, key}, 2, nil) -> target
      true -> nil
    end
  end

  defp row(%__MODULE__{table: table} = cvars, name) do
    case row_key(cvars, name) do
      nil -> nil
      key -> table |> :ets.lookup(key) |> List.first()
    end
  end

  defp rows(%__MODULE__{table: table}),
    do: :ets.select(table, [{:"$1", [{:is_binary, {:element, 1, :"$1"}}], [:"$1"]}])

  defp new_row(name, value, default, engine, bits, opts) do
    {key(name), name, value, atof(value), atoi(value), default, engine, bits, nil,
     Keyword.get(opts, :description), 0, Keyword.get(opts, :group, "Engine variables"),
     Keyword.get(opts, :alias)}
  end

  defp insert(%__MODULE__{table: table, generation: generation}, row) do
    row = put_elem(row, @stamp, System.unique_integer([:monotonic, :positive]))
    :ets.insert(table, row)
    :atomics.add(generation, 1, 1)
    to_cvar(row)
  end

  defp put_bits(cvars, row, bits) do
    insert(cvars, put_elem(row, @bits, bits))
    :ok
  end

  defp remember_alias(_cvars, nil, _key), do: :ok

  defp remember_alias(%__MODULE__{table: table}, alias_name, key) do
    :ets.insert(table, {{:alias, key(alias_name)}, key})
    :ok
  end

  defp to_cvar(row) do
    %Cvar{
      name: elem(row, @name),
      string: elem(row, @string),
      value: elem(row, @value),
      ival: elem(row, @ival),
      default: elem(row, @default),
      engine: elem(row, @engine),
      flags: elem(row, @bits),
      latched: elem(row, @latched),
      description: elem(row, @description),
      group: elem(row, @group),
      alias: elem(row, @alias)
    }
  end

  defp apply_latch(cvars, row, bit, clear?) do
    bits = elem(row, @bits)
    latched = elem(row, @latched)
    kept = if clear?, do: bits &&& bnot(bit), else: bits

    if latched do
      set_row(cvars, put_elem(row, @bits, bits &&& bnot(bit)), latched, false)
      insert(cvars, put_elem(row(cvars, elem(row, @name)), @bits, kept))
    else
      if clear?, do: insert(cvars, put_elem(row, @bits, kept))
    end

    latched != nil
  end

  defp set_row(cvars, row, nil, force?), do: set_row(cvars, row, elem(row, @default), force?)

  defp set_row(cvars, row, value, force?) do
    bits = elem(row, @bits)

    cond do
      (bits &&& @flags.noset) != 0 and not force? ->
        ["variable #{elem(row, @name)} is readonly\n"]

      message = not force? && latch_message(cvars, bits) ->
        latch(cvars, row, value, message)

      true ->
        change(cvars, row, value)
    end
  end

  defp latch_message(cvars, bits) do
    cond do
      (bits &&& @flags.maplatch) != 0 and running?(cvars, :server) ->
        "variable %s is latched and will be applied for the start of the next map\n"

      (bits &&& @flags.videolatch) != 0 and running?(cvars, :renderer) ->
        "variable %s will be changed after a vid_restart\n"

      (bits &&& @flags.rendererlatch) != 0 and running?(cvars, :renderer) ->
        "variable %s will be changed after a vid_reload\n"

      (bits &&& @flags.rendereroverride) != 0 and running?(cvars, :renderer) ->
        "variable %s is not supported by the current renderer/gpu/drivers\n"

      (bits &&& @flags.rulesetlatch) != 0 ->
        "variable %s is latched due to current ruleset\n"

      true ->
        nil
    end
  end

  defp latch(cvars, row, value, message) do
    latched = elem(row, @latched)
    shown = String.replace(message, "%s", elem(row, @name))

    prints =
      cond do
        latched != nil and latched != value -> [shown]
        latched == nil and elem(row, @string) != value -> [shown]
        true -> []
      end

    cond do
      latched == value ->
        []

      elem(row, @string) == value ->
        mark_unsaved(cvars)
        insert(cvars, put_elem(row, @latched, nil))
        warned(cvars, prints)

      true ->
        mark_unsaved(cvars)
        insert(cvars, put_elem(row, @latched, value))
        warned(cvars, prints)
    end
  end

  defp warned(cvars, prints), do: if(value(cvars, "cl_warncmd") != 0, do: prints, else: [])

  defp change(cvars, row, value) do
    cond do
      elem(row, @string) != value ->
        changed(cvars, row, value)

      elem(row, @latched) != nil ->
        insert(cvars, put_elem(row, @latched, nil))
        []

      true ->
        []
    end
  end

  defp changed(cvars, row, value) do
    bits = elem(row, @bits)

    insert(
      cvars,
      row
      |> put_elem(@string, value)
      |> put_elem(@value, atof(value))
      |> put_elem(@ival, atoi(value))
      |> put_elem(@latched, nil)
    )

    if (bits &&& @flags.archive) != 0 and (bits &&& @flags.serveroverride) == 0 and
         value(cvars, "cl_warncmd") != 0,
       do: mark_unsaved(cvars)

    case check(elem(row, @key), atof(value), value) do
      nil -> []
      forced -> set_row(cvars, row(cvars, elem(row, @name)), forced, true)
    end
  end

  defp check(key, number, text) when key in ["r_meshpitch", "r_meshroll"] do
    cond do
      text in ["-1", "1"] -> nil
      number <= 0 -> "-1"
      true -> "1"
    end
  end

  defp check("fov", number, _text) when number < 10, do: "10"
  defp check("viewsize", number, _text) when number < 30, do: "30"
  defp check("viewsize", number, _text) when number > 120, do: "120"
  defp check(_key, _number, _text), do: nil

  defp mark_unsaved(%__MODULE__{table: table}),
    do: :ets.insert(table, {{:state, :unsaved}, true})

  defp info(%__MODULE__{} = cvars, bit) do
    for row <- rows(cvars),
        (elem(row, @bits) &&& bit) != 0,
        elem(row, @string) != "",
        into: %{},
        do: {elem(row, @name), elem(row, @string)}
  end

  defp saved?(row, all?) do
    bits = elem(row, @bits)

    ((bits &&& @flags.archive) != 0 or (all? and elem(row, @key) != "cl_warncmd")) and
      (bits &&& (@flags.noset ||| @flags.nosave)) == 0
  end

  defp archive_line(row) do
    bits = elem(row, @bits)
    value = quoted(elem(row, @latched) || elem(row, @string))
    name = elem(row, @name)

    line =
      cond do
        (bits &&& @flags.usercreated) == 0 -> "#{name} #{value}"
        (bits &&& @flags.archive) != 0 -> "seta #{name} #{value}"
        true -> "set #{name} #{value}"
      end

    case elem(row, @description) do
      nil -> line <> "\n"
      "" -> line <> "\n"
      description -> described(line, description)
    end
  end

  defp described(line, description) do
    pad = max(Bitwise.band(byte_size(line) + 8, bnot(7)), 24)
    margin = String.duplicate(" ", pad) <> "//"

    String.pad_trailing(line, pad) <>
      "//" <> String.replace(description, "\n", "\n" <> margin) <> "\n"
  end

  defp quoted(text), do: "\"" <> String.replace(text, ["\\", "\""], &("\\" <> &1)) <> "\""

  defp wildcard(nil), do: nil
  defp wildcard("*"), do: nil
  defp wildcard(pattern), do: String.downcase(pattern, :ascii)

  defp resettable?(row, filter) do
    bits = elem(row, @bits)

    (bits &&& filter.exclude) == 0 and (bits &&& @flags.noreset) == 0 and
      not (filter.pattern == nil and (bits &&& @flags.noset) != 0) and
      (filter.group == nil or wild?(filter.group, String.downcase(elem(row, @group), :ascii))) and
      named?(row, filter)
  end

  defp named?(_row, %{pattern: nil}), do: true

  defp named?(row, %{pattern: pattern, alt: alt?}) do
    wild?(pattern, elem(row, @key)) or
      (alt? and elem(row, @alias) != nil and
         wild?(pattern, String.downcase(elem(row, @alias), :ascii)))
  end

  defp wild?(pattern, text), do: wild(String.to_charlist(pattern), String.to_charlist(text))

  defp wild([], []), do: true

  defp wild([?* | rest], text),
    do: wild(rest, text) or (text != [] and wild([?* | rest], tl(text)))

  defp wild([?? | rest], [_ | text]), do: wild(rest, text)
  defp wild([c | rest], [c | text]), do: wild(rest, text)
  defp wild(_pattern, _text), do: false

  defp valid_name?(""), do: false

  defp valid_name?(name),
    do: not String.contains?(name, ["\"", "^", "$", " ", "\t", "\r", "\n", ";"])

  defp sign("-" <> rest), do: {-1, rest}
  defp sign(rest), do: {1, rest}

  defp unsigned_float(<<"0", x, rest::binary>>) when x in [?x, ?X], do: hex(rest, 0)
  defp unsigned_float(<<"'", c, _::binary>>), do: c
  defp unsigned_float("'"), do: 0
  defp unsigned_float(text), do: decimal(text, 0, -1, 0)

  defp unsigned_int(<<"0", x, rest::binary>>) when x in [?x, ?X], do: hex(rest, 0)
  defp unsigned_int(<<"'", c, _::binary>>), do: c
  defp unsigned_int("'"), do: 0
  defp unsigned_int(text), do: digits(text, 0)

  defp hex(<<c, rest::binary>>, value) when c in ?0..?9, do: hex(rest, value * 16 + c - ?0)
  defp hex(<<c, rest::binary>>, value) when c in ?a..?f, do: hex(rest, value * 16 + c - ?a + 10)
  defp hex(<<c, rest::binary>>, value) when c in ?A..?F, do: hex(rest, value * 16 + c - ?A + 10)
  defp hex(_rest, value), do: value

  defp digits(<<c, rest::binary>>, value) when c in ?0..?9, do: digits(rest, value * 10 + c - ?0)
  defp digits(_rest, value), do: value

  defp decimal(<<".", rest::binary>>, value, _point, total),
    do: decimal(rest, value, total, total)

  defp decimal(<<c, rest::binary>>, value, point, total) when c in ?0..?9,
    do: decimal(rest, value * 10 + c - ?0, point, total + 1)

  defp decimal(_rest, value, -1, _total), do: value / 1
  defp decimal(_rest, value, point, total), do: shift_down(value / 1, total - point)

  defp shift_down(value, 0), do: value
  defp shift_down(value, places), do: shift_down(value / 10, places - 1)

  defp float32(value) do
    clamped = value |> max(-@float32_max) |> min(@float32_max)
    <<rounded::float-32>> = <<clamped::float-32>>
    rounded
  end

  defp wrap32(value) do
    <<wrapped::signed-32>> = <<value::signed-32>>
    wrapped
  end
end
