defmodule QuakeServer.Server do
  @moduledoc """
  A running level of a QuakeC game: the program and its entities, the map, the models and
  sounds it has asked for, and what happened this frame for a client to show.

      server = QuakeServer.Server.start("e1m1", source: MyGame.Source, skill: 1)
      server = QuakeServer.Server.connect(server)
      server = QuakeServer.Server.frame(server, 1 / 60, command)
      {events, server} = QuakeServer.Server.drain(server)

  A command is `%{forward:, side:, up:, angles: {pitch, yaw, roll}, attack:, jump:,
  impulse:}`, the moves in units a second and the angles in degrees. For a program that
  runs its players' commands itself (`QuakeServer.Physics.Command`) it is `%{forward:,
  side:, up:, angles:, buttons:, impulse:}`.

  Entity 0 is the world, entity 1 the player (`slots` is how many entities after the world
  are player slots: 1 for a level, 0 for a client program's world). The player slots'
  entities are in use from the level's start, as FTE allocates them; the player is in the
  game from `connect/3` until `disconnect/1` (`parms` is `nil` while it is not).
  """

  alias QuakeC.Exec
  alias QuakeServer.{Autocvars, Builtins, Cvars, Edicts, EntityTable, Physics, Spawn, World}
  alias QuakeServer.Extensions.{Settings, Store, Strings}
  alias QuakeServer.Cvars.Engine
  alias QuakeServer.Physics.Command

  @type command :: %{
          forward: number(),
          side: number(),
          up: number(),
          angles: {number(), number(), number()},
          attack: boolean(),
          jump: boolean(),
          impulse: non_neg_integer()
        }

  defstruct [
    :qc,
    :map,
    :bsp,
    :source,
    builtins: Builtins,
    replacements: %{},
    budget: 100_000,
    hull: &QuakeServer.World.choose_hull/2,
    inhibit: &QuakeServer.Q.skill_inhibited?/2,
    trace: nil,
    model_names: [""],
    models: %{0 => nil},
    sound_names: [""],
    edicts: %{},
    count: 2,
    links: %{},
    leaves: %{},
    versions: %{},
    area: %{},
    time: 1.0,
    clock: 1.0,
    slots: 1,
    frametime: 0.1,
    lightstyles: %{},
    events: [],
    messages: [],
    statics: [],
    ambients: [],
    cvars: nil,
    ext: %{},
    console: [],
    coords: :short,
    data_dir: nil,
    command: nil,
    parms: nil,
    changelevel: nil,
    changelevel_startspot: nil,
    check: %{client: 1, time: -1.0, leaf: nil},
    skill: 1,
    serverflags: 0
  ]

  @type t :: %__MODULE__{}

  @typedoc "What a player carries from level to level: the 64 spawn parameters, `parm1` first, and the program's `parm_string`."
  @type spawn_parms :: %{parms: [number()], string: String.t() | nil}

  @spawn_parms 64
  @netquake_crc 5927
  @quakeworld_crc 54_730

  @doc """
  Load map `name` and spawn its entities, as a fresh level, in the order of FTE's
  `SV_SpawnServer`: the info keys `mapname`, `*cheats` (`ON` while the cvar `sv_cheats`
  is set), `*bspversion` (`30` for a Half-Life map) and `*startspot` are set (an empty
  one removed); the program is loaded, its `dimension_send` defaulted, and its `init`
  called with `-1` at `time` 0; the model list is the world and its submodels; the world
  entity is set up (its model, `solid` bsp, `movetype` push, its box) and the player slots'
  entities allocated; the globals `mapname`, `serverflags`, `time` (1), and `coop` (when
  the cvar `coop` is set) or else `deathmatch` are set; `initents` runs; a QuakeWorld
  program (CRC 54730) has `StartFrame` run at time 0; the map's entities spawn; the
  world's angles are cleared and the level's name taken from its `message`
  (`ext.levelname`); two physics frames of a tenth of a second run from time 1, leaving
  the host clock at 1.3; then the info key `map` is set and the `startspot` global.

  ## Options

    * `:source` — the game's `QuakeServer.Source` module (required); the program
      functions its `replacements/0` names run as the game's functions
      (`QuakeServer.Builtins.call/3`)
    * `:builtins` — the module whose `call/3` runs the program's builtins, default
      `QuakeServer.Builtins`
    * `:budget` — how many statements one call into the program may run, default 100 000
    * `:trace` — a function given the name of every QuakeC function the program enters,
      default none
    * `:hull` — `fun(hulls, size)` choosing the hull a box of `size` moves through in a
      brush model, default `QuakeServer.World.choose_hull/2`
    * `:inhibit` — `fun(spawnflags, skill)`, true for a map entity to leave out, default
      `QuakeServer.Q.skill_inhibited?/2`; a program with `CheckSpawn` filters its own

  A program defining `init` has it called with `-1` once its memory is fresh, and one
  defining `initents` has that called before the map's entities spawn.
    * `:skill` — 0 (easy) to 3 (nightmare), default 1
    * `:serverflags` — carried from level to level (the episode runes), default 0
    * `:cvar_table` — the `QuakeServer.Cvars` table of console variables to use, shared
      with whatever else holds it; default a table of the server's own, freed by
      `release/1`. FTE's engine variables are registered in it (`QuakeServer.Cvars.Engine`),
      its `:maplatch` variables take their latched values, and it is marked as having a
      server running. The skill option sets `skill`; without one a blank `skill` becomes 1.
    * `:cvars` — console variables to set in the table, name to text or number, as `set`
      sets them
    * `:data_dir` — the directory the program's written files (`data/…`) are kept in;
      without one they last as long as the server
    * `:coords` — `:short` (Quake's) or `:float`, how messages carry coordinates and
      angles; see `QuakeServer.Builtins.Write`
    * `:startspot` — the landmark name the last level's `changelevel` gave, put in the
      program's `startspot` global once the entities have spawned and settled
    * `:written` — the files the program wrote on earlier levels, name to bytes (the
      host's `ext.written` of the last level)
    * `:entity_tables` — the entity tables of those files (the host's
      `ext.entity_tables` of the last level), by which the program's `edict_num`
      translates the entity numbers it reads from them; see `QuakeServer.EntityTable`
    * `:serverinfo` — the server's info keys as the last level left them, kept under
      the keys this level sets, as FTE keeps its server info from level to level

  A `changelevel` asked for during play leaves the map in `changelevel` and the
  landmark, when one was given, in `changelevel_startspot`.
  """
  @spec start(String.t(), keyword()) :: t()
  def start(name, opts) do
    source = Keyword.fetch!(opts, :source)

    %{bsp: bsp, entities: text} =
      source.map(name) || raise ArgumentError, "there is no map #{name}"

    skill = Keyword.get(opts, :skill, 1)
    replacements = replacements(source)

    server = %__MODULE__{
      qc: QuakeC.new(QuakeC.Progs.replace(source.progs(), Map.keys(replacements))),
      replacements: replacements,
      map: name,
      bsp: bsp,
      source: source,
      builtins: Keyword.get(opts, :builtins, Builtins),
      budget: Keyword.get(opts, :budget, 100_000),
      hull: Keyword.get(opts, :hull, &QuakeServer.World.choose_hull/2),
      inhibit: Keyword.get(opts, :inhibit, &QuakeServer.Q.skill_inhibited?/2),
      trace: Keyword.get(opts, :trace),
      skill: skill,
      serverflags: Keyword.get(opts, :serverflags, 0),
      cvars: server_cvars(opts),
      data_dir: Keyword.get(opts, :data_dir),
      coords: Keyword.get(opts, :coords, :short),
      time: 0.0,
      ext: %{
        written: Keyword.get(opts, :written, %{}),
        entity_tables: EntityTable.carry(Keyword.get(opts, :entity_tables, %{})),
        serverinfo: Keyword.get(opts, :serverinfo, %{})
      }
    }

    startspot = Keyword.get(opts, :startspot)

    server
    |> put_star_keys(startspot)
    |> load_progs()
    |> precache_world()
    |> spawn_world()
    |> hook("initents", [])
    |> QuakeServer.Console.flush()
    |> quakeworld_start_frame()
    |> Spawn.entities(text)
    |> QuakeServer.Console.flush()
    |> name_level()
    |> settle()
    |> Settings.put_info(0, "map", name)
    |> put_startspot(startspot)
  end

  @doc """
  Bring back a level left by a `changelevel` with a landmark, as it was left, as FTE's
  `SV_LoadLevelCache` brings one back: the change it asked for is forgotten; the info
  keys of option `:serverinfo` (the server's as they stand) are taken under the level's
  own and the star keys of `start/2` set again for option `:startspot`; the program's
  `serverflags` global becomes option `:serverflags`, `time` the level's physics time and
  `startspot` the landmark; its written files become option `:written` and their entity
  tables option `:entity_tables`. Connect the player to it next.
  """
  @spec resume(t(), keyword()) :: t()
  def resume(%__MODULE__{} = server, opts) do
    startspot = Keyword.get(opts, :startspot)
    flags = Keyword.get(opts, :serverflags, server.serverflags)

    serverinfo =
      Map.merge(Keyword.get(opts, :serverinfo, %{}), Map.get(server.ext, :serverinfo, %{}))

    ext =
      server.ext
      |> Map.put(:written, Keyword.get(opts, :written, %{}))
      |> Map.put(:entity_tables, EntityTable.carry(Keyword.get(opts, :entity_tables, %{})))
      |> Map.put(:serverinfo, serverinfo)

    qc =
      server.qc
      |> QuakeC.put_declared("serverflags", flags / 1)
      |> QuakeC.put_declared("time", server.time / 1)

    %{server | qc: qc, changelevel: nil, changelevel_startspot: nil, serverflags: flags, ext: ext}
    |> put_star_keys(startspot)
    |> put_startspot(startspot)
  end

  @doc """
  Load map `name` with its world entity and the source's program, spawning nothing else
  and calling no hooks: the world a client program (FTE's CSQC) runs in. Takes
  `start/2`'s options; its console variable table is not marked as having a server
  running and its latched variables stay latched.
  """
  @spec open(String.t(), keyword()) :: t()
  def open(name, opts) do
    source = Keyword.fetch!(opts, :source)

    %{bsp: bsp} = source.map(name) || raise ArgumentError, "there is no map #{name}"
    replacements = replacements(source)

    %__MODULE__{
      qc: QuakeC.new(QuakeC.Progs.replace(source.progs(), Map.keys(replacements))),
      replacements: replacements,
      map: name,
      bsp: bsp,
      source: source,
      builtins: Keyword.get(opts, :builtins, Builtins),
      budget: Keyword.get(opts, :budget, 100_000),
      hull: Keyword.get(opts, :hull, &QuakeServer.World.choose_hull/2),
      inhibit: Keyword.get(opts, :inhibit, &QuakeServer.Q.skill_inhibited?/2),
      trace: Keyword.get(opts, :trace),
      cvars: client_cvars(opts),
      data_dir: Keyword.get(opts, :data_dir),
      coords: Keyword.get(opts, :coords, :short),
      slots: 0
    }
    |> default_dimensions()
    |> precache_world()
    |> spawn_world()
  end

  @doc """
  Bring the player in, as FTE does when its client begins (`SV_SetUpClientEdict`, then
  `SV_Begin_Core`), carrying `parms` from the last level (`save_spawn_parms/1`, or the
  bare list of 64), or with the program's `SetNewParms` run for fresh ones when `nil`.
  The player's entity is cleared (not for a NetQuake program, CRC 5927), named by the
  player's `name` info key (`Player` without one), and given its entity number as
  `colormap`, `16 × topcolor + bottomcolor` as `clientcolors` (each 0 outside 0 to 13),
  `gravity` 1, `maxspeed` the cvar `sv_maxspeed`, `movetype` noclip and no frags. The
  spawn parameters go into the `parm*` globals and `parm_string`; `ClientConnect` runs
  with its argument 1 when option `:csqc` is true (the client runs a client program),
  0 otherwise, then `PutClientInServer`, each with `self` the player and `time` the
  server's; `oldorigin` becomes `origin`; and a program that runs its players' commands
  runs one empty command (no time, no moves, the angles the player's `v_angle`).
  """
  @spec connect(t(), spawn_parms() | [number()] | nil, keyword()) :: t()
  def connect(%__MODULE__{} = server, parms \\ nil, opts \\ []) do
    player = 1
    {server, carried} = spawn_parms(server, parms)

    ext =
      server.ext
      |> Map.put(:parm_string, carried.string)
      |> Map.delete(:independent)

    %{server | parms: carried.parms, ext: ext}
    |> set_up_client_edict(player)
    |> put_parms(carried)
    |> set_globals(player, 0)
    |> put_args([if(Keyword.get(opts, :csqc, false), do: 1.0, else: 0.0)])
    |> call_named("ClientConnect")
    |> set_globals(player, 0)
    |> call_named("PutClientInServer")
    |> keep_old_origin(player)
    |> run_empty_command(player)
  end

  @doc "The name of player `entity`: its `name` info key, `Player` without one (FTE's `name` default)."
  @spec player_name(t(), pos_integer()) :: String.t()
  def player_name(%__MODULE__{ext: ext}, entity),
    do: ext |> Map.get(:userinfo, %{}) |> Map.get(entity, %{}) |> Map.get("name", "Player")

  @doc """
  Take the player out of the level, as FTE's `SV_DespawnClient` does to a level it keeps:
  `ClientDisconnect` runs with `self` the player, a NetQuake program's player entity is
  cleared, the player's `frags` become 0 and the player is no longer in the game.
  """
  @spec disconnect(t()) :: t()
  def disconnect(%__MODULE__{parms: nil} = server), do: server

  def disconnect(%__MODULE__{} = server) do
    server
    |> set_globals(1, 0)
    |> call_named("ClientDisconnect")
    |> clear_netquake_client(1)
    |> Edicts.put(1, "frags", 0.0)
    |> Map.put(:parms, nil)
  end

  @doc """
  Run one physics frame of `seconds` (`QuakeServer.Physics.frame/1`), `command` being the
  player's latest for a program that does not run its players' commands itself: the
  routes asked for before are handed to their callbacks
  (`QuakeServer.Extensions.Routes.run/1`), the replies to `uri_get` that have come to
  `URI_Get_Callback` (`QuakeServer.Extensions.Web.run/1`), the console's queued commands run, then every
  entity, and the physics clock (`time`) moves on by `seconds`. How long a frame should
  be is the caller's choice; FTE runs them as `QuakeServer.Runner` does.
  """
  @spec frame(t(), number(), command()) :: t()
  def frame(%__MODULE__{} = server, seconds, command) do
    server = %{server | frametime: seconds / 1, command: command}
    qc = QuakeC.put_global(server.qc, "frametime", seconds / 1)

    %{server | qc: qc}
    |> QuakeServer.Extensions.Routes.run()
    |> QuakeServer.Extensions.Web.run()
    |> QuakeServer.Console.flush()
    |> Physics.frame()
  end

  @doc """
  Run a player's command as it arrives, for a program that runs its players' commands
  itself (`QuakeServer.Physics.Command`), at the host clock (`clock`); a program that
  does not has `command` kept for its frames instead.
  """
  @spec client_command(t(), non_neg_integer(), map()) :: t()
  def client_command(%__MODULE__{} = server, entity, command) do
    if Command.program_moves?(server),
      do: Command.run(server, entity, command),
      else: %{server | command: command}
  end

  @doc "Move the host clock (`clock`) on by `seconds`; physics frames catch up to it."
  @spec advance(t(), number()) :: t()
  def advance(%__MODULE__{} = server, seconds), do: %{server | clock: server.clock + seconds}

  @doc "The events of the frames since the last drain, oldest first, and the server without them."
  @spec drain(t()) :: {[term()], t()}
  def drain(%__MODULE__{} = server) do
    messages = QuakeServer.Messages.decode(IO.iodata_to_binary(Enum.reverse(server.messages)))
    {Enum.reverse(server.events) ++ messages, %{server | events: [], messages: []}}
  end

  @doc """
  Free the level's program memory (`QuakeC.release/1`) and a console variable table the
  server made itself; the server may not be used after.
  """
  @spec release(t()) :: :ok
  def release(%__MODULE__{qc: qc, cvars: cvars}) do
    if match?(%Cvars{release: true}, cvars), do: Cvars.delete(cvars)
    QuakeC.release(qc)
  end

  @doc """
  What the level change carries, as FTE's `SV_SaveSpawnparms` takes it: the player's
  spawn parameters go back into the `parm*` globals and `parm_string`, the program's
  `SetChangeParms` runs with `self` the player, and the globals are read into `parms` and
  `string`; with no player in the game both are `nil`. `serverflags` is the program's
  global.
  """
  @spec save_spawn_parms(t()) :: %{
          parms: [float()] | nil,
          string: String.t() | nil,
          serverflags: float()
        }
  def save_spawn_parms(%__MODULE__{parms: nil} = server),
    do: %{parms: nil, string: nil, serverflags: serverflags(server)}

  def save_spawn_parms(%__MODULE__{} = server) do
    server =
      server
      |> put_parms(%{parms: server.parms, string: Map.get(server.ext, :parm_string)})
      |> set_globals(1, 0)
      |> call_named("SetChangeParms")

    %{parms: parms(server), string: parm_string(server), serverflags: serverflags(server)}
  end

  @doc "The spawn parameters the player carries to the next level (`save_spawn_parms/1`'s `parms`)."
  @spec change_parms(t()) :: [float()] | nil
  def change_parms(%__MODULE__{} = server), do: save_spawn_parms(server).parms

  @doc "Whether the program saves and restores a level itself (`SV_PerformSave` and `SV_PerformLoad`)."
  @spec saves_levels?(t()) :: boolean()
  def saves_levels?(%__MODULE__{qc: qc}),
    do:
      QuakeC.Progs.function(qc.progs, "SV_PerformSave") != nil and
        QuakeC.Progs.function(qc.progs, "SV_PerformLoad") != nil

  @doc """
  Save the level for a return through a landmark, as FTE's `SV_SaveLevelCache` saves one
  for a program that saves itself: the player is taken out (`disconnect/1`), and the
  text is FTE's: the version (515), a comment (the level's name and kills, 39
  characters, spaces as `_`), `vmmode`, the cvars `skill`, `deathmatch`, `coop` and
  `teamplay`, `time` and `map`, then `moddata` and what the program's
  `SV_PerformSave(file, entities, slots)` writes to the file it is given,
  `saves/<map>.lvc`. Returns the text and the server.
  """
  @spec save_level(t()) :: {String.t(), t()}
  def save_level(%__MODULE__{} = server) do
    name = "saves/#{server.map}.lvc"
    server = disconnect(server)
    {server, file} = Store.open_output(server, name, level_preamble(server) <> "moddata\n")

    server =
      server
      |> put_args([file / 1, server.count / 1, server.slots / 1])
      |> call_named("SV_PerformSave")

    {Store.output(server, file, name), server}
  end

  @doc """
  Restore onto a freshly started level the save `text` of `save_level/1`, as FTE's
  `SV_LoadLevelCache`: the program's `SV_PerformLoad(file, entities, slots)` reads the
  text after its `moddata` line, every entity is linked into the world again, and the
  physics time, the host clock and `time` become the saved time.
  """
  @spec load_level(t(), String.t()) :: t()
  def load_level(%__MODULE__{} = server, text) do
    saved = saved_level(text)
    name = "saves/#{server.map}.lvc"
    {server, file} = Store.open_buffer(server, name, saved.moddata, saved.at)

    server =
      server
      |> put_args([file / 1, server.count / 1, server.slots / 1])
      |> call_named("SV_PerformLoad")
      |> relink()

    qc = QuakeC.put_declared(server.qc, "time", saved.time)
    %{server | qc: qc, time: saved.time, clock: saved.time}
  end

  @doc """
  The preamble of a save from `save_level/1`: the console variables it sets, its time,
  its map, and its program data with the place its `moddata` line ends.
  """
  @spec saved_level(String.t()) :: %{
          cvars: %{String.t() => String.t()},
          time: float(),
          map: String.t(),
          moddata: binary(),
          at: non_neg_integer()
        }
  def saved_level(text) do
    [_version, _comment | lines] = String.split(text, "\n")
    preamble(lines, %{cvars: %{}, time: 0.0, map: "", moddata: "", at: 0})
  end

  defp preamble([], saved), do: saved

  defp preamble([line | lines], saved) do
    case line |> Strings.tokenize_console() |> Enum.map(&elem(&1, 0)) do
      ["map", map | _] ->
        moddata(%{saved | map: map}, Enum.join(lines, "\n"))

      ["cvar", name, value | _] ->
        preamble(lines, %{saved | cvars: Map.put(saved.cvars, name, value)})

      ["time", time | _] ->
        preamble(lines, %{saved | time: Strings.number(time)})

      _ ->
        preamble(lines, saved)
    end
  end

  defp moddata(saved, data) do
    case :binary.match(data, "moddata\n") do
      {at, length} -> %{saved | moddata: data, at: at + length}
      :nomatch -> %{saved | moddata: data, at: byte_size(data)}
    end
  end

  defp level_preamble(server) do
    [
      "515",
      save_comment(server),
      "vmmode " <> quoted(vm_mode(server)),
      "cvar skill " <> quoted(cvar_string(server, "skill")),
      "cvar deathmatch " <> quoted(cvar_string(server, "deathmatch")),
      "cvar coop " <> quoted(cvar_string(server, "coop")),
      "cvar teamplay " <> quoted(cvar_string(server, "teamplay")),
      "time " <> :erlang.float_to_binary(server.time / 1, decimals: 6),
      "map " <> quoted(server.map)
    ]
    |> Enum.map_join(&(&1 <> "\n"))
  end

  defp quoted(text), do: "\"" <> text <> "\""

  defp vm_mode(%__MODULE__{qc: %{progs: %{crc: @quakeworld_crc}}}), do: "QW"
  defp vm_mode(%__MODULE__{qc: %{progs: %{crc: @netquake_crc}}}), do: "NQ"
  defp vm_mode(_server), do: "UNKNOWN"

  defp save_comment(server) do
    name = server.ext |> Map.get(:levelname, server.map) |> String.slice(0, 22)

    (String.pad_trailing(name, 22) <> String.pad_trailing(kills(server), 17))
    |> String.slice(0, 39)
    |> String.replace(" ", "_")
  end

  defp kills(server) do
    killed = trunc(global_float(server, "killed_monsters"))
    total = trunc(global_float(server, "total_monsters"))

    if killed != 0 or total != 0,
      do:
        "kills:" <> String.pad_leading("#{killed}", 3) <> "/" <> String.pad_leading("#{total}", 3),
      else: ""
  end

  defp global_float(server, name) do
    if QuakeC.global?(server.qc, name),
      do: QuakeC.float(QuakeC.global(server.qc, name)),
      else: 0.0
  end

  defp relink(server) do
    server = Enum.reduce(Map.keys(server.links), server, &World.unlink(&2, &1))
    Enum.reduce(Edicts.live(server), server, &World.link(&2, &1, false))
  end

  @doc "Run QuakeC function value `function` with `self` and `other` set, at the server's time."
  @spec run(t(), integer(), non_neg_integer(), non_neg_integer()) :: t()
  def run(%__MODULE__{} = server, function, self, other) do
    server
    |> set_globals(self, other)
    |> Exec.call(trunc(function), server.builtins, exec_opts(server))
  end

  @doc "Run the program's function `name` as it stands."
  @spec call_named(t(), String.t()) :: t()
  def call_named(%__MODULE__{} = server, name),
    do: Exec.call_named(server, name, server.builtins, exec_opts(server))

  @doc """
  The options every call into the program takes: the server's budget and trace, and
  `QuakeServer.Autocvars.sync/1` run before the call.
  """
  @spec exec_opts(t()) :: keyword()
  def exec_opts(%__MODULE__{budget: budget, trace: trace}),
    do: [budget: budget, trace: trace, before: &Autocvars.sync/1]

  @doc """
  Run `call` (a function of the server) and put `self` and `other` back as they were, as
  a builtin that calls back into the program must.
  """
  @spec keeping_self(t(), (t() -> t())) :: t()
  def keeping_self(%__MODULE__{} = server, call) do
    self = QuakeC.global(server.qc, "self")
    other = QuakeC.global(server.qc, "other")
    server = call.(server)

    %{
      server
      | qc: server.qc |> QuakeC.put_global("self", self) |> QuakeC.put_global("other", other)
    }
  end

  @doc "Set `self`, `other` and `time` for a call into the program."
  @spec set_globals(t(), non_neg_integer(), non_neg_integer()) :: t()
  def set_globals(%__MODULE__{} = server, self, other) do
    qc =
      server.qc
      |> QuakeC.put_global("self", self)
      |> QuakeC.put_global("other", other)
      |> QuakeC.put_global("time", server.time)

    %{server | qc: qc}
  end

  @doc "Add an event for the client."
  @spec emit(t(), term()) :: t()
  def emit(%__MODULE__{} = server, event), do: %{server | events: [event | server.events]}

  @doc "The value of console variable `name` as a number (FTE's `value`), 0.0 when there is no such variable."
  @spec cvar(t(), String.t()) :: float()
  def cvar(%__MODULE__{cvars: nil}, _name), do: 0.0
  def cvar(%__MODULE__{cvars: cvars}, name), do: Cvars.value(cvars, name)

  @doc "The value of console variable `name` as text, `\"\"` when there is no such variable."
  @spec cvar_string(t(), String.t()) :: String.t()
  def cvar_string(%__MODULE__{cvars: nil}, _name), do: ""
  def cvar_string(%__MODULE__{cvars: cvars}, name), do: Cvars.string(cvars, name)

  @doc "Whether there is a console variable `name`."
  @spec cvar?(t(), String.t()) :: boolean()
  def cvar?(%__MODULE__{cvars: nil}, _name), do: false
  def cvar?(%__MODULE__{cvars: cvars}, name), do: Cvars.exists?(cvars, name)

  @doc """
  Set console variable `name` to `value`, text or a number (written as FTE's
  `Cvar_SetValue` writes one), as FTE's `Cvar_Set` (`QuakeServer.Cvars.set/4`); a name
  there is no variable for is made, as a config or program makes one. What FTE prints
  about it is printed, and the server's own `autocvar_` globals and info keys follow at
  once (`QuakeServer.Autocvars.sync/1`).
  """
  @spec put_cvar(t(), String.t(), String.t() | number()) :: t()
  def put_cvar(%__MODULE__{cvars: %Cvars{} = cvars} = server, name, value) do
    text = if is_number(value), do: Cvars.format_number(value), else: value

    case Cvars.get(cvars, name, text) do
      nil ->
        server

      _cvar ->
        {:ok, prints} = Cvars.set(cvars, name, text)
        server |> print_lines(prints) |> Autocvars.sync()
    end
  end

  @doc "Print `lines` to the console, each as a `{:print, :notify, line}` event."
  @spec print_lines(t(), [String.t()]) :: t()
  def print_lines(%__MODULE__{} = server, lines),
    do: Enum.reduce(lines, server, &emit(&2, {:print, :notify, &1}))

  defp server_cvars(opts) do
    cvars = client_cvars(opts)
    put_skill(cvars, opts)
    Cvars.apply_latches(cvars, :maplatch)
    Cvars.put_running(cvars, :server, true)
    cvars
  end

  defp client_cvars(opts) do
    cvars =
      case Keyword.get(opts, :cvar_table) do
        nil -> %{Cvars.new() | release: true}
        %Cvars{} = shared -> shared
      end

    Engine.register(cvars)

    for {name, value} <- Keyword.get(opts, :cvars, %{}) do
      text = if is_number(value), do: Cvars.format_number(value), else: value
      Cvars.get(cvars, name, text) && Cvars.set(cvars, name, text)
    end

    cvars
  end

  defp put_skill(cvars, opts) do
    cond do
      Keyword.has_key?(opts, :skill) ->
        Cvars.set(cvars, "skill", Cvars.format_number(Keyword.fetch!(opts, :skill)))

      Cvars.string(cvars, "skill") == "" ->
        Cvars.set(cvars, "skill", "1")

      true ->
        :ok
    end
  end

  defp precache_world(server) do
    submodels = for i <- 1..(tuple_size(server.bsp.models) - 1)//1, do: "*#{i}"
    names = ["", "maps/#{server.map}.bsp" | submodels]

    models =
      names
      |> Enum.with_index()
      |> Map.new(fn {name, index} -> {index, QuakeServer.Models.info(server, name)} end)

    %{server | model_names: names, models: models}
  end

  defp put_star_keys(server, startspot) do
    [
      {"mapname", server.map},
      {"*cheats", if(cvar(server, "sv_cheats") != 0, do: "ON", else: "")},
      {"*bspversion", bsp_version(server.bsp)},
      {"*startspot", startspot || ""}
    ]
    |> Enum.reduce(server, fn {key, value}, acc -> put_info_key(acc, key, value) end)
  end

  defp put_info_key(server, key, ""),
    do: %{server | ext: Map.update(server.ext, :serverinfo, %{}, &Map.delete(&1, key))}

  defp put_info_key(server, key, value),
    do: %{
      server
      | ext: Map.update(server.ext, :serverinfo, %{key => value}, &Map.put(&1, key, value))
    }

  defp replacements(source) do
    if function_exported?(source, :replacements, 0), do: source.replacements(), else: %{}
  end

  defp load_progs(server) do
    server
    |> default_dimensions()
    |> hook("init", [-1.0])
    |> QuakeServer.Console.flush()
  end

  defp default_dimensions(server), do: %{server | qc: default_dimension_send(server.qc)}

  defp spawn_world(server) do
    world = elem(server.bsp.models, 0)

    qc =
      server.qc
      |> QuakeC.put_declared("mapname", "maps/#{server.map}.bsp" |> Path.basename(".bsp"))
      |> QuakeC.put_declared("serverflags", server.serverflags / 1)
      |> QuakeC.put_declared("time", 1.0)
      |> put_game_mode(server)

    edicts =
      Map.new(0..max(server.slots, 1), &{&1, %{free: &1 > server.slots, freetime: 0.0}})

    %{server | qc: qc, edicts: edicts, time: 1.0}
    |> Edicts.clear(0)
    |> clear_slots()
    |> Edicts.put(0, "model", "maps/#{server.map}.bsp")
    |> Edicts.put(0, "modelindex", 1.0)
    |> Edicts.put(0, "solid", QuakeServer.Q.solid(:bsp) / 1)
    |> Edicts.put(0, "movetype", QuakeServer.Q.movetype(:push) / 1)
    |> Edicts.put(0, "mins", world.mins)
    |> Edicts.put(0, "maxs", world.maxs)
    |> Edicts.put(0, "absmin", world.mins)
    |> Edicts.put(0, "absmax", world.maxs)
  end

  defp put_game_mode(qc, server) do
    coop = cvar(server, "coop")

    if QuakeC.global?(qc, "coop") and coop != 0,
      do: QuakeC.put_global(qc, "coop", coop),
      else: QuakeC.put_declared(qc, "deathmatch", cvar(server, "deathmatch"))
  end

  defp clear_slots(server),
    do: Enum.reduce(1..server.slots//1, server, &Edicts.clear(&2, &1))

  defp name_level(server) do
    server = Edicts.put(server, 0, "angles", {0.0, 0.0, 0.0})

    levelname =
      if QuakeC.field_type(server.qc, "message") == :string,
        do: Edicts.string(server, 0, "message"),
        else: server.map

    %{server | ext: Map.put(server.ext, :levelname, levelname)}
  end

  defp hook(server, name, args) do
    server
    |> set_globals(0, 0)
    |> put_args(args)
    |> call_named(name)
  end

  defp put_args(server, args) do
    qc =
      args
      |> Enum.with_index()
      |> Enum.reduce(server.qc, fn {value, i}, qc -> QuakeC.put_slot(qc, 4 + 3 * i, value) end)

    %{server | qc: qc}
  end

  defp spawn_parms(server, nil) do
    server =
      server
      |> set_globals(0, 0)
      |> call_named("SetNewParms")

    {server, %{parms: parms(server), string: parm_string(server)}}
  end

  defp spawn_parms(server, parms) when is_list(parms), do: {server, %{parms: parms, string: nil}}

  defp spawn_parms(server, %{parms: parms} = carried),
    do: {server, %{parms: parms, string: Map.get(carried, :string)}}

  defp set_up_client_edict(server, player) do
    info = server.ext |> Map.get(:userinfo, %{}) |> Map.get(player, %{})
    colours = 16 * colour(info, "topcolor") + colour(info, "bottomcolor")

    server
    |> clear_client(player)
    |> Edicts.put(player, "netname", player_name(server, player))
    |> Edicts.put(player, "colormap", player / 1)
    |> Edicts.put(player, "clientcolors", colours / 1)
    |> Edicts.put(player, "gravity", 1.0)
    |> Edicts.put(player, "maxspeed", cvar(server, "sv_maxspeed"))
    |> Edicts.put(player, "movetype", QuakeServer.Q.movetype(:noclip) / 1)
    |> Edicts.put(player, "frags", 0.0)
  end

  defp colour(info, key) do
    case Integer.parse(Map.get(info, key, "0")) do
      {colour, _} when colour in 0..13 -> colour
      _ -> 0
    end
  end

  defp clear_client(%__MODULE__{qc: %{progs: %{crc: @netquake_crc}}} = server, _player),
    do: server

  defp clear_client(server, player), do: Edicts.clear(server, player)

  defp clear_netquake_client(%__MODULE__{qc: %{progs: %{crc: @netquake_crc}}} = server, player),
    do: Edicts.clear(server, player)

  defp clear_netquake_client(server, _player), do: server

  defp keep_old_origin(server, player),
    do: Edicts.put(server, player, "oldorigin", Edicts.vector(server, player, "origin"))

  defp run_empty_command(server, player) do
    if Command.program_moves?(server) do
      command = %{
        angles: Edicts.vector(server, player, "v_angle"),
        forward: 0.0,
        side: 0.0,
        up: 0.0,
        buttons: 0,
        impulse: 0,
        msec: 0
      }

      Command.run(server, player, command, independent?: false)
    else
      server
    end
  end

  defp serverflags(server) do
    if QuakeC.global?(server.qc, "serverflags"),
      do: QuakeC.float(QuakeC.global(server.qc, "serverflags")),
      else: server.serverflags / 1
  end

  defp parm_string(server) do
    with true <- QuakeC.global?(server.qc, "parm_string"),
         value when value not in [0, nil] <- QuakeC.global(server.qc, "parm_string") do
      QuakeC.string(server.qc, value)
    else
      _ -> nil
    end
  end

  defp put_startspot(server, nil), do: server

  defp put_startspot(server, startspot) do
    %{server | qc: QuakeC.put_declared(server.qc, "startspot", startspot)}
    |> QuakeServer.Extensions.Settings.put_info(0, "*startspot", startspot)
  end

  defp bsp_version(%{game: :half_life}), do: "30"
  defp bsp_version(_bsp), do: ""

  defp quakeworld_start_frame(%__MODULE__{qc: %{progs: %{crc: @quakeworld_crc}}} = server) do
    %{server | time: 0.0}
    |> set_globals(0, 0)
    |> call_named("StartFrame")
  end

  defp quakeworld_start_frame(server), do: server

  defp default_dimension_send(qc) do
    cond do
      not QuakeC.global?(qc, "dimension_send") ->
        qc

      QuakeC.float(QuakeC.global(qc, "dimension_send")) != 0 ->
        qc

      QuakeC.global?(qc, "dimension_default") ->
        QuakeC.put_global(qc, "dimension_send", QuakeC.global(qc, "dimension_default"))

      true ->
        QuakeC.put_global(qc, "dimension_send", 255.0)
    end
  end

  defp settle(server) do
    server = %{server | time: 1.0, clock: 1.1, frametime: 0.1}
    server = %{server | qc: QuakeC.put_global(server.qc, "frametime", 0.1)}
    server |> Physics.frame() |> advance(0.1) |> Physics.frame() |> advance(0.1)
  end

  defp parms(server) do
    for i <- 1..@spawn_parms do
      name = "parm#{i}"

      if QuakeC.global?(server.qc, name),
        do: QuakeC.float(QuakeC.global(server.qc, name)),
        else: 0.0
    end
  end

  defp put_parms(server, %{parms: parms, string: string}) do
    qc =
      parms
      |> Enum.with_index(1)
      |> Enum.reduce(server.qc, fn {value, i}, qc ->
        QuakeC.put_declared(qc, "parm#{i}", value)
      end)
      |> QuakeC.put_declared("parm_string", string || 0)

    %{server | qc: qc}
  end
end
