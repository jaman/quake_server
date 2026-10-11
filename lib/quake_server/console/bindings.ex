defmodule QuakeServer.Console.Bindings do
  @moduledoc """
  FTE's key bindings (`keys.c`): the console's `bind`, `in_bind`, `bindlevel`, `unbind`
  and `unbindall`, and the lookups the client and menu programs make, kept in the
  host's `QuakeServer.Cvars` table (`QuakeServer.Cvars.binding/3`) so every holder of it
  shares them.

      server = QuakeServer.Console.run(server, "bind w +forward; bind ctrl+q quit")
      QuakeServer.Console.Bindings.get(server.cvars, ?w, 0, 0)
      #=> "+forward"

  Keys are named and numbered as `QuakeServer.Keys` names and numbers them. A binding
  made with no modifier in the key's name holds for every modifier state but the bind
  maps; `unbind` with no modifier clears the bind maps too. `bind key` alone prints the
  binding. `in_bind map key command` binds in bind map `map` (1 to 8). `bindlevel key
  level command` binds at restriction level `level`. A binding is made at the level of
  the command that made it: 29 for the console (`:local`), 31 for the server.
  """

  import Bitwise

  alias QuakeServer.{Cvars, Events, Keys, Server}

  @altbindmap 8
  @states 16
  @local 29
  @insecure 30
  @server 31

  @doc "The console's binding commands."
  @spec commands() :: [String.t()]
  def commands, do: ~w(bind in_bind bindlevel unbind unbindall)

  @doc "Run binding command `name` (one of `commands/0`) from the console (`:local`) or the server."
  @spec command(Server.t(), String.t(), [tuple()], String.t(), :local | :server) :: Server.t()
  def command(%Server{cvars: nil} = server, _name, _tokens, _line, _from), do: server

  def command(server, "unbindall", _tokens, _line, from) do
    for keynum <- 0..(Keys.max() - 1), do: set(server.cvars, keynum, :all, nil, level(from))
    server
  end

  def command(server, "unbind", tokens, _line, from) do
    case words(tokens) do
      [_, key] -> unbind(server, key, from)
      _ -> Events.print(server, :notify, "unbind <key> : remove commands from a key\n")
    end
  end

  def command(server, "in_bind", tokens, line, from) do
    case tokens do
      [_ | [{map, _, _} | rest]] ->
        bind(server, "in_bind", rest, line, from, leading_integer(map))

      _ ->
        bind(server, "in_bind", [], line, from, 0)
    end
  end

  def command(server, name, [_ | rest], line, from), do: bind(server, name, rest, line, from, 0)

  @doc """
  The command bound to key number `keynum` (FTE's `Key_GetBinding`): with `bindmap`
  below 0 the binding of the first then second current bind map (`Cvars.bindmaps/1`);
  with `bindmap` 1 to 8 that bind map's; otherwise modifier state `modifier`'s. `nil`
  when unbound.
  """
  @spec get(Cvars.t(), integer(), integer(), integer()) :: String.t() | nil
  def get(cvars, keynum, bindmap, modifier) do
    cond do
      keynum < 0 or keynum >= Keys.max() ->
        nil

      bindmap < 0 ->
        {first, second} = Cvars.bindmaps(cvars)
        command(cvars, keynum, first) || command(cvars, keynum, second)

      bindmap > 0 ->
        command(cvars, keynum, bindmap - 1 + @altbindmap)

      modifier >= 0 and modifier < @states ->
        command(cvars, keynum, modifier)

      true ->
        nil
    end
  end

  @doc """
  Bind key number `keynum` to `command` (or unbind it with `nil`) in modifier state
  `modifier` at restriction `level` (FTE's `Key_SetBinding`); `:all` binds every state
  but the bind maps, or unbinds every state.
  """
  @spec set(Cvars.t(), integer(), Keys.modifier(), String.t() | nil, integer()) :: :ok
  def set(cvars, keynum, :all, nil, level) do
    Enum.each(0..(@states - 1), &set(cvars, keynum, &1, nil, level))
  end

  def set(cvars, keynum, :all, command, level) do
    Enum.each(0..(@altbindmap - 1), &set(cvars, keynum, &1, command, level))
  end

  def set(cvars, keynum, modifier, command, level) do
    if keynum >= 0 and keynum < Keys.max() and modifier in 0..(@states - 1),
      do: Cvars.put_binding(cvars, keynum, modifier, command, level),
      else: :ok
  end

  @doc """
  Up to `count` keys bound to `command` (a binding matches when it starts with the
  command followed by its end, a space or `;`), as `{keynum, modifier}` in key order
  (FTE's `M_FindKeysForBind`): bind map `bindmap` (1 to 8) only, or else the eight
  modifier states, skipping a modified state bound the same as a state with fewer of
  its modifiers.
  """
  @spec find(Cvars.t(), integer(), String.t(), pos_integer()) :: [{integer(), integer()}]
  def find(cvars, bindmap, command, count) do
    states =
      if bindmap > 0 and bindmap <= @altbindmap,
        do: [bor(bindmap - 1, @altbindmap)],
        else: Enum.to_list(0..(@altbindmap - 1))

    by_key = cvars |> Cvars.bindings() |> Enum.group_by(&elem(&1, 0))

    by_key
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(fn keynum ->
      bound = Map.new(by_key[keynum], fn {_, modifier, text, _} -> {modifier, text} end)

      for modifier <- states,
          text = bound[modifier],
          text != nil,
          matches?(text, command),
          not redundant?(bound, states, modifier, text),
          do: {keynum, modifier}
    end)
    |> Enum.take(count)
  end

  @doc """
  The bindings as `bind`, `bindlevel` and `in_bind` lines for a config (FTE's
  `Key_WriteBindings`): each key's unmodified binding, then each modifier state bound
  differently from it, then its bind maps.
  """
  @spec write(Cvars.t()) :: String.t()
  def write(cvars) do
    by_key = cvars |> Cvars.bindings() |> Enum.group_by(&elem(&1, 0))

    by_key
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map_join(fn keynum ->
      bound =
        Map.new(by_key[keynum], fn {_, modifier, text, level} -> {modifier, {text, level}} end)

      key_lines(keynum, bound)
    end)
  end

  defp key_lines(keynum, bound) do
    {base, base_level} = Map.get(bound, 0, {"", @local})

    states =
      for modifier <- 0..(@altbindmap - 1),
          {text, level} = Map.get(bound, modifier, {"", base_level}),
          text != base or (modifier == 0 and Map.has_key?(bound, 0)) or level != base_level,
          into: "",
          do: state_line(keynum, modifier, text, level)

    maps =
      for map <- 0..(@altbindmap - 1),
          {text, _level} = Map.get(bound, bor(map, @altbindmap), {"", 0}),
          text != "",
          into: "",
          do: "in_bind #{map + 1} #{map_key(keynum)} #{quoted(text)}\n"

    states <> maps
  end

  defp state_line(keynum, modifier, text, level) do
    name = Keys.keynum_to_string(keynum, modifier)

    name =
      if keynum == ?; or keynum <= ?\s or String.contains?(name, [" ", "+", "\""]),
        do: quoted(name),
        else: name

    if level != @local,
      do: "bindlevel #{name} #{level} #{quoted(text)}\n",
      else: "bind #{name} #{quoted(text)}\n"
  end

  defp map_key(keynum) do
    name = Keys.keynum_to_string(keynum, 0)
    if keynum == ?; or keynum <= ?\s or keynum == ?", do: quoted(name), else: name
  end

  defp quoted(text) do
    if String.contains?(text, ["\"", "\n", "\r"]),
      do: "\\\"" <> escaped(text, "") <> "\"",
      else: "\"" <> text <> "\""
  end

  defp escaped(<<>>, acc), do: acc
  defp escaped(<<?\n, rest::binary>>, acc), do: escaped(rest, acc <> "\\n")
  defp escaped(<<?\r, rest::binary>>, acc), do: escaped(rest, acc <> "\\r")
  defp escaped(<<?\t, rest::binary>>, acc), do: escaped(rest, acc <> "\\t")

  defp escaped(<<char, rest::binary>>, acc) when char in [?', ?", ?\\, ?$],
    do: escaped(rest, acc <> <<?\\, char>>)

  defp escaped(<<char, rest::binary>>, acc), do: escaped(rest, acc <> <<char>>)

  defp matches?(text, command) do
    size = byte_size(command)

    case text do
      <<^command::binary-size(^size)>> -> true
      <<^command::binary-size(^size), next, _::binary>> -> next in [?\s, ?;]
      _ -> false
    end
  end

  defp redundant?(bound, states, modifier, text) do
    Enum.any?(states, fn earlier ->
      earlier < modifier and band(earlier, bnot(modifier)) == 0 and bound[earlier] == text
    end)
  end

  defp command(cvars, keynum, modifier) do
    case Cvars.binding(cvars, keynum, modifier) do
      {text, _level} -> text
      nil -> nil
    end
  end

  defp unbind(server, key, from) do
    case Keys.string_to_keynum(key) do
      {-1, _} ->
        warn(server, "\"#{key}\" isn't a valid key\n")

      {keynum, modifier} ->
        set(server.cvars, keynum, modifier, nil, level(from))
        server
    end
  end

  defp bind(server, name, args, line, from, bindmap) do
    level? = name == "bindlevel"

    case args do
      [] ->
        usage(server, name, level?)

      [_] when level? ->
        usage(server, name, level?)

      [{key, _, _} | rest] ->
        bind_key(server, Keys.string_to_keynum(key), key, rest, line, from, {level?, bindmap})
    end
  end

  defp usage(server, name, level?) do
    Events.print(
      server,
      :notify,
      "#{name} <key> #{if level?, do: "<level> ", else: ""}[command] : attach a command to a key\n"
    )
  end

  defp bind_key(server, {-1, _}, key, _rest, _line, _from, _how),
    do: warn(server, "\"#{key}\" isn't a valid key\n")

  defp bind_key(server, {keynum, modifier}, key, rest, line, from, {level?, bindmap}) do
    {level, rest} = if level?, do: chosen_level(rest, from), else: {level(from), rest}

    with {:ok, modifier} <- in_map(modifier, bindmap) do
      put(server, keynum, modifier, key, rest, line, level)
    else
      {:error, text} -> warn(server, text)
    end
  end

  defp in_map(modifier, 0), do: {:ok, modifier}

  defp in_map(_modifier, bindmap) when bindmap <= 0 or bindmap > @altbindmap,
    do: {:error, "unsupported bindmap #{bindmap}\n"}

  defp in_map(:all, bindmap), do: {:ok, bor(bindmap - 1, @altbindmap)}
  defp in_map(_modifier, _bindmap), do: {:error, "modifiers cannot be combined with bindmaps\n"}

  defp chosen_level([{text, _, _} | rest], from) do
    level =
      cond do
        from == :server -> level(from)
        leading_integer(text) > 29 -> @insecure
        true -> text |> leading_integer() |> max(1) |> min(level(from))
      end

    {level, rest}
  end

  defp put(server, keynum, modifier, key, [], _line, level),
    do: show(server, keynum, modifier, key, level)

  defp put(server, keynum, modifier, _key, [{text, _, _}], _line, level) do
    set(server.cvars, keynum, modifier, text, level)
    server
  end

  defp put(server, keynum, modifier, _key, [{_, start, _} | _] = rest, line, level) do
    {_, _, stop} = List.last(rest)
    set(server.cvars, keynum, modifier, binary_part(line, start, stop - start), level)
    server
  end

  defp show(server, keynum, modifier, key, level) do
    name = Keys.keynum_to_string(keynum, if(modifier == :all, do: 0, else: modifier))
    state = if modifier == :all, do: 0, else: modifier

    case Cvars.binding(server.cvars, keynum, state) do
      nil ->
        Events.print(server, :notify, "\"#{name}\" is not bound\n")

      {text, bound_level} ->
        Events.print(
          server,
          :notify,
          shown(server, name, key, text, describe(bound_level, level))
        )
    end
  end

  defp shown(server, name, key, text, levels) do
    case Cvars.command_alias(server.cvars, text) do
      nil ->
        "^[\"#{name}\"\\type\\bind #{text} #{key}^] = \"#{text}\"#{levels}\n"

      commands ->
        "^[\"#{name}\"\\type\\bind #{key} #{quoted(text)}^] = ^[\"#{text}\"\\type\\alias #{text} #{quoted(commands)}^]#{levels}\n"
    end
  end

  defp describe(level, level), do: ""
  defp describe(_bound, @server), do: ", bound by server"
  defp describe(bound, _level) when bound >= @insecure, do: ", bound by insecure source"
  defp describe(bound, _level), do: ", at level #{bound}"

  defp warn(server, text) do
    if Server.cvar(server, "cl_warncmd") != 0,
      do: Events.print(server, :notify, text),
      else: server
  end

  defp words(tokens), do: Enum.map(tokens, &elem(&1, 0))

  defp level(:server), do: @server
  defp level(_from), do: @local

  defp leading_integer(text) do
    case Integer.parse(String.trim_leading(text)) do
      {number, _} -> number
      :error -> 0
    end
  end
end
