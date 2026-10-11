defmodule QuakeServer.Runner do
  @moduledoc """
  A level running in a process of its own, on its own clock, as FTE's listen server runs
  one for its own client (`SV_Frame`, `SV_Physics`): the host clock follows real time,
  and physics frames catch up to it whenever it is at least the cvar `sv_mintic` ahead,
  each frame as long as it is ahead up to `sv_maxtic`; after `sv_limittics` frames of
  `sv_maxtic` the rest is dropped. A player's command runs as it arrives
  (`QuakeServer.Server.client_command/3`), covering its `msec` milliseconds when given,
  else its `timelength` in whole milliseconds, up to 250. A command's `sequence` (the
  client's number for it) is the one the server acknowledges in every packet after it
  runs, as FTE's server sends a client's `last_sequence` (`PEXT2_PREDINFO`): 0 when the
  program does not run its players' commands itself, telling the client it cannot
  predict.

      {:ok, runner} = QuakeServer.Runner.start_link(map: "c0a0", server: [source: MyGame.Source])

      QuakeServer.Runner.subscribe(runner, self())
      receive do
        {QuakeServer.Runner, {:serverdata, %{level: level}}} ->
          QuakeServer.Runner.begin(runner, level, csqc: true)
      end
      QuakeServer.Runner.command(runner, command)
      receive do
        {QuakeServer.Runner, %{level: level, packets: packets}} -> ...
      end

      table = QuakeServer.Runner.handoff(runner)
      %{events: events, listener: at, setangle: angles} = QuakeServer.Runner.take(table)

  A level starts without the player, as FTE's `SV_SpawnServer` does. The subscribed
  client is sent `{QuakeServer.Runner, {:serverdata, serverdata}}` (`t:serverdata/0`),
  what FTE sends a client from `svc_serverdata` to the `spawn` command: the level, a
  number counting up from 1 with each level started, its map and name, the model and
  sound lists, the server's info keys but `mapname` (FTE's `fullserverinfo`), and the
  signon messages (`QuakeServer.Signon`); then a message with no packets carrying every
  light style. A client subscribing later is sent the same for the level as it stands.
  The client loaded, `begin/3` brings the player in (`QuakeServer.Server.connect/3`),
  as FTE's `begin` does, and sets the view (FTE's `svc_setangle`, `FIXANGLE_FIXED`): the
  player's `angles` while its `fixangle` is set, else its `v_angle`, roll included;
  `fixangle` is then cleared. A `begin` for a level other than the current one is
  ignored, and one for a player already in the game runs the program's `RestoreGame` and
  sets the view again.

  Until the player is in the game the level is paused, as FTE pauses a single player
  server with nobody spawned: no physics frames run, the host clock moves on only while
  it stays at or below 1.5, and commands and requests are ignored.

  Each server frame ends with `QuakeServer.Network.frame/2` and
  `QuakeServer.Animation.sample/1`; when a command has arrived since the last packet,
  the player is sent one, as FTE sends a client a packet for each it receives. The
  subscribed client gets each as the message `{QuakeServer.Runner, snapshot}`, a
  `t:snapshot/0`: the packet in `packets`, as `%{reliable: [binary], entities: [update],
  animation: %{entity => state}, datagram: [binary], sequence: integer}` (the reliable
  messages queued for the player, `QuakeServer.Outbox`, the entity updates, the
  animation states the player lacks, `QuakeServer.Animation.take/2`, the datagram, and
  the sequence of the last command the server ran), the
  light styles set or changed since the last message (`%{style => pattern}`, as FTE
  sends `svc_lightstyle`) and their colours (`lightstyle_colours`, `%{style => {r, g,
  b}}`), the server's info keys (`serverinfo`), the server's time, its model list, and
  the level with its map.

  A level change the program asks for is followed between frames, the clock waiting, as
  FTE's `changelevel` (`SV_Map_f`): the player's spawn parameters and `parm_string`
  (`QuakeServer.Server.save_spawn_parms/1`), the program's `serverflags`, its written
  files with their entity tables (`QuakeServer.EntityTable`), the server's info keys and
  the player's info keys are carried. With a landmark
  the level left is kept for a return, as FTE's level cache keeps it: a program that
  saves levels itself has it saved (`QuakeServer.Server.save_level/1`), and on a return
  through a landmark the level starts afresh with the console variables of the save and
  is restored from it (`QuakeServer.Server.load_level/2`); for another program the
  player is taken out (`QuakeServer.Server.disconnect/1`), the level is kept as it
  stands and brought back as it was left (`QuakeServer.Server.resume/2`). Without a
  landmark the level left and the kept levels are released
  (`QuakeServer.Server.release/1`) and the saves forgotten. The reliable messages still queued for the
  player are sent as a last packet, then `{QuakeServer.Runner, {:changing, map}}`, as
  FTE stuffs `changing`; the next level starts without the player.

  After every frame and command the runner puts in its handoff table (`handoff/1`) the
  events since, where the player's eye is, and the view angles the server set
  (`fixangle`): `{pitch, yaw, roll}`, `{:turn, yaw}` for a turn to add (`fixangle` 2).
  `take/1` empties it of events and angles without waiting on the runner. The handoff
  also holds whether the player stands on the ground and how fast they move.

  `console/2` runs console commands in the level's server, as FTE's host console
  does. Every level the runner starts uses one console variable table, as FTE's one
  process has one: the server option `:cvar_table`, or a table of the runner's own.

  A program error (`QuakeC.Exec.Error`, raised by the program's `error` builtin with
  `developer` 0 or by the machine) ends the server, as FTE's `SV_Error` and
  `Host_EndGame` do: the level and the kept levels are released, the reason
  `"SV_Error: " <> message <> "\\n"` is put in the handoff table (`ended` in `take/1`) and
  the subscribed client is sent `{QuakeServer.Runner, {:ended, reason}}`, as is a client
  that subscribes after, and the table no longer counts a server as running
  (`QuakeServer.Cvars.running?/2`). The runner then stays up with no server: commands, requests and
  console commands are ignored and the clock stops.
  """

  use GenServer

  alias Cauldron3D.Vec
  alias QuakeServer.{Animation, Cvars, Edicts, Network, Outbox, Server, Signon}
  alias QuakeServer.Extensions.Strings
  alias QuakeServer.Physics.Command

  @player 1
  @paused_clock 1.5

  @typedoc "What a client takes of the world (`snapshot/1`)."
  @type snapshot :: %{
          level: pos_integer(),
          map: String.t(),
          model_names: [String.t()],
          packets: [
            %{
              reliable: [binary()],
              entities: list(),
              animation: %{pos_integer() => Animation.state()},
              datagram: [binary()],
              sequence: non_neg_integer()
            }
          ],
          lightstyles: %{non_neg_integer() => term()},
          lightstyle_colours: %{non_neg_integer() => tuple()},
          serverinfo: %{String.t() => String.t()},
          time: float()
        }

  @typedoc "What a client is sent when a level starts, before it begins."
  @type serverdata :: %{
          level: pos_integer(),
          map: String.t(),
          levelname: String.t(),
          model_names: [String.t()],
          sound_names: [String.t()],
          serverinfo: %{String.t() => String.t()},
          signon: [binary()]
        }

  @doc """
  Start level `:map` with `Server.start/2` options `:server`; with `held: true` the level
  is not loaded until `load/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Load the level a runner started with `held: true` was given."
  @spec load(pid()) :: :ok
  def load(runner), do: GenServer.cast(runner, :load)

  @doc "Use `command` for the player from the next frame on."
  @spec command(pid(), Server.command() | map()) :: :ok
  def command(runner, command), do: GenServer.cast(runner, {:command, command})

  @doc "Run the player's client program request `name` with `values` (`QuakeServer.Requests`)."
  @spec request(pid(), String.t(), [{String.t(), term()}]) :: :ok
  def request(runner, name, values), do: GenServer.cast(runner, {:request, name, values})

  @doc "Send the player's packets to `client` from now on, starting with the level as it stands."
  @spec subscribe(pid(), pid()) :: :ok
  def subscribe(runner, client), do: GenServer.cast(runner, {:subscribe, client})

  @doc """
  Bring the player into level `level`, its client having loaded it, as FTE's `begin`;
  option `csqc: true` when the client runs a client program (FTE's `enablecsqc`).
  """
  @spec begin(pid(), pos_integer(), keyword()) :: :ok
  def begin(runner, level, opts \\ []), do: GenServer.cast(runner, {:begin, level, opts})

  @doc "Run console commands `text` in the level (`QuakeServer.Console.run/2`)."
  @spec console(pid(), String.t()) :: :ok
  def console(runner, text), do: GenServer.cast(runner, {:console, text})

  @doc "The table the runner hands its events, the player's eye and view angles over in."
  @spec handoff(pid()) :: :ets.tid()
  def handoff(runner), do: GenServer.call(runner, :handoff, :infinity)

  @doc """
  The events put in `table` since the last take, oldest first, the player's eye, the
  last view angles the server set since, or `nil`, whether the player stands on the
  ground (`onground`) and their velocity, the reason the server ended (`ended`), or
  `nil` while it runs, and the level's map (`map`), or `nil` before the first.
  """
  @spec take(:ets.tid()) :: %{
          events: [term()],
          listener: Vec.t(),
          setangle: term(),
          onground: boolean(),
          velocity: Vec.t(),
          ended: String.t() | nil,
          map: String.t() | nil
        }
  def take(table) do
    events =
      for {key, _} <- :ets.select(table, [{{:"$1", :_}, [{:is_integer, :"$1"}], [:"$_"]}]),
          [{_, event}] <- [:ets.take(table, key)],
          do: event

    setangle =
      case :ets.take(table, :setangle) do
        [{_, angles}] -> angles
        [] -> nil
      end

    listener = kept(table, :listener, {0.0, 0.0, 0.0})
    {onground, velocity} = kept(table, :motion, {false, {0.0, 0.0, 0.0}})

    %{
      events: events,
      listener: listener,
      setangle: setangle,
      onground: onground,
      velocity: velocity,
      ended: kept(table, :ended, nil),
      map: kept(table, :map, nil)
    }
  end

  defp kept(table, key, default) do
    case :ets.lookup(table, key) do
      [{_, value}] -> value
      [] -> default
    end
  end

  @impl true
  def init(opts) do
    state = %{
      server: nil,
      options: opts |> Keyword.fetch!(:server) |> Keyword.put_new_lazy(:cvar_table, &Cvars.new/0),
      command: %{
        forward: 0.0,
        side: 0.0,
        up: 0.0,
        angles: {0.0, 0.0, 0.0},
        buttons: 0,
        impulse: 0
      },
      events: [],
      setangle: nil,
      levels: %{},
      level: 0,
      spawned: false,
      parms: nil,
      userinfo: %{},
      styles_sent: %{},
      colours_sent: %{},
      sending: false,
      client: nil,
      handoff: :ets.new(__MODULE__, [:ordered_set, :public]),
      handed: 0,
      last: nil,
      acknowledged: 0,
      ended: nil
    }

    map = Keyword.fetch!(opts, :map)

    if Keyword.get(opts, :held, false),
      do: {:ok, Map.put(state, :held_map, map)},
      else: {:ok, state, {:continue, {:start, map}}}
  end

  @impl true
  def handle_continue({:start, map}, state),
    do: {:noreply, running(state, &start_level(&1, map))}

  @impl true
  def handle_cast(:load, %{held_map: map} = state),
    do: {:noreply, Map.delete(state, :held_map), {:continue, {:start, map}}}

  def handle_cast(:load, state), do: {:noreply, state}

  @impl true
  def handle_cast({:request, name, values}, %{spawned: true} = state),
    do: {:noreply, running(state, &run_request(&1, name, values))}

  def handle_cast({:request, _name, _values}, state), do: {:noreply, state}

  def handle_cast({:console, text}, state),
    do: {:noreply, running(state, &run_console(&1, text))}

  def handle_cast({:subscribe, client}, %{server: nil, ended: nil} = state),
    do: {:noreply, %{state | client: client, styles_sent: %{}, colours_sent: %{}}}

  def handle_cast({:subscribe, client}, %{ended: nil} = state) do
    state = %{state | client: client, styles_sent: %{}, colours_sent: %{}}
    {:noreply, state |> send_serverdata() |> push([])}
  end

  def handle_cast({:subscribe, client}, state) do
    send(client, {__MODULE__, {:ended, state.ended}})
    {:noreply, %{state | client: client}}
  end

  def handle_cast({:begin, level, opts}, %{level: level} = state),
    do: {:noreply, running(state, &begin_player(&1, opts))}

  def handle_cast({:begin, _level, _opts}, state), do: {:noreply, state}

  def handle_cast({:command, command}, %{spawned: true} = state),
    do: {:noreply, running(state, &run_command(&1, command))}

  def handle_cast({:command, _command}, state), do: {:noreply, state}

  @impl true
  def handle_call(:handoff, _from, state), do: {:reply, state.handoff, state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, running(state, &tick/1)}

  defp start_level(state, map) do
    server = Server.start(map, state.options)
    state |> arrive(server) |> publish() |> tick_soon()
  end

  defp begin_player(%{spawned: true, server: server} = state, _opts) do
    server = server |> Server.set_globals(@player, 0) |> Server.call_named("RestoreGame")
    %{state | server: server} |> begin_angle() |> publish()
  end

  defp begin_player(state, opts) do
    server =
      state.server
      |> Server.connect(state.parms, csqc: Keyword.get(opts, :csqc, false))
      |> Network.watch(@player)

    {events, server} = Server.drain(server)

    %{state | server: server, spawned: true, events: Enum.reverse(events, state.events)}
    |> begin_angle()
    |> publish()
  end

  defp begin_angle(%{server: server} = state) do
    field = if Edicts.float(server, @player, "fixangle") != 0, do: "angles", else: "v_angle"
    angles = Edicts.vector(server, @player, field)
    %{state | setangle: angles, server: Edicts.put(server, @player, "fixangle", 0.0)}
  end

  defp run_request(state, name, values) do
    server = QuakeServer.Requests.run(state.server, @player, name, values)
    {events, server} = Server.drain(server)
    publish(%{state | server: server, events: Enum.reverse(events, state.events)})
  end

  defp run_console(state, text) do
    server = QuakeServer.Console.run(state.server, text)
    {events, server} = Server.drain(server)

    publish(%{state | server: server, events: Enum.reverse(events, state.events)})
  end

  defp run_command(state, command) do
    msec = command |> command_msec() |> max(0) |> min(250)
    command = Map.put(command, :msec, msec)
    acknowledged = acknowledged(state.server, command)
    server = Server.client_command(state.server, @player, command)
    {events, server} = Server.drain(server)
    {setangle, ext} = Map.pop(server.ext, :setangle)

    state = %{
      state
      | server: %{server | ext: ext},
        command: command,
        acknowledged: acknowledged,
        sending: true,
        events: Enum.reverse(events, state.events)
    }

    state = if setangle, do: %{state | setangle: setangle}, else: state
    state |> fix_angle() |> follow() |> publish()
  end

  defp command_msec(%{msec: msec}) when is_integer(msec), do: msec

  defp command_msec(command),
    do: command |> Map.get(:timelength, 0.0) |> Kernel.*(1000) |> trunc()

  defp acknowledged(server, command) do
    if Command.program_moves?(server),
      do: Map.get(command, :sequence, 0),
      else: 0
  end

  defp tick(%{spawned: false} = state) do
    now = System.monotonic_time(:microsecond)
    advanced = Server.advance(state.server, (now - state.last) / 1_000_000)
    server = if advanced.clock > @paused_clock, do: state.server, else: advanced
    %{state | server: server, last: now} |> publish() |> tick_soon()
  end

  defp tick(state) do
    now = System.monotonic_time(:microsecond)
    server = Server.advance(state.server, (now - state.last) / 1_000_000)
    limit = trunc(Server.cvar(server, "sv_limittics"))

    %{state | server: server, last: now}
    |> frames(limit)
    |> deliver()
    |> follow()
    |> publish()
    |> tick_soon()
  end

  defp frames(%{server: server} = state, left) do
    tics = {Server.cvar(server, "sv_mintic"), Server.cvar(server, "sv_maxtic")}
    frames(state, left, server.clock - server.time, tics)
  end

  defp frames(state, _left, seconds, _tics) when seconds < 0, do: caught_up(state)

  defp frames(state, _left, seconds, {shortest, _longest})
       when seconds <= 0 or seconds < shortest,
       do: state

  defp frames(state, left, seconds, {_shortest, longest})
       when seconds > longest and longest > 0 and left <= 0,
       do: caught_up(state)

  defp frames(state, left, seconds, {_shortest, longest}) when seconds > longest and longest > 0,
    do: state |> frame(longest) |> frames(left - 1)

  defp frames(state, left, seconds, _tics), do: state |> frame(seconds) |> frames(left)

  defp caught_up(%{server: server} = state), do: %{state | server: %{server | time: server.clock}}

  defp frame(state, seconds) do
    server = Server.frame(state.server, seconds, state.command)
    {events, server} = Server.drain(server)
    fix_angle(%{state | server: server, events: Enum.reverse(events, state.events)})
  end

  defp deliver(state) do
    sending = if state.sending, do: [@player], else: []
    {updates, server} = Network.frame(state.server, sending)
    state = %{state | server: Animation.sample(server), sending: false}

    case Map.fetch(updates, @player) do
      {:ok, entities} -> send_packet(state, entities)
      :error -> state
    end
  end

  defp send_packet(state, entities) do
    {packet, server} = Outbox.take(state.server, @player)
    {animation, server} = Animation.take(server, @player)

    packet =
      packet
      |> Map.put(:entities, entities)
      |> Map.put(:animation, animation)
      |> Map.put(:sequence, state.acknowledged)

    push(%{state | server: server}, [packet])
  end

  defp send_serverdata(%{client: nil} = state), do: state

  defp send_serverdata(%{server: server} = state) do
    serverdata = %{
      level: state.level,
      map: server.map,
      levelname: Map.get(server.ext, :levelname, server.map),
      model_names: server.model_names,
      sound_names: server.sound_names,
      serverinfo: server.ext |> Map.get(:serverinfo, %{}) |> Map.delete("mapname"),
      signon: Signon.messages(server)
    }

    send(state.client, {__MODULE__, {:serverdata, serverdata}})
    state
  end

  defp push(%{client: nil} = state, _packets), do: state

  defp push(%{server: server} = state, packets) do
    styles =
      Map.reject(server.lightstyles, fn {style, value} -> state.styles_sent[style] == value end)

    colours = Map.get(server.ext, :lightstyle_rgb, %{})

    colours =
      Map.reject(colours, fn {style, value} -> state.colours_sent[style] == value end)

    send(
      state.client,
      {__MODULE__,
       %{
         level: state.level,
         map: server.map,
         model_names: server.model_names,
         packets: packets,
         lightstyles: styles,
         lightstyle_colours: colours,
         serverinfo: Map.get(server.ext, :serverinfo, %{}),
         time: server.time
       }}
    )

    %{
      state
      | styles_sent: Map.merge(state.styles_sent, styles),
        colours_sent: Map.merge(state.colours_sent, colours)
    }
  end

  defp publish(state) do
    state.events
    |> Enum.reverse()
    |> Enum.with_index(state.handed)
    |> Enum.each(fn {event, key} -> :ets.insert(state.handoff, {key, event}) end)

    if state.setangle, do: :ets.insert(state.handoff, {:setangle, state.setangle})
    :ets.insert(state.handoff, {:listener, eye(state.server)})
    :ets.insert(state.handoff, {:motion, motion(state.server)})
    :ets.insert(state.handoff, {:map, state.server.map})
    %{state | events: [], setangle: nil, handed: state.handed + length(state.events)}
  end

  defp fix_angle(%{server: server} = state),
    do: fix_angle(state, Edicts.float(server, @player, "fixangle"))

  defp fix_angle(state, fixangle) when fixangle == 0, do: state

  defp fix_angle(%{server: server} = state, fixangle) when fixangle == 2 do
    {_, yaw, _} = Edicts.vector(server, @player, "v_angle")
    %{state | setangle: {:turn, yaw}, server: Edicts.put(server, @player, "fixangle", 0.0)}
  end

  defp fix_angle(%{server: server} = state, _fixangle) do
    {pitch, yaw, _} = Edicts.vector(server, @player, "angles")
    %{state | setangle: {pitch, yaw, 0.0}, server: Edicts.put(server, @player, "fixangle", 0.0)}
  end

  defp follow(%{server: %{changelevel: nil}} = state), do: state

  defp follow(%{server: server} = state) do
    saved = Server.save_spawn_parms(server)
    map = server.changelevel |> String.split() |> hd()
    startspot = server.changelevel_startspot
    {stored, left} = store_level(server, startspot)
    {events, left} = Server.drain(left)
    {packet, left} = Outbox.take(left, @player)

    state =
      %{
        state
        | server: left,
          spawned: false,
          parms: carried_parms(saved, state.parms),
          userinfo: player_info(left),
          events: Enum.reverse(events, state.events)
      }
      |> last_packet(packet)

    if state.client, do: send(state.client, {__MODULE__, {:changing, map}})

    carried = [
      startspot: startspot,
      written: Map.get(left.ext, :written, %{}),
      entity_tables: Map.get(left.ext, :entity_tables, %{}),
      serverflags: saved.serverflags,
      serverinfo: Map.get(left.ext, :serverinfo, %{})
    ]

    levels = keep(state.levels, left, stored)

    next =
      case startspot && Map.get(levels, map) do
        nil -> Server.start(map, Keyword.merge(state.options, carried))
        {:saved, text} -> restore(map, text, Keyword.merge(state.options, carried))
        kept -> Server.resume(kept, carried)
      end

    %{state | levels: Map.delete(levels, map)}
    |> arrive(next)
    |> Map.put(:last, System.monotonic_time(:microsecond))
  end

  defp carried_parms(%{parms: nil}, parms), do: parms
  defp carried_parms(saved, _parms), do: Map.take(saved, [:parms, :string])

  defp player_info(server), do: server.ext |> Map.get(:userinfo, %{}) |> Map.get(@player, %{})

  defp last_packet(state, %{reliable: []}), do: state

  defp last_packet(state, packet),
    do: push(state, [%{reliable: packet.reliable, entities: [], datagram: []}])

  defp store_level(server, nil), do: {nil, server}

  defp store_level(server, _startspot) do
    if Server.saves_levels?(server) do
      {text, server} = Server.save_level(server)
      {{:saved, text}, server}
    else
      {:kept, Server.disconnect(server)}
    end
  end

  defp keep(levels, server, nil) do
    Enum.each([server | kept_servers(levels)], &Server.release/1)
    %{}
  end

  defp keep(levels, server, {:saved, _text} = saved) do
    Server.release(server)
    Map.put(levels, server.map, saved)
  end

  defp keep(levels, server, :kept), do: Map.put(levels, server.map, server)

  defp kept_servers(levels), do: for(%Server{} = kept <- Map.values(levels), do: kept)

  defp restore(map, text, options) do
    saved = Server.saved_level(text)

    options =
      options
      |> Keyword.update(:cvars, saved.cvars, &Map.merge(Map.new(&1), saved.cvars))
      |> put_saved_skill(Map.get(saved.cvars, "skill"))

    map |> Server.start(options) |> Server.load_level(text)
  end

  defp put_saved_skill(options, nil), do: options

  defp put_saved_skill(options, skill),
    do: Keyword.put(options, :skill, Strings.number(skill))

  defp arrive(state, server) do
    userinfo =
      server.ext
      |> Map.get(:userinfo, %{})
      |> Map.update(@player, state.userinfo, &Map.merge(&1, state.userinfo))

    server = %{server | ext: server.ext |> Map.delete(:network) |> Map.put(:userinfo, userinfo)}

    %{
      state
      | server: server,
        level: state.level + 1,
        spawned: false,
        styles_sent: %{},
        colours_sent: %{}
    }
    |> send_serverdata()
    |> push([])
  end

  defp running(%{ended: nil} = state, run) do
    run.(state)
  rescue
    error in QuakeC.Exec.Error -> end_game(state, error.message)
  end

  defp running(state, _run), do: state

  defp end_game(state, message) do
    reason = "SV_Error: " <> message <> "\n"
    Enum.each(List.wrap(state.server) ++ Map.values(state.levels), &Server.release/1)
    Cvars.put_running(Keyword.fetch!(state.options, :cvar_table), :server, false)
    :ets.insert(state.handoff, {:ended, reason})
    if state.client, do: send(state.client, {__MODULE__, {:ended, reason}})
    %{state | server: nil, levels: %{}, ended: reason, events: [], setangle: nil}
  end

  defp motion(server),
    do: {Edicts.flag?(server, @player, :onground), Edicts.vector(server, @player, "velocity")}

  defp eye(server),
    do:
      Vec.add(
        Edicts.vector(server, @player, "origin"),
        Edicts.vector(server, @player, "view_ofs")
      )

  defp tick_soon(state) do
    state = if state.last, do: state, else: %{state | last: System.monotonic_time(:microsecond)}
    Process.send_after(self(), :tick, max(ceil(Server.cvar(state.server, "sv_mintic") * 1000), 1))
    state
  end
end
