defmodule QuakeServer.Autocvars do
  @moduledoc """
  A program's `autocvar_<name>` globals kept equal to console variable `<name>`, and a
  server's info keys kept equal to its `:serverinfo` and `:userinfo` variables, as FTE
  keeps them (`PR_AutoCvar`, `Cvar_SetCore`).

      server = QuakeServer.Autocvars.sync(server)

  The host is a `QuakeServer.Server` (a server, a client program's world or a menu)
  holding a `QuakeServer.Cvars` table in `cvars`. The first `sync/1` of a program
  attaches it, as FTE does when a program loads: each `autocvar_` global (a float,
  integer, vector or string; not a float named like a vector's `_x`, `_y` or `_z`)
  names a variable, made when there is none with the global's own value as its default
  (`%g` for a float, `%i` for an integer, `%g %g %g` for a vector), and is given the
  variable's value; a variable programs may not read (`:nounsafeexpand`) is left out.
  On a server (one with player slots) every `:serverinfo` variable with a value becomes
  a server info key and every `:userinfo` one an info key of each player slot; one
  without a value removes its key.

  Every later `sync/1` whose table changed since the last brings every attached global
  and every info key up to date. A float global takes the variable's `value`, an integer
  its `ival`, a string its text (empty text the null string) and a vector the first
  three words of the text read as numbers. `QuakeServer.Server.exec_opts/1` runs
  `sync/1` before every call into a program, so a change made by any process holding
  the table reaches each program before it next runs.
  """

  alias QuakeServer.Cvars
  alias QuakeServer.Extensions.Settings

  @doc "Attach the host's program, or bring it up to date with its table; see the module documentation."
  @spec sync(map()) :: map()
  def sync(%{cvars: %Cvars{} = cvars, qc: %QuakeC{}, ext: ext} = host) do
    case Map.get(ext, :autocvars) do
      nil ->
        attach(host, cvars)

      %{seen: seen} = state ->
        generation = Cvars.generation(cvars)
        if generation == seen, do: host, else: refresh(host, cvars, state, generation)
    end
  end

  def sync(host), do: host

  @doc "A float as C's `%g` writes it: six significant digits, trailing zeros dropped."
  @spec format_g(number()) :: String.t()
  def format_g(value) when value == 0, do: "0"

  def format_g(value) do
    [mantissa, exponent] =
      (value / 1) |> :erlang.float_to_binary(scientific: 5) |> String.split("e")

    exponent = String.to_integer(exponent)

    if exponent < -4 or exponent >= 6,
      do: trim_zeros(mantissa) <> "e" <> exponent_text(exponent),
      else: (value / 1) |> :erlang.float_to_binary(decimals: 5 - exponent) |> trim_zeros()
  end

  defp attach(host, cvars) do
    generation = Cvars.generation(cvars)

    {host, globals} =
      host.qc.progs.global_defs
      |> Enum.filter(&autocvar?/1)
      |> Enum.sort_by(fn {_name, {_type, offset}} -> offset end)
      |> Enum.reduce({host, %{}}, &attach_global(&1, &2, cvars))

    state = %{globals: globals, info: %{}, seen: generation}
    host = %{host | ext: Map.put(host.ext, :autocvars, state)}
    refresh(host, cvars, state, generation)
  end

  defp autocvar?({"autocvar_" <> name, {type, _offset}})
       when type in [:vector, :integer, :string],
       do: name != ""

  defp autocvar?({"autocvar_" <> name, {:float, _offset}}),
    do: name != "" and not Regex.match?(~r/_[xyz]\z/, name)

  defp autocvar?(_def), do: false

  defp attach_global({"autocvar_" <> name, {type, offset}}, {host, globals}, cvars) do
    {default, host} = initial(host, type, offset)

    case Cvars.get(cvars, name, default, [], group: "autocvars") do
      nil ->
        {host, globals}

      cvar ->
        if Cvars.flag?(cvar, :nounsafeexpand) do
          {host, globals}
        else
          Cvars.add_flags(cvars, name, [:tellgamecode])
          key = String.downcase(name, :ascii)
          entry = Map.get(globals, key, %{name: name, places: [], stamp: nil})
          {host, Map.put(globals, key, %{entry | places: entry.places ++ [{offset, type}]})}
        end
    end
  end

  defp initial(host, :float, offset),
    do: {format_g(QuakeC.float(QuakeC.slot(host.qc, offset))), host}

  defp initial(host, :integer, offset),
    do: {Integer.to_string(int(QuakeC.slot(host.qc, offset))), host}

  defp initial(host, :vector, offset) do
    {x, y, z} = QuakeC.slot_vector(host.qc, offset)
    {Enum.map_join([x, y, z], " ", &format_g/1), host}
  end

  defp initial(host, :string, offset) do
    text = QuakeC.string(host.qc, QuakeC.slot(host.qc, offset))
    {text, %{host | qc: QuakeC.put_slot(host.qc, offset, 0)}}
  end

  defp refresh(host, cvars, state, generation) do
    {host, globals} =
      Enum.reduce(state.globals, {host, state.globals}, fn {key, entry}, {host, globals} ->
        case Cvars.stamp(cvars, entry.name) do
          stamp when stamp == entry.stamp ->
            {host, globals}

          stamp ->
            cvar = Cvars.fetch(cvars, entry.name)
            host = Enum.reduce(entry.places, host, &put_place(&2, &1, cvar))
            {host, Map.put(globals, key, %{entry | stamp: stamp})}
        end
      end)

    {host, info} = refresh_info(host, cvars, state.info)
    state = %{state | globals: globals, info: info, seen: generation}
    %{host | ext: Map.put(host.ext, :autocvars, state)}
  end

  defp put_place(host, _place, nil), do: host

  defp put_place(host, place, cvar) do
    if Cvars.flag?(cvar, :nounsafeexpand),
      do: host,
      else: %{host | qc: put_value(host.qc, place, cvar)}
  end

  defp put_value(qc, {offset, :float}, cvar), do: QuakeC.put_slot(qc, offset, cvar.value)
  defp put_value(qc, {offset, :integer}, cvar), do: QuakeC.put_slot(qc, offset, cvar.ival)
  defp put_value(qc, {offset, :string}, %{string: ""}), do: QuakeC.put_slot(qc, offset, 0)
  defp put_value(qc, {offset, :string}, cvar), do: QuakeC.put_slot(qc, offset, cvar.string)

  defp put_value(qc, {offset, :vector}, cvar),
    do: QuakeC.put_slot_vector(qc, offset, vector(cvar.string))

  defp refresh_info(%{slots: slots} = host, cvars, known) when slots > 0 do
    cvars
    |> Cvars.info_stamps()
    |> Enum.reduce({host, known}, fn {name, stamp}, {host, known} ->
      if Map.get(known, name) == stamp,
        do: {host, known},
        else: {put_info(host, Cvars.fetch(cvars, name)), Map.put(known, name, stamp)}
    end)
  end

  defp refresh_info(host, _cvars, known), do: {host, known}

  defp put_info(host, cvar) do
    host = if Cvars.flag?(cvar, :serverinfo), do: server_info(host, cvar), else: host

    if Cvars.flag?(cvar, :userinfo),
      do: Enum.reduce(1..host.slots//1, host, &user_info(&2, &1, cvar)),
      else: host
  end

  defp server_info(host, %{string: ""} = cvar) do
    host = Settings.put_info(host, 0, cvar.name, "")
    %{host | ext: Map.update(host.ext, :serverinfo, %{}, &Map.delete(&1, cvar.name))}
  end

  defp server_info(host, cvar), do: Settings.put_info(host, 0, cvar.name, cvar.string)

  defp user_info(host, entity, %{string: ""} = cvar) do
    userinfo = Map.get(host.ext, :userinfo, %{})
    player = userinfo |> Map.get(entity, %{}) |> Map.delete(cvar.name)
    %{host | ext: Map.put(host.ext, :userinfo, Map.put(userinfo, entity, player))}
  end

  defp user_info(host, entity, cvar), do: Settings.put_info(host, entity, cvar.name, cvar.string)

  defp vector(text) do
    words = String.split(text) ++ ["", "", ""]
    [x, y, z] = words |> Enum.take(3) |> Enum.map(&Cvars.c_atof/1)
    {x, y, z}
  end

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)
  defp int(_value), do: 0

  defp trim_zeros(text) do
    if String.contains?(text, "."),
      do: text |> String.trim_trailing("0") |> String.trim_trailing("."),
      else: text
  end

  defp exponent_text(exponent) when exponent < 0,
    do: "-" <> String.pad_leading(Integer.to_string(-exponent), 2, "0")

  defp exponent_text(exponent), do: "+" <> String.pad_leading(Integer.to_string(exponent), 2, "0")
end
