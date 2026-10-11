defmodule QuakeServer.Console.Configs do
  @moduledoc """
  The console's `exec` and `cfg_save`, as FTE's `Cmd_Exec_f` and `Cmd_WriteConfig_f`
  run them, with FTE's main config `fte.cfg`.

  `exec name` reads `name`, or `name.cfg` when there is no `name`, from the table's home
  directory (`QuakeServer.Cvars.home/1`) first and then the game's files; a name
  starting `../` or `./` is refused. Its commands run before the rest of what was being
  run, and:

    * `exec config.cfg` (or `q3config.cfg`) runs `exec fte.cfg` after it, and is refused
      when `default.cfg` is found earlier in the search order than it (`depth/2`);
      `exec fte.cfg` is refused the same way
    * after `config.cfg`, `q3config.cfg` or `fte.cfg`, `exec default.cfg` runs when
      `default.cfg` is found earlier than it; a `vid_restart` line in them is made a
      comment
    * after `default.cfg`, `cvar_lockdefaults 1` runs (not for one the server execs), so
      its values become the defaults
    * a UTF-8 byte order mark is skipped

  `execing name` is printed while `cl_warncmd` or `developer` is set; `couldn't exec
  name` when there is no such file.

  `cfg_save [name]` writes the key bindings (`QuakeServer.Console.Bindings.write/1`,
  while `cfg_save_binds` is set), the console aliases and the archived variables
  (`QuakeServer.Cvars.archive_text/2`; every variable while `cfg_save_all` is set) to
  `fte.cfg` in the home directory, or to `configs/name.cfg`, under a `// FTE config file
  (date)` line, and marks them saved; `cfg_save_ifmodified` does so only when an
  archived variable changed.
  """

  alias QuakeServer.{Cvars, Events, Server}
  alias QuakeServer.Console.Bindings
  alias QuakeServer.Extensions.Store

  @main "fte.cfg"
  @missing 0x7FFFFFFF

  @doc """
  Run `exec` with its words, from the console (`:local`) or the server; the server and
  the commands to run before the rest.
  """
  @spec exec(Server.t(), [String.t()], :local | :server) :: {Server.t(), [String.t()]}
  def exec(server, [_command, name], from) do
    cond do
      String.starts_with?(name, ["../", "..\\", "./", ".\\"]) ->
        text =
          if from == :server,
            do: "exec: #{name} is an invalid path (from server)\n",
            else: "exec: #{name} is an invalid path\n"

        {Events.print(server, :notify, text), []}

      superseded?(server, name) ->
        refuse(server, name, after_main(name))

      true ->
        read(server, name, from)
    end
  end

  def exec(server, _words, _from),
    do: {Events.print(server, :notify, "exec <filename> : execute a script file\n"), []}

  @doc """
  Where file `name` is in the search order: -1 in the home directory, otherwise the
  game source's `depth/1` (0 for any file when the source has none); `0x7FFFFFFF` when
  there is no such file.
  """
  @spec depth(Server.t(), String.t()) :: integer()
  def depth(server, name) do
    home = Cvars.home(server.cvars)
    source = server.source

    cond do
      home && File.regular?(Path.join(home, name)) ->
        -1

      source && Code.ensure_loaded?(source) && function_exported?(source, :depth, 1) ->
        source.depth(name) || @missing

      Store.read(server, name) ->
        0

      true ->
        @missing
    end
  end

  @doc "Run `cfg_save` or `cfg_save_ifmodified` (`command`) with its words."
  @spec save(Server.t(), String.t(), [String.t()]) :: Server.t()
  def save(server, "cfg_save_ifmodified", words) do
    if Cvars.unsaved?(server.cvars), do: save(server, "cfg_save", words), else: server
  end

  def save(server, _command, words) do
    {file, all?} = save_target(server, Enum.at(words, 1, ""))
    home = Cvars.home(server.cvars)

    if home == nil or String.contains?(file, "..") do
      Events.print(server, :notify, "Couldn't write config #{file}\n")
    else
      path = Path.join(home, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, config_text(server.cvars, all?))
      Cvars.saved(server.cvars)
      Events.print(server, :notify, "Wrote #{file}\n")
    end
  end

  defp superseded?(server, name) when name in ["config.cfg", "q3config.cfg", @main] do
    config = depth(server, name)
    defaults = depth(server, "default.cfg")
    defaults < config and config != @missing
  end

  defp superseded?(_server, _name), do: false

  defp after_main(name) when name in ["config.cfg", "q3config.cfg"], do: ["exec " <> @main]
  defp after_main(_name), do: []

  defp refuse(server, name, following) do
    server =
      if warn?(server),
        do:
          Events.print(
            server,
            :notify,
            "Refusing to execute \"#{name}\", superceded by default.cfg\n"
          ),
        else: server

    {server, following}
  end

  defp read(server, name, from) do
    case locate(server, name) do
      nil ->
        {Events.print(server, :notify, "couldn't exec #{name}\n"), after_main(name)}

      text ->
        server =
          if warn?(server), do: Events.print(server, :notify, "execing #{name}\n"), else: server

        {server, text} = prepared(server, name, strip_mark(text))

        {server,
         QuakeServer.Console.commands(text) ++ following(server, name, from) ++ after_main(name)}
    end
  end

  defp locate(server, name), do: file(server, name) || file(server, name <> ".cfg")

  defp file(server, name) do
    home = Cvars.home(server.cvars)
    path = home && Path.join(home, name)
    if path && File.regular?(path), do: File.read!(path), else: Store.read(server, name)
  end

  defp strip_mark(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_mark(text), do: text

  defp prepared(server, name, text) when name in ["config.cfg", "q3config.cfg", @main] do
    if Regex.match?(~r/\nvid_restart[\r\n]/, text) do
      text = String.replace(text, ~r/\nvid_restart(?=[\r\n])/, "\n//d_restart", global: false)
      {Events.print(server, :notify, "WARNING: #{name} came from a different engine\n"), text}
    else
      {server, text}
    end
  end

  defp prepared(server, _name, text), do: {server, text}

  defp following(server, name, _from) when name in ["config.cfg", "q3config.cfg", @main] do
    if depth(server, "default.cfg") < depth(server, name), do: ["exec default.cfg"], else: []
  end

  defp following(_server, "default.cfg", :local), do: ["cvar_lockdefaults 1"]
  defp following(_server, _name, _from), do: []

  defp save_target(server, "") do
    {@main, Cvars.value(server.cvars, "cfg_save_all") != 0}
  end

  defp save_target(server, name) do
    file = if Path.extname(name) == "", do: "configs/" <> name <> ".cfg", else: "configs/" <> name

    all? =
      Cvars.value(server.cvars, "cfg_save_all") != 0 or
        Cvars.string(server.cvars, "cfg_save_all") == ""

    {file, all?}
  end

  defp config_text(cvars, all?) do
    {{year, month, day}, {hour, minute, _}} = :calendar.local_time()

    stamp =
      :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B", [year, month, day, hour, minute])
      |> IO.iodata_to_binary()

    name = Cvars.string(cvars, "com_fullgamename")
    name = if name == "", do: "FTE", else: name

    aliases =
      cvars
      |> Cvars.command_aliases()
      |> Enum.map_join(fn {alias_name, commands} -> "alias #{alias_name} \"#{commands}\"\n" end)

    binds = if Cvars.value(cvars, "cfg_save_binds") != 0, do: Bindings.write(cvars), else: ""

    "// #{name} config file (#{stamp})\n\n" <> binds <> aliases <> Cvars.archive_text(cvars, all?)
  end

  defp warn?(server),
    do: Server.cvar(server, "cl_warncmd") != 0 or Server.cvar(server, "developer") != 0
end
