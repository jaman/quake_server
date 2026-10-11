defmodule QuakeServer.Extensions.Settings do
  @moduledoc """
  FTE's builtins about the engine around the program: console variables (`cvar`,
  `cvar_string`, `cvar_set`, `cvar_setf`, `registercvar`, `cvar_defstring`,
  `cvar_type`, `cvar_description`, `buf_cvarlist`, `cvars_haveunsaved`, as FTE's
  `pr_bgcmd.c` runs them on the host's `QuakeServer.Cvars` table), server and player info
  keys, which extensions and functions exist, calling functions by name, the time,
  printing, console commands, registered stats, and the kinds of client.

  `registercvar(name, value, flags)` takes the value only when given flags too, as FTE
  reads its arguments; DarkPlaces flag bits 16 (cheat), 32 (archive), 256 (server
  info), 512 (user info) and 2048 (private) are taken, any other is warned about.
  `cvar_type` gives FTE's bits: 1 there, 2 archived, 4 private, 8 the engine's, 16 has
  a description, 32 read only.

  `readcmd` runs the console commands queued so far, then its text, and returns what
  they printed, kept off the console, followed by `PF_readcmd: ` and the text, as FTE's
  redirected console gives it.

  Info keys live in the host's `ext.serverinfo` and `ext.userinfo` (by entity), stats in
  `ext.stats`, registered commands in `ext.commands`.
  """

  alias QuakeC.Exec
  alias QuakeServer.{Args, Cvars, Edicts, Events, Outbox, Server}
  alias QuakeServer.Extensions.Strings

  @extensions ~w(
    DP_QC_CVAR_STRING DP_QC_EDICT_NUM DP_QC_FINDCHAIN DP_QC_FINDCHAINFLAGS DP_QC_FINDCHAINFLOAT
    DP_QC_FINDFLAGS DP_QC_FINDFLOAT DP_QC_FS_SEARCH DP_QC_MINMAXBOUND DP_QC_SINCOSSQRTPOW
    DP_QC_SPRINTF DP_QC_STRINGBUFFERS DP_QC_STRING_CASE_FUNCTIONS DP_QC_STRREPLACE
    DP_QC_TOKENIZEBYSEPARATOR DP_QC_TRACEBOX DP_QC_VECTORVECTORS DP_SV_POINTSOUND
    DP_SV_PRINT FRIK_FILE FTE_FORCEINFOKEY FTE_MEMALLOC FTE_QC_CHECKPVS FTE_QC_HASHTABLES
    FTE_QC_INTCONV FTE_STRINGS KRIMZON_SV_PARSECLIENTCOMMAND QW_ENGINE ZQ_QC_STRINGS
  )

  @doc "Whether `name` is one of the extensions `checkextension` (99) reports, ignoring ASCII case, as FTE's menu program checks."
  @spec extension?(String.t()) :: boolean()
  def extension?(name) do
    lower = String.downcase(name, :ascii)
    Enum.any?(@extensions, &(String.downcase(&1, :ascii) == lower))
  end

  @doc "Run settings builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 45, _argc), do: Args.return(s, cvar_value(s, Args.str(s, 0)))

  def call(s, 448, _argc) do
    case readable(s, Args.str(s, 0)) do
      nil -> Args.return(s, 0)
      cvar -> Args.return(s, cvar.latched || cvar.string)
    end
  end

  def call(s, 72, _argc), do: set_cvar(s, Args.str(s, 0), Args.str(s, 1))
  def call(s, 176, _argc), do: set_cvar(s, Args.str(s, 0), Cvars.format_number(Args.num(s, 1)))
  def call(s, 93, argc), do: register_cvar(s, argc)

  def call(s, 482, _argc) do
    case readable(s, Args.str(s, 0)) do
      nil -> Args.return(s, 0)
      cvar -> Args.return(s, cvar.default)
    end
  end

  def call(s, 495, _argc), do: Args.return(s, cvar_type(Cvars.fetch(s.cvars, Args.str(s, 0))) / 1)

  def call(s, 518, _argc) do
    case readable(s, Args.str(s, 0)) do
      %{description: description} when is_binary(description) -> Args.return(s, description)
      _ -> Args.return(s, 0)
    end
  end

  def call(s, 517, _argc), do: cvar_list(s, Args.int(s, 0), Args.str(s, 1), Args.str(s, 2))

  def call(s, "cvars_haveunsaved", _argc),
    do: Args.return(s, if(Cvars.unsaved?(s.cvars), do: 1.0, else: 0.0))

  def call(s, 354, argc) do
    key = Enum.map_join(0..(max(argc, 1) - 1), &Args.str(s, &1))

    case server_key(s, key) do
      "" -> Args.return(s, 0)
      text -> Args.return(s, text)
    end
  end

  def call(s, "serverkeyfloat", argc) do
    case server_key(s, Args.str(s, 0)) do
      "" -> Args.return(s, Args.num(s, 1, argc, 0.0))
      text -> Args.return(s, Strings.number(text))
    end
  end

  def call(s, 80, _argc), do: Args.return(s, info(s, Args.int(s, 0), Args.str(s, 1)))

  def call(s, "infokeyf", _argc),
    do: Args.return(s, Strings.number(info(s, Args.int(s, 0), Args.str(s, 1))))

  def call(s, 213, _argc) do
    entity = Args.int(s, 0)
    key = Args.str(s, 1)
    value = Args.str(s, 2)
    put_info(s, entity, key, value)
  end

  def call(s, 99, _argc), do: Args.return(s, Args.str(s, 0) in @extensions)

  def call(s, "checkbuiltin", _argc),
    do: Args.return(s, builtin_known?(s, builtin_of(s, Args.slot(s, 0))))

  def call(s, 607, _argc),
    do: Args.return(s, QuakeC.Progs.find_function(s.qc.progs, Args.str(s, 0)) != nil)

  def call(s, 605, argc) do
    name = Args.str(s, max(argc - 1, 0))

    case QuakeC.Progs.find_function(s.qc.progs, name) do
      nil -> Args.return(s, 0)
      index -> Exec.call(s, index, s.builtins, Server.exec_opts(s))
    end
  end

  def call(s, 202, _argc) do
    s
    |> Events.print(:notify, "addprogs #{Args.str(s, 0)}: one program per server\n")
    |> Args.return(-1.0)
  end

  def call(s, 203, argc) do
    name = Enum.map_join(1..max(argc - 1, 1)//1, &Args.str(s, &1))
    if this_program?(Args.int(s, 0)), do: extern_value(s, name), else: Args.return(s, 0)
  end

  def call(s, 204, argc) do
    name = Enum.map_join(2..max(argc - 1, 2)//1, &Args.str(s, &1))

    case this_program?(Args.int(s, 0)) && global_type(s, name) do
      :vector -> %{s | qc: QuakeC.put_global(s.qc, name, Args.vec(s, 1))}
      nil -> s
      false -> s
      _type -> %{s | qc: QuakeC.put_global(s.qc, name, Args.slot(s, 1))}
    end
  end

  def call(s, 519, argc) do
    kind = trunc(Args.num(s, 0, argc, 0.0))
    seconds = if kind == 0, do: s.time, else: System.monotonic_time(:microsecond) / 1_000_000
    Args.return(s, seconds / 1)
  end

  def call(s, 339, argc),
    do: Events.print(s, :notify, Enum.map_join(0..(max(argc, 1) - 1), &Args.str(s, &1)))

  def call(s, 352, _argc) do
    name = Args.str(s, 0)

    %{s | ext: Map.update(s.ext, :commands, MapSet.new([name]), &MapSet.put(&1, name))}
    |> Args.return(true)
  end

  def call(s, 440, _argc), do: client_command(s, Args.int(s, 0), Args.str(s, 1))

  def call(s, "readcmd", _argc), do: read_command(s, Args.str(s, 0))

  def call(s, 79, _argc), do: s
  def call(s, 531, _argc), do: %{s | ext: Map.put(s.ext, :paused, Args.num(s, 0) != 0)}

  def call(s, builtin, _argc) when builtin in [232, 233, "pointerstat"] do
    stat = %{number: Args.int(s, 0), type: Args.int(s, 1), source: Args.slot(s, 2), kind: builtin}
    %{s | ext: Map.update(s.ext, :stats, [stat], &(&1 ++ [stat]))}
  end

  def call(s, 455, _argc), do: Args.return(s, if(Args.int(s, 0) == 1, do: 1.0, else: 0.0))
  def call(s, 453, _argc), do: Server.emit(s, {:drop, Args.int(s, 0)})
  def call(s, 454, _argc), do: Args.return(s, 0)

  def call(s, 478, argc) do
    utc? = Args.num(s, 0) == 0
    format = Args.str(s, 1, argc, "")
    now = if utc?, do: :calendar.universal_time(), else: :calendar.local_time()
    Args.return(s, strftime(format, now))
  end

  @doc """
  Server key `key` as a client program reads it (`PF_cl_serverkey_internal`): `ip`
  `loopback`, `servername` `local`, `constate` `active`, `pausestate` `1` or `0` by the
  host's `ext.paused`, `maxplayers` `1`, `protocol` `QuakeWorld FTE`, `transferring` and
  `dlstate` empty, `loadstate` `0 0 0 ""`; any other key from the server's info.
  """
  @spec server_key(map(), String.t()) :: String.t()
  def server_key(_s, "ip"), do: "loopback"
  def server_key(_s, "servername"), do: "local"
  def server_key(_s, "constate"), do: "active"
  def server_key(s, "pausestate"), do: if(Map.get(s.ext, :paused, false), do: "1", else: "0")
  def server_key(_s, "maxplayers"), do: "1"
  def server_key(_s, "protocol"), do: "QuakeWorld FTE"
  def server_key(_s, key) when key in ["transferring", "dlstate"], do: ""
  def server_key(_s, "loadstate"), do: "0 0 0 \"\""
  def server_key(s, key), do: info(s, 0, key)

  @doc "The server's info keys as an info string, `\\key\\value` for each."
  @spec info_string(map()) :: String.t()
  def info_string(s) do
    s.ext
    |> Map.get(:serverinfo, %{})
    |> Enum.sort()
    |> Enum.map_join(fn {key, value} -> "\\" <> key <> "\\" <> value end)
  end

  @doc """
  Console variable `name` as a program reads it (FTE's `PF_Cvar_FindOrGet`): made when
  there is none and `pr_autocreatecvars` is set (empty, or `sv_maxairspeed` 30 and
  `sv_jumpvelocity` 270), `nil` when it is not there or programs may not read it
  (`:nounsafeexpand`).
  """
  @spec readable(map(), String.t()) :: QuakeServer.Cvars.Cvar.t() | nil
  def readable(s, name) do
    cvar = found_or_made(s.cvars, name)
    if cvar && not Cvars.flag?(cvar, :nounsafeexpand), do: cvar
  end

  @doc """
  Console variable `name` as a server program's `cvar` reads it: `pr_checkextension` is
  `checkextension`'s builtin number (0 when the variable is set to 0),
  `pr_builtin_find` and `pr_map_builtin` 0, `halflifebsp` 1 on a Half-Life map; any
  other name its value as `readable/2` finds it, 0 when there is none.
  """
  @spec cvar_value(map(), String.t()) :: float()
  def cvar_value(%{slots: slots} = s, "pr_checkextension") when slots > 0 do
    case Cvars.fetch(s.cvars, "pr_checkextension") do
      %{ival: 0} -> 0.0
      _ -> 99.0
    end
  end

  def cvar_value(%{slots: slots}, name)
      when slots > 0 and name in ["pr_builtin_find", "pr_map_builtin"],
      do: 0.0

  def cvar_value(%{slots: slots} = s, "halflifebsp") when slots > 0,
    do: if(match?(%{game: :half_life}, s.bsp), do: 1.0, else: 0.0)

  def cvar_value(s, name) do
    case readable(s, name) do
      nil -> 0.0
      cvar -> cvar.value
    end
  end

  @doc """
  Set console variable `name` to `value` as a program's `cvar_set` does: made when there
  is none (`readable/2`), and left alone when no program may set it
  (`:notfromserver`).
  """
  @spec set_cvar(map(), String.t(), String.t()) :: map()
  def set_cvar(s, name, value) do
    case found_or_made(s.cvars, name) do
      nil -> s
      cvar -> if Cvars.flag?(cvar, :notfromserver), do: s, else: Server.put_cvar(s, name, value)
    end
  end

  @doc "Info key `key` of `entity`: the server's for the world, a player's own otherwise; `\"\"` when unset."
  @spec info(map(), non_neg_integer(), String.t()) :: String.t()
  def info(s, 0, key), do: s.ext |> Map.get(:serverinfo, %{}) |> Map.get(key, "")

  def info(s, entity, key) do
    case key do
      "name" ->
        s.ext
        |> Map.get(:userinfo, %{})
        |> Map.get(entity, %{})
        |> Map.get("name", Edicts.string(s, entity, "netname"))

      _ ->
        s.ext |> Map.get(:userinfo, %{}) |> Map.get(entity, %{}) |> Map.get(key, "")
    end
  end

  @doc """
  Set info key `key` of `entity` (the world for the server's own). A change to the
  server's own goes to every player reliably as `svc_serverinfo` (52, the key and value
  as strings).
  """
  @spec put_info(map(), non_neg_integer(), String.t(), String.t()) :: map()
  def put_info(s, 0, key, value) do
    changed? = info(s, 0, key) != value
    s = %{s | ext: Map.update(s.ext, :serverinfo, %{key => value}, &Map.put(&1, key, value))}

    if changed?,
      do:
        Enum.reduce(
          Outbox.players(s),
          s,
          &Outbox.reliable(&2, &1, <<52>> <> key <> <<0>> <> value <> <<0>>)
        ),
      else: s
  end

  def put_info(s, entity, key, value) do
    userinfo = Map.get(s.ext, :userinfo, %{})
    player = userinfo |> Map.get(entity, %{}) |> Map.put(key, value)
    %{s | ext: Map.put(s.ext, :userinfo, Map.put(userinfo, entity, player))}
  end

  defp found_or_made(cvars, name) do
    cond do
      cvar = Cvars.fetch(cvars, name) ->
        cvar

      Cvars.value(cvars, "pr_autocreatecvars") != 0 ->
        Cvars.get(cvars, name, implicit(name), [], group: "Implicit QC variables")

      true ->
        nil
    end
  end

  defp implicit("sv_maxairspeed"), do: "30"
  defp implicit("sv_jumpvelocity"), do: "270"
  defp implicit(_name), do: ""

  defp register_cvar(s, argc) do
    name = Args.str(s, 0)
    value = if argc > 2, do: Args.str(s, 1), else: ""
    {flags, unknown} = dp_flags(if(argc > 2, do: trunc(Args.num(s, 2)), else: 0))

    s =
      if unknown != 0,
        do:
          Events.print(
            s,
            :notify,
            "WARNING: Unknown flags passed to registercvar(\"#{name}\", \"#{value}\", #{Integer.to_string(unknown, 16) |> String.downcase()})\n"
          ),
        else: s

    cond do
      Cvars.exists?(s.cvars, name) ->
        Args.return(s, 0.0)

      Cvars.get(s.cvars, name, value, [:usercreated | flags], group: "QC created vars") ->
        s |> QuakeServer.Autocvars.sync() |> Args.return(1.0)

      true ->
        Args.return(s, 0.0)
    end
  end

  defp dp_flags(bits) do
    known = [
      {16, :cheat},
      {32, :archive},
      {256, :serverinfo},
      {512, :userinfo},
      {2048, :nounsafeexpand}
    ]

    Enum.reduce(known, {[], bits}, fn {bit, flag}, {flags, left} ->
      if Bitwise.band(left, bit) != 0,
        do: {[flag | flags], Bitwise.band(left, Bitwise.bnot(bit))},
        else: {flags, left}
    end)
  end

  defp cvar_type(nil), do: 0

  defp cvar_type(cvar) do
    [
      {true, 1},
      {Cvars.flag?(cvar, :archive), 2},
      {Cvars.flag?(cvar, :notfromserver) or Cvars.flag?(cvar, :nounsafeexpand), 4},
      {not Cvars.flag?(cvar, :usercreated), 8},
      {cvar.description != nil, 16},
      {Cvars.flag?(cvar, :noset) or Cvars.flag?(cvar, :rendereroverride), 32}
    ]
    |> Enum.reduce(0, fn {on?, bit}, acc -> if on?, do: acc + bit, else: acc end)
  end

  defp cvar_list(s, handle, pattern, antipattern) do
    case s.ext |> Map.get(:buffers, %{}) |> Map.fetch(handle) do
      {:ok, _old} ->
        names =
          s.cvars
          |> Cvars.list()
          |> Enum.map(& &1.name)
          |> Enum.filter(&listed?(&1, pattern, antipattern))
          |> Enum.sort()
          |> Enum.with_index()
          |> Map.new(fn {name, index} -> {index, name} end)

        %{s | ext: Map.update!(s.ext, :buffers, &Map.put(&1, handle, names))}

      :error ->
        s
    end
  end

  defp listed?(name, pattern, antipattern) do
    (pattern == "" or matches?(pattern, name)) and
      (antipattern == "" or not matches?(antipattern, name))
  end

  defp matches?(pattern, name) do
    if String.contains?(pattern, ["*", "?"]),
      do: wild(String.to_charlist(pattern), String.to_charlist(name)),
      else: String.starts_with?(name, pattern)
  end

  defp wild([], []), do: true

  defp wild([?* | rest], text),
    do: wild(rest, text) or (text != [] and wild([?* | rest], tl(text)))

  defp wild([?? | rest], [_ | text]), do: wild(rest, text)
  defp wild([c | rest], [c | text]), do: wild(rest, text)
  defp wild(_pattern, _text), do: false

  defp builtin_of(s, value)
       when is_integer(value) and value > 0 and value < tuple_size(s.qc.progs.functions) do
    case elem(s.qc.progs.functions, value) do
      %{first: 0, name: name} -> name
      %{first: first} when first < 0 -> -first
      _ -> nil
    end
  end

  defp builtin_of(_s, _value), do: nil

  defp builtin_known?(_s, nil), do: false

  defp builtin_known?(%{builtins: builtins}, builtin)
       when is_atom(builtins) and builtins != nil do
    if Code.ensure_loaded?(builtins) and function_exported?(builtins, :known?, 1),
      do: builtins.known?(builtin),
      else: QuakeServer.Extensions.known?(builtin)
  end

  defp builtin_known?(_s, builtin), do: QuakeServer.Extensions.known?(builtin)

  defp read_command(s, text) do
    s = QuakeServer.Console.flush(s)
    earlier = length(s.events)
    s = QuakeServer.Console.run(s, text)
    {added, old} = Enum.split(s.events, length(s.events) - earlier)
    {printed, others} = Enum.split_with(added, &match?({:print, _, _}, &1))
    output = printed |> Enum.reverse() |> Enum.map_join(fn {:print, _, line} -> line end)
    Args.return(%{s | events: others ++ old}, output <> "PF_readcmd: " <> text <> "\n")
  end

  defp client_command(s, entity, text) do
    case String.split(text) do
      ["kill" | _] ->
        s |> Server.set_globals(entity, 0) |> Server.call_named("ClientKill")

      [command | _] ->
        Events.print(
          s,
          :notify,
          "#{Edicts.string(s, entity, "netname")}: unknown command \"#{command}\"\n"
        )

      [] ->
        s
    end
  end

  defp strftime(format, datetime) do
    Regex.replace(~r/%(.)/, format, fn _, code -> format_code(code, datetime) end)
  end

  defp format_code("Y", {{year, _, _}, _}), do: Integer.to_string(year)
  defp format_code("y", {{year, _, _}, _}), do: pad_two(rem(year, 100))
  defp format_code("m", {{_, month, _}, _}), do: pad_two(month)
  defp format_code("d", {{_, _, day}, _}), do: pad_two(day)
  defp format_code("H", {_, {hour, _, _}}), do: pad_two(hour)
  defp format_code("M", {_, {_, minute, _}}), do: pad_two(minute)
  defp format_code("S", {_, {_, _, second}}), do: pad_two(second)
  defp format_code("%", _datetime), do: "%"
  defp format_code(other, _datetime), do: "%" <> other

  defp pad_two(number), do: String.pad_leading(Integer.to_string(number), 2, "0")

  defp this_program?(number), do: number in -3..0

  defp extern_value(s, "&" <> name) do
    case Map.get(s.qc.global_offsets, name) do
      nil -> Args.return(s, 0)
      offset -> Args.return(s, offset * 4)
    end
  end

  defp extern_value(s, name) do
    case global_type(s, name) do
      :vector -> Args.return(s, QuakeC.global_vector(s.qc, name))
      nil -> Args.return(s, QuakeC.Progs.find_function(s.qc.progs, name) || 0)
      _type -> Args.return(s, QuakeC.global(s.qc, name))
    end
  end

  defp global_type(s, name) do
    case Map.get(s.qc.progs.global_defs, name) do
      {type, _offset} -> type
      nil -> nil
    end
  end
end
