defmodule QuakeServer.Console do
  @moduledoc """
  The console: the commands a program queues with `localcmd`, the lines of the
  configuration files they `exec`, and commands typed or sent to it, run against the
  host's `QuakeServer.Cvars` table as FTE's console runs them.

      server = QuakeServer.Console.run(server, "exec default.cfg; set skill 2")
      server = QuakeServer.Console.flush(server)

  Text splits into commands at newlines and at `;` outside quotes and outside a `//`
  comment; a comment runs to the end of its line and stays with its command (`set` reads
  a description from it). A command's first word is looked up as FTE looks it up: the
  console's own commands, then aliases, then console variables, then the program.

  The console's own commands:

    * the variable commands of `QuakeServer.Console.Variables`: `set`, `seta`,
      `set_tp`, `setfl`, `toggle`, `inc`, `cvarreset`, `cvar_lockdefaults`,
      `cvar_purgedefaults`, `cvar_resettodefaults_all`, `cvar_resettodefaults_saveonly`,
      `cvar_resettodefaults_nosaveonly`, `vid_reload`, `vid_restart`
    * `exec file`, `cfg_save [name]`, `cfg_save_ifmodified` (`QuakeServer.Console.Configs`)
    * `alias name commands` — kept in the table, so every holder of it shares them; an
      alias runs its commands before the rest, with the command's arguments after a
      one-word alias that names a variable or command
    * `serverinfo key value` (a variable of that name is set too), `localinfo key
      value`, `setinfo key value` (the player's; a `:userinfo` variable of that name is
      set instead), `setinfoblob key file` (as `setinfo`, the value the file's bytes;
      `pmodel` and `emodel` ignored, `*` keys refused)
    * the key binding commands of `QuakeServer.Console.Bindings`: `bind`, `in_bind`,
      `bindlevel`, `unbind`, `unbindall`
    * `setpos [x y z [pitch yaw roll]]` and `noclip` (`QuakeServer.Cheats`)
    * `echo text`, `sky name` (kept in `ext.sky`), `wait` (the rest waits for the next
      `flush/1`), `map name`, `changelevel name [startspot]`
    * `watchpoint`, `watchpoint_ssqc`, `watchpoint_csqc` and `watchpoint_menuqc` with a
      term (a global, or `entity.field` with the entity a number or an entity global):
      the term is kept in `ext.watchpoint` and answered `Watchpoint set`, or `Watchpoint
      cleared` with no term or one that names nothing; changes to what it names are not
      reported

  A variable's name alone prints it; with a value it sets it
  (`QuakeServer.Console.Variables.command/5`). Any other command goes to the program's
  `ConsoleCmd(string)`, or a client program's `CSQC_ConsoleCommand(string)`, when it has
  one, or a menu program's `m_consolecommand(string)` (a command the menu registered
  with `registercommand` counts as taken whatever it returns); `ConsoleCmd` runs as
  FTE's server runs it, with `self` the world and `time` the
  server's, `self` put back afterwards. A command nothing takes is reported as unknown
  while `cl_warncmd` (or `developer`) is set, as FTE reports it. One run expands at most
  4096 aliases and `exec`s; past that the commands they would add are dropped.
  """

  alias QuakeC.Exec
  alias QuakeServer.{Cheats, Cvars, Events}
  alias QuakeServer.Console.{Bindings, Configs, Variables}
  alias QuakeServer.Extensions.{Settings, Store, Strings}
  alias QuakeServer.Server

  @limit 4096
  @variable_commands ~w(set seta set_tp setfl)
  @defaults_commands ~w(cvar_lockdefaults cvar_purgedefaults cvar_resettodefaults_all cvar_resettodefaults_saveonly cvar_resettodefaults_nosaveonly)
  @watchpoints ~w(watchpoint watchpoint_ssqc watchpoint_csqc watchpoint_menuqc)
  @binding_commands Bindings.commands()
  @commands @variable_commands ++
              @defaults_commands ++
              @watchpoints ++
              @binding_commands ++
              ~w(toggle inc cvarreset vid_reload vid_restart exec cfg_save cfg_save_ifmodified alias serverinfo localinfo setinfo setinfoblob echo sky map changelevel wait setpos noclip)

  @doc "Run the commands `localcmd` queued since the last flush."
  @spec flush(Server.t()) :: Server.t()
  def flush(%Server{console: []} = server), do: server

  def flush(%Server{console: queued} = server) do
    %{server | console: []}
    |> run(Enum.join(queued, "\n"))
  end

  @doc """
  Run `text` as console commands now. Option `from: :server` runs them as commands the
  server sent (FTE's commands from game code), which may not set `:notfromserver`
  variables and take over the variables they set.
  """
  @spec run(Server.t(), String.t(), keyword()) :: Server.t()
  def run(%Server{} = server, text, opts \\ []),
    do: lines(server, commands(text), %{from: Keyword.get(opts, :from, :local), added: 0})

  @doc "Whether `name` is one of the console's own commands."
  @spec command?(String.t()) :: boolean()
  def command?(name), do: String.downcase(name, :ascii) in @commands

  @doc """
  The commands of `text`, split at newlines and at `;` outside quotes and outside a
  `//` comment, each trimmed, blank ones dropped; a comment stays with its command.
  """
  @spec commands(String.t()) :: [String.t()]
  def commands(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.flat_map(&split_line(&1, "", false, false, []))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp lines(server, [], _context), do: server

  defp lines(server, [line | rest], context) do
    tokens = Strings.tokenize_console(line)

    case Enum.map(tokens, &elem(&1, 0)) do
      [] ->
        lines(server, rest, context)

      [first | _] = words ->
        if String.downcase(first, :ascii) == "wait" do
          %{server | console: [Enum.join(rest, "\n") | server.console]}
        else
          {server, added} = command(words, tokens, line, server, context)
          continue(server, added, rest, context)
        end
    end
  end

  defp continue(server, [], rest, context), do: lines(server, rest, context)

  defp continue(server, _added, rest, %{added: added} = context) when added >= @limit,
    do: lines(server, rest, context)

  defp continue(server, added, rest, context),
    do: lines(server, added ++ rest, %{context | added: context.added + 1})

  defp command([first | _] = words, tokens, line, server, context) do
    name = String.downcase(first, :ascii)

    cond do
      name in @commands ->
        own(name, words, tokens, line, server, context)

      text = alias_of(server, first) ->
        {server, alias_commands(server, text, tokens, line)}

      cvar = variable(server, first) ->
        {Variables.command(server, cvar, tokens, line, context.from), []}

      true ->
        {program(server, line, context.from), []}
    end
  end

  defp own(name, _words, tokens, line, server, context) when name in @variable_commands,
    do: {Variables.set(server, name, tokens, line, context.from), []}

  defp own(name, _words, _tokens, _line, server, _context) when name in @defaults_commands,
    do: {Variables.defaults(server, name), []}

  defp own(name, words, _tokens, _line, server, _context) when name in @watchpoints,
    do: {watchpoint(server, Enum.at(words, 1)), []}

  defp own(name, _words, tokens, line, server, context) when name in @binding_commands,
    do: {Bindings.command(server, name, tokens, line, context.from), []}

  defp own("toggle", words, _tokens, _line, server, _context),
    do: {Variables.toggle(server, words), []}

  defp own("inc", words, _tokens, _line, server, context),
    do: {Variables.inc(server, words, context.from), []}

  defp own("cvarreset", words, _tokens, _line, server, _context),
    do: {Variables.reset(server, words), []}

  defp own(name, _words, _tokens, _line, server, _context)
       when name in ["vid_reload", "vid_restart"],
       do: {Variables.renderer(server), []}

  defp own("exec", words, _tokens, _line, server, context),
    do: Configs.exec(server, words, context.from)

  defp own(name, words, _tokens, _line, server, _context)
       when name in ["cfg_save", "cfg_save_ifmodified"],
       do: {Configs.save(server, name, words), []}

  defp own("alias", words, _tokens, _line, server, _context), do: {put_alias(server, words), []}

  defp own("serverinfo", words, _tokens, _line, server, _context),
    do: {serverinfo(server, words), []}

  defp own("localinfo", [_, key, value | _], _tokens, _line, server, _context),
    do:
      {%{
         server
         | ext: Map.update(server.ext, :localinfo, %{key => value}, &Map.put(&1, key, value))
       }, []}

  defp own("setinfo", [_, key, value | _], _tokens, _line, server, _context),
    do: {setinfo(server, key, value), []}

  defp own("setinfoblob", [_, key, file], _tokens, _line, server, _context),
    do: {setinfoblob(server, key, file), []}

  defp own("setinfoblob", words, _tokens, _line, server, _context) when length(words) != 1,
    do: {Events.print(server, :notify, "usage: setinfo [ <key> <filename> ]\n"), []}

  defp own("sky", [_, name | _], _tokens, _line, server, _context),
    do: {%{server | ext: Map.put(server.ext, :sky, name)}, []}

  defp own("setpos", [_ | args], _tokens, _line, server, _context),
    do: {Cheats.setpos(server, args), []}

  defp own("noclip", _words, _tokens, _line, server, _context), do: {Cheats.noclip(server), []}

  defp own("echo", [_ | words], _tokens, _line, server, _context),
    do: {Events.print(server, :notify, Enum.join(words, " ") <> "\n"), []}

  defp own("changelevel", [_, map, startspot | _], _tokens, _line, server, _context),
    do: {change_level(server, map, startspot), []}

  defp own(name, [_, map | _], _tokens, _line, server, _context)
       when name in ["map", "changelevel"],
       do: {change_level(server, map, nil), []}

  defp own(_name, _words, _tokens, _line, server, _context), do: {server, []}

  defp change_level(%Server{changelevel: nil} = server, map, startspot),
    do: %{server | changelevel: map, changelevel_startspot: startspot}

  defp change_level(server, _map, _startspot), do: server

  defp variable(%Server{cvars: nil}, _name), do: nil
  defp variable(%Server{cvars: cvars}, name), do: Cvars.fetch(cvars, name)

  defp alias_of(%Server{cvars: nil} = server, name),
    do: server.ext |> Map.get(:aliases, %{}) |> Map.get(name)

  defp alias_of(%Server{cvars: cvars}, name), do: Cvars.command_alias(cvars, name)

  defp alias_commands(server, text, tokens, line) do
    if length(tokens) > 1 and
         (String.starts_with?(text, "cmd ") or one_word_target?(server, text)),
       do: commands(text <> " " <> Variables.rest(line, tokens, 1)),
       else: commands(text)
  end

  defp one_word_target?(server, text) do
    not String.contains?(text, [" ", "\t"]) and
      (variable(server, text) != nil or
         (command?(text) and not String.starts_with?(text, ["+", "-"])))
  end

  defp put_alias(server, [_, name | words]) do
    if command?(name) do
      Events.print(server, :notify, "Can't register alias, #{name} is a command\n")
    else
      store_alias(server, name, Enum.join(words, " "))
    end
  end

  defp put_alias(server, _words), do: server

  defp store_alias(%Server{cvars: nil} = server, name, text),
    do: %{
      server
      | ext: Map.update(server.ext, :aliases, %{name => text}, &Map.put(&1, name, text))
    }

  defp store_alias(%Server{cvars: cvars} = server, name, text) do
    Cvars.put_command_alias(cvars, name, text)
    server
  end

  defp serverinfo(server, [_, key, value | more]) do
    value = Enum.join([value | more], " ")
    server = Settings.put_info(server, 0, key, value)
    if variable(server, key), do: Server.put_cvar(server, key, value), else: server
  end

  defp serverinfo(server, _words), do: server

  defp setinfo(server, key, value) do
    case variable(server, key) do
      nil ->
        Settings.put_info(server, 1, key, value)

      cvar ->
        if Cvars.flag?(cvar, :userinfo),
          do: Server.put_cvar(server, key, value),
          else: Settings.put_info(server, 1, key, value)
    end
  end

  defp setinfoblob(server, key, file) do
    cond do
      String.downcase(key, :ascii) in ["pmodel", "emodel"] ->
        server

      String.starts_with?(key, "*") ->
        Events.print(server, :notify, "Can't set * keys\n")

      true ->
        case Store.read(server, file) do
          nil ->
            Events.print(server, :notify, "Unable to read #{file}\n")

          data when byte_size(data) > 64 * 1024 * 1024 ->
            Events.print(server, :notify, "File is over 64mb\n")

          data ->
            setinfo(server, key, data)
        end
    end
  end

  defp watchpoint(server, nil) do
    %{server | ext: Map.delete(server.ext, :watchpoint)}
    |> Events.print(:notify, "Watchpoint cleared\n")
  end

  defp watchpoint(server, term) do
    if watchable?(server, String.split(term, ".")) do
      %{server | ext: Map.put(server.ext, :watchpoint, term)}
      |> Events.print(:notify, "Watchpoint set\n")
    else
      server
      |> Events.print(:notify, "Unable to evaluate watch term \"#{term}\"\n")
      |> Events.print(:notify, "Watchpoint cleared\n")
    end
  end

  defp watchable?(%Server{qc: nil}, _parts), do: false
  defp watchable?(server, [name]), do: QuakeC.global?(server.qc, name)

  defp watchable?(server, [entity, field]),
    do: entity?(server, entity) and QuakeC.field_offset(server.qc, field) != nil

  defp watchable?(_server, _parts), do: false

  defp entity?(server, entity) do
    case Integer.parse(entity) do
      {number, ""} -> number >= 0 and number < server.count
      _ -> QuakeC.global?(server.qc, entity)
    end
  end

  defp program(%Server{qc: nil} = server, line, from), do: unknown(server, line, from)

  defp program(server, line, from) do
    progs = server.qc.progs

    cond do
      function = QuakeC.Progs.function(progs, "ConsoleCmd") ->
        server |> server_command(function, line) |> answered(line, from)

      function = QuakeC.Progs.function(progs, "CSQC_ConsoleCommand") ->
        server |> client_command(function, line) |> answered(line, from)

      function = QuakeC.Progs.function(progs, "m_consolecommand") ->
        server = client_command(server, function, line)
        if registered?(server, line), do: server, else: answered(server, line, from)

      true ->
        unknown(server, line, from)
    end
  end

  defp server_command(server, function, line) do
    self = QuakeC.global(server.qc, "self")

    qc =
      server.qc
      |> QuakeC.put_global("self", 0)
      |> QuakeC.put_global("time", server.time)
      |> QuakeC.put_slot(4, line)

    server = Exec.call(%{server | qc: qc}, function, server.builtins, Server.exec_opts(server))
    %{server | qc: QuakeC.put_global(server.qc, "self", self)}
  end

  defp client_command(server, function, line) do
    server = %{server | qc: QuakeC.put_slot(server.qc, 4, line)}
    Exec.call(server, function, server.builtins, Server.exec_opts(server))
  end

  defp registered?(server, line) do
    case String.split(line) do
      [name | _] -> MapSet.member?(Map.get(server.ext, :commands, MapSet.new()), name)
      [] -> false
    end
  end

  defp answered(server, line, from) do
    if QuakeC.float(QuakeC.slot(server.qc, 1)) != 0,
      do: server,
      else: unknown(server, line, from)
  end

  defp unknown(server, line, from) do
    if (Server.cvar(server, "cl_warncmd") != 0 and from == :local) or
         Server.cvar(server, "developer") != 0,
       do:
         Events.print(server, :notify, "Unknown command \"#{line |> String.split() |> hd()}\"\n"),
       else: server
  end

  defp split_line(<<>>, current, _quoted, _comment, acc), do: Enum.reverse([current | acc])

  defp split_line(<<"\"", rest::binary>>, current, quoted, comment, acc),
    do: split_line(rest, current <> "\"", not quoted, comment, acc)

  defp split_line(<<c, rest::binary>>, current, true, comment, acc),
    do: split_line(rest, current <> <<c>>, true, comment, acc)

  defp split_line(<<"//", rest::binary>>, current, false, false, acc),
    do: split_line(rest, current <> "//", false, true, acc)

  defp split_line(<<";", rest::binary>>, current, false, false, acc),
    do: split_line(rest, "", false, false, [current | acc])

  defp split_line(<<c, rest::binary>>, current, quoted, comment, acc),
    do: split_line(rest, current <> <<c>>, quoted, comment, acc)
end
