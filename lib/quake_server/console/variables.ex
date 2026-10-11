defmodule QuakeServer.Console.Variables do
  @moduledoc """
  The console's commands about console variables, run on the host's
  `QuakeServer.Cvars` table as FTE's `cmd.c` and `cvar.c` run them.

    * `set name value`, `seta`, `set_tp` — make the variable when there is none and
      set it (`seta` also archives it). The value is the rest of the line; a single
      quoted value may be followed by `// description`, and an unquoted one is cut at
      `//`, the rest its description. A variable made this way takes the description.
    * `setfl name value flags [description]` — `flags` letters `a` (archive), `u`
      (user info), `s` (server info); any other letter does nothing.
    * `toggle name [value [other]]` — between 0 and 1, or `value` and `other` (default
      the variable's default); a variable not there is made at 0
    * `inc name [amount]` — add `amount` (default 1)
    * `name` — print the value, its default and any latched value; `name value` sets it
    * `cvarreset [-a] [-g group] pattern` — set back to their defaults
    * `cvar_lockdefaults`, `cvar_purgedefaults`, `cvar_resettodefaults_all`,
      `cvar_resettodefaults_saveonly`, `cvar_resettodefaults_nosaveonly`
    * `vid_reload`, `vid_restart` — latched renderer and video variables take effect

  Commands from the server (`from: :server`, FTE's commands from game code) cannot set
  `:notfromserver` variables; `set` then reads the flags as `setfl` does, and a value
  the server sets takes the variable over (`QuakeServer.Cvars.lock_from_server/3`)
  unless it is the default.
  """

  alias QuakeServer.{Autocvars, Cvars, Events, Server}
  alias QuakeServer.Cvars.Cvar

  @type tokens :: [{String.t(), non_neg_integer(), non_neg_integer()}]
  @type from :: :local | :server

  @doc "Run `set`, `seta`, `set_tp` or `setfl` (`command`) with the line's `tokens`."
  @spec set(Server.t(), String.t(), tokens(), String.t(), from()) :: Server.t()
  def set(server, command, tokens, _line, _from) when length(tokens) < 3 do
    name = tokens |> Enum.at(1, {"<var>", 0, 0}) |> elem(0)

    usage =
      if command == "setfl",
        do: "#{command} #{name} <value> <a|u|s>\n",
        else: "#{command} #{name} <value>\n"

    Events.print(server, :notify, usage)
  end

  def set(server, command, tokens, line, from) do
    name = tokens |> Enum.at(1) |> elem(0)

    archive =
      if String.starts_with?(command, "seta") and from != :server, do: [:archive], else: []

    case arguments(command, tokens, line, from) do
      :invalid -> server
      {text, description, flags} -> put(server, name, text, description, archive ++ flags, from)
    end
  end

  @doc "Run `toggle name [value [other]]`."
  @spec toggle(Server.t(), [String.t()]) :: Server.t()
  def toggle(server, [_command]), do: Events.print(server, :notify, "missing cvar name\n")

  def toggle(server, [_command, name | values]) do
    case Cvars.get(server.cvars, name, "0") do
      nil -> server
      cvar -> Server.put_cvar(server, name, toggled(cvar, values))
    end
  end

  @doc "Run `inc name [amount]`."
  @spec inc(Server.t(), [String.t()], from()) :: Server.t()
  def inc(server, [_command, name | amount] = words, from) when length(words) in [2, 3] do
    case Cvars.fetch(server.cvars, name) do
      nil ->
        Events.print(server, :notify, "Unknown variable \"#{name}\"\n")

      cvar ->
        if from == :server and Cvars.flag?(cvar, :notfromserver) do
          Events.print(server, :notify, "Server tried setting #{cvar.name} cvar\n")
        else
          delta = amount |> List.first("1") |> Cvars.c_atof()
          Server.put_cvar(server, name, Cvars.format_number(cvar.value + delta))
        end
    end
  end

  def inc(server, _words, _from), do: Events.print(server, :notify, "inc <cvar> [value]\n")

  @doc """
  Run a command naming variable `cvar`: with no value print it, as FTE's `Cvar_Command`
  prints, otherwise set it to the value (the one word, or the rest of the line).
  """
  @spec command(Server.t(), Cvar.t(), tokens(), String.t(), from()) :: Server.t()
  def command(server, %Cvar{} = cvar, tokens, line, from) do
    cond do
      from == :server and Cvars.flag?(cvar, :notfromserver) ->
        Events.print(server, :notify, "Server tried setting #{cvar.name} cvar\n")

      length(tokens) == 1 ->
        Events.print(server, :notify, describe(cvar))

      Cvars.flag?(cvar, :noset) ->
        if warn?(server),
          do: Events.print(server, :notify, "Cvar #{cvar.name} may not be set via the console\n"),
          else: server

      true ->
        value =
          if length(tokens) == 2, do: tokens |> Enum.at(1) |> elem(0), else: rest(line, tokens, 1)

        set_value(server, cvar, value, from)
    end
  end

  @doc "Run `cvarreset` with its words."
  @spec reset(Server.t(), [String.t()]) :: Server.t()
  def reset(server, [_command | words]) do
    case reset_options(words, %{alt: false, group: nil, pattern: nil}) do
      {:print, text} ->
        Events.print(server, :notify, text)

      %{pattern: nil, group: nil} ->
        Events.print(server, :notify, "No group or cvars given\nUse cvarreset -h for help\n")

      options ->
        lines = Cvars.reset(server.cvars, options.pattern, group: options.group, alt: options.alt)
        server |> Server.print_lines(lines) |> Autocvars.sync()
    end
  end

  @doc "Run one of the commands that move every variable's default (`cvar_lockdefaults` and the like)."
  @spec defaults(Server.t(), String.t()) :: Server.t()
  def defaults(server, "cvar_lockdefaults"), do: tap(server, &Cvars.lock_defaults(&1.cvars))
  def defaults(server, "cvar_purgedefaults"), do: tap(server, &Cvars.purge_defaults(&1.cvars))

  def defaults(server, "cvar_resettodefaults_all"),
    do: tap(server, &Cvars.reset_defaults(&1.cvars, :all))

  def defaults(server, "cvar_resettodefaults_saveonly"),
    do: tap(server, &Cvars.reset_defaults(&1.cvars, :saved))

  def defaults(server, "cvar_resettodefaults_nosaveonly"),
    do: tap(server, &Cvars.reset_defaults(&1.cvars, :unsaved))

  @doc "Run `vid_reload` or `vid_restart`: latched renderer and video variables take their latched values."
  @spec renderer(Server.t()) :: Server.t()
  def renderer(server) do
    Cvars.apply_latches(server.cvars, [:videolatch, :rendererlatch])
    Autocvars.sync(server)
  end

  @doc "The raw text of `line` from token `index` on, as FTE's `Cmd_Args` after that many words."
  @spec rest(String.t(), tokens(), non_neg_integer()) :: String.t()
  def rest(line, tokens, index) do
    case Enum.at(tokens, index) do
      nil -> ""
      {_text, start, _stop} -> binary_part(line, start, byte_size(line) - start)
    end
  end

  defp arguments(command, tokens, _line, from) when command == "setfl" or from == :server do
    words = Enum.map(tokens, &elem(&1, 0))

    case flags(Enum.at(words, 3, "")) do
      :invalid -> :invalid
      flags -> {Enum.at(words, 2), Enum.at(words, 4), flags}
    end
  end

  defp arguments(_command, tokens, line, _from) do
    text = rest(line, tokens, 2)

    if length(tokens) == 3 and String.starts_with?(text, ["\"", "\\\""]) do
      {value, _start, stop} = Enum.at(tokens, 2)
      after_value = line |> binary_part(stop, byte_size(line) - stop) |> trim_blank_leading()
      {value, quoted_description(after_value), []}
    else
      {value, description} = split_description(text)
      {value, description, []}
    end
  end

  defp quoted_description("//" <> description),
    do: description |> trim_blank_leading() |> trim_blank_trailing()

  defp quoted_description(_text), do: nil

  defp split_description(text) do
    case :binary.split(text, "//") do
      [value] ->
        {trim_blank_trailing(value), nil}

      [value, description] ->
        {trim_blank_trailing(value), description |> trim_blank_leading() |> trim_blank_trailing()}
    end
  end

  defp trim_blank_leading(text), do: String.replace(text, ~r/\A[ \t]+/, "")
  defp trim_blank_trailing(text), do: String.replace(text, ~r/[ \t\r]+\z/, "")

  defp flags(letters), do: letters |> String.graphemes() |> Enum.reduce_while([], &flag/2)

  defp flag("u", flags), do: {:cont, [:userinfo | flags]}
  defp flag("s", flags), do: {:cont, [:serverinfo | flags]}
  defp flag("a", flags), do: {:cont, [:archive | flags]}
  defp flag(_letter, _flags), do: {:halt, :invalid}

  defp put(server, name, text, description, flags, from) do
    case Cvars.get(server.cvars, name, text, flags, description: description) do
      nil -> server
      cvar -> put_existing(server, cvar, text, flags, from)
    end
  end

  defp put_existing(server, cvar, text, flags, from) do
    cond do
      from == :server and Cvars.flag?(cvar, :notfromserver) ->
        Events.print(server, :notify, "Server tried setting #{cvar.name} cvar\n")

      Cvars.flag?(cvar, :noset) ->
        Events.print(server, :notify, "variable #{cvar.name} is readonly\n")

      true ->
        flags =
          if Cvars.flag?(cvar, :nounsafeexpand),
            do: flags -- [:userinfo, :serverinfo],
            else: flags

        put_flagged(server, cvar, text, flags, from)
    end
  end

  defp put_flagged(server, cvar, text, flags, :server) do
    if flags != [] do
      Cvars.remove_flags(server.cvars, cvar.name, [:userinfo, :serverinfo])
      Cvars.add_flags(server.cvars, cvar.name, flags)
    end

    Cvars.lock_from_server(server.cvars, cvar.name, text)
    Autocvars.sync(server)
  end

  defp put_flagged(server, cvar, text, flags, :local) do
    Cvars.add_flags(server.cvars, cvar.name, [:usercreated | flags])
    Server.put_cvar(server, cvar.name, text)
  end

  defp set_value(server, cvar, value, :server) do
    cond do
      Cvars.flag?(cvar, :serveroverride) and (cvar.default == nil or cvar.default == value) ->
        Cvars.remove_flags(server.cvars, cvar.name, [:serveroverride])
        Server.put_cvar(server, cvar.name, cvar.latched || value)

      Cvars.flag?(cvar, :serveroverride) ->
        Cvars.lock_from_server(server.cvars, cvar.name, value)
        Autocvars.sync(server)

      cvar.default != nil and cvar.default != value ->
        Cvars.lock_from_server(server.cvars, cvar.name, value)
        Autocvars.sync(server)

      true ->
        Server.put_cvar(server, cvar.name, value)
    end
  end

  defp set_value(server, cvar, value, :local), do: Server.put_cvar(server, cvar.name, value)

  defp toggled(cvar, [value]), do: if(value == cvar.string, do: cvar.default, else: value)
  defp toggled(cvar, [value, other | _]), do: if(value == cvar.string, do: other, else: value)
  defp toggled(cvar, []), do: if(cvar.value != 0, do: "0", else: "1")

  defp describe(%Cvar{latched: nil} = cvar) do
    if cvar.default != nil and cvar.string == cvar.default,
      do: "\"#{cvar.name}\" is \"#{cvar.string}\" (default)\n",
      else: "\"#{cvar.name}\" is \"#{cvar.string}\"\n" <> default_line(cvar)
  end

  defp describe(%Cvar{} = cvar) do
    cond do
      Cvars.flag?(cvar, :maplatch) ->
        "\"#{cvar.name}\" is currently \"#{cvar.string}\"\nWill be changed to \"#{cvar.latched}\" on the next map\n"

      Cvars.flag?(cvar, :videolatch) ->
        "\"#{cvar.name}\" is \"#{cvar.string}\"\nWill be changed to \"#{cvar.latched}\" on vid_restart\n"

      Cvars.flag?(cvar, :rendererlatch) ->
        "\"#{cvar.name}\" is \"#{cvar.string}\"\nWill be changed to \"#{cvar.latched}\" on vid_reload\n"

      true ->
        "\"#{cvar.name}\" is \"#{cvar.latched}\"\nEffective value is \"#{cvar.string}\"\n"
    end <> default_line(cvar)
  end

  defp default_line(%Cvar{default: nil}), do: ""
  defp default_line(%Cvar{default: default}), do: "Default: \"#{default}\"\n"

  defp warn?(server),
    do: Server.cvar(server, "cl_warncmd") != 0 or Server.cvar(server, "developer") != 0

  defp reset_options([], options), do: options

  defp reset_options(["-" <> letters | rest], options) do
    case reset_letters(String.graphemes(letters), rest, options) do
      {:print, _text} = printed -> printed
      {rest, options} -> reset_options(rest, options)
    end
  end

  defp reset_options([pattern | rest], options),
    do: reset_options(rest, %{options | pattern: pattern})

  defp reset_letters([], rest, options), do: {rest, options}

  defp reset_letters(["a" | letters], rest, options),
    do: reset_letters(letters, rest, %{options | alt: true})

  defp reset_letters(["g" | _letters], [], _options),
    do: {:print, "Missing parameter for -g\nUse cvarlist -h for help\n"}

  defp reset_letters(["g" | letters], [group | rest], options),
    do: reset_letters(letters, rest, %{options | group: group})

  defp reset_letters([letter | _letters], _rest, _options) when letter in ["u", "h"] do
    {:print,
     "cvarreset resets all cvars to default values matching given parameters\n" <>
       "Syntax: cvarreset [-ahu] (-g group)/cvar\n" <>
       "  -a matches cvar against alternate cvar names\n" <>
       "  -g matches using wildcards in group\n" <>
       "  -h shows this help message\n" <>
       "  -u excludes user cvars\n" <>
       "  cvar indicates the cvars to reset, wildcards (*, ?) accepted\n" <>
       "A -g or cvar is required\n"}
  end

  defp reset_letters(_letters, _rest, _options),
    do: {:print, "Invalid option for cvarreset\nUse cvarreset -h for help\n"}
end
