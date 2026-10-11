defmodule QuakeServer.Physics do
  @moduledoc """
  One physics frame of a level, as FTE's server runs it (`sv_phys.c`): the program's
  `StartFrame`, then every entity by its move type (`WPhys_RunEntity`), then `EndFrame`,
  and the clock moved on by the frame.

      server = QuakeServer.Physics.frame(server)

  The program's `time` is the frame's start for everything run in it, and its end for
  `EndFrame`. An entity whose `customphysics` holds a function has that run instead of
  its move type. A player whose commands the program runs itself
  (`QuakeServer.Physics.Command`) is left out: its commands move it. Any other player
  runs its command (`QuakeServer.Player`), then `PlayerPreThink`, its move, and
  `PlayerPostThink`. After each entity, the missile it may have spawned (`newmis`) runs
  at once, for a twentieth of a second.
  """

  alias Cauldron3D.Vec
  alias QuakeC.Exec
  alias QuakeServer.{Angles, Contents, Edicts, Player, Server, Sounds, World}
  alias QuakeServer.Physics.{Command, Move, Pusher, Walk}

  @step 18.0

  @doc "Run `server`'s entities for one frame of `server.frametime` seconds and move its clock on."
  @spec frame(Server.t()) :: Server.t()
  def frame(%Server{} = server) do
    server =
      server
      |> Server.set_globals(0, 0)
      |> Server.call_named("StartFrame")

    retouch? = retouch(server) >= 1
    server = each(server, 0, retouch?)
    server = if retouch?, do: put(server, "force_retouch", retouch(server) - 1), else: server

    end_time = server.time + server.frametime

    server
    |> Server.set_globals(0, 0)
    |> put("time", end_time)
    |> Server.call_named("EndFrame")
    |> then(&%{&1 | time: end_time, clock: max(&1.clock, end_time)})
  end

  @doc """
  Run `entity`'s think if it is due before the frame ends, at the time it was due (the
  frame's start when that has passed), again while it sets a later `nextthink` still due
  this frame and the cvar `sv_gameplayfix_multiplethinks` is on (`WPhys_RunThink`).
  Returns `{server, still_there?}`.
  """
  @spec think(Server.t(), non_neg_integer()) :: {Server.t(), boolean()}
  def think(%Server{} = server, entity) do
    at = Edicts.float(server, entity, "nextthink")

    if at <= 0 or at > server.time + server.frametime do
      {server, true}
    else
      thinktime = max(at, server.time)
      server = think_once(server, entity, thinktime)

      cond do
        Edicts.free?(server, entity) -> {server, false}
        Server.cvar(server, "sv_gameplayfix_multiplethinks") == 0 -> {server, true}
        Edicts.float(server, entity, "nextthink") <= thinktime -> {server, true}
        true -> think(server, entity)
      end
    end
  end

  @doc "Bound `entity`'s velocity to the length `sv_maxvelocity` (`WPhys_CheckVelocity`)."
  @spec check_velocity(Server.t(), non_neg_integer()) :: Server.t()
  def check_velocity(%Server{} = server, entity) do
    limit = Server.cvar(server, "sv_maxvelocity")
    velocity = Edicts.vector(server, entity, "velocity")
    speed = Vec.length(velocity)

    if speed > limit,
      do: Edicts.put(server, entity, "velocity", Vec.scale(velocity, limit / speed)),
      else: server
  end

  @doc "Run `entity` for the frame by its move type (`WPhys_RunEntity`)."
  @spec run_entity(Server.t(), non_neg_integer()) :: Server.t()
  def run_entity(%Server{slots: slots} = server, 1) when slots >= 1 do
    cond do
      server.parms == nil or independent?(server, 1) -> server
      Command.program_moves?(server) -> rerun_command(server, 1)
      true -> run_client(server, 1)
    end
  end

  def run_entity(%Server{} = server, entity), do: run_movetype(server, entity)

  @doc "Run the missile the program last spawned (`newmis`), for a twentieth of a second, and clear `newmis`."
  @spec run_newmis(Server.t()) :: Server.t()
  def run_newmis(%Server{} = server) do
    case QuakeC.global?(server.qc, "newmis") and
           trunc(QuakeC.float(QuakeC.global(server.qc, "newmis"))) do
      missile when is_integer(missile) and missile > 0 ->
        if Server.cvar(server, "sv_gameplayfix_multiplethinks") == 0 do
          server
        else
          frametime = server.frametime

          %{put(server, "newmis", 0) | frametime: 0.05}
          |> run_entity(missile)
          |> then(&%{&1 | frametime: frametime})
        end

      _ ->
        server
    end
  end

  @doc "Whether player `entity` runs its own commands (`QuakeServer.Physics.Command`), so a frame leaves it out."
  @spec independent?(Server.t(), non_neg_integer()) :: boolean()
  def independent?(%Server{} = server, entity),
    do: MapSet.member?(Map.get(server.ext, :independent, MapSet.new()), entity)

  @doc "Mark player `entity` as running its own commands."
  @spec independent(Server.t(), non_neg_integer()) :: Server.t()
  def independent(%Server{} = server, entity) do
    marked = server.ext |> Map.get(:independent, MapSet.new()) |> MapSet.put(entity)
    %{server | ext: Map.put(server.ext, :independent, marked)}
  end

  @doc "Run the touches of two entities that have met, from `trace`."
  @spec impact(Server.t(), non_neg_integer(), map()) :: Server.t()
  def impact(%Server{} = server, entity, trace), do: Move.impact(server, entity, trace)

  @doc "The height of a step, FTE's `movevars.stepheight`: the cvar `pm_stepheight`, or 18 while it is empty."
  @spec step_size(Server.t()) :: float()
  def step_size(%Server{} = server) do
    if Server.cvar_string(server, "pm_stepheight") == "",
      do: @step,
      else: Server.cvar(server, "pm_stepheight") / 1
  end

  defp each(server, index, _retouch?) when index >= server.count, do: server

  defp each(server, index, retouch?) do
    server =
      if Edicts.free?(server, index) do
        server
      else
        server = if retouch?, do: World.link(server, index, true), else: server
        server |> run_entity(index) |> run_newmis()
      end

    each(server, index + 1, retouch?)
  end

  defp rerun_command(server, entity) do
    command = Map.put(server.command || %{}, :msec, trunc(server.frametime * 1000))
    Command.run(server, entity, command, independent?: false)
  end

  defp run_client(server, entity) do
    server =
      server
      |> Player.think(entity, server.command)
      |> Server.set_globals(entity, QuakeC.global(server.qc, "other"))
      |> Server.call_named("PlayerPreThink")
      |> run_movetype(entity)

    if Edicts.free?(server, entity) do
      server
    else
      server
      |> World.link(entity, true)
      |> Server.set_globals(entity, QuakeC.global(server.qc, "other"))
      |> Server.call_named("PlayerPostThink")
    end
  end

  defp run_movetype(server, entity) do
    case custom_physics(server, entity) do
      0 ->
        by_movetype(server, entity, Edicts.int(server, entity, "movetype"))

      function ->
        server
        |> Server.set_globals(entity, QuakeC.global(server.qc, "other"))
        |> then(&Exec.call(&1, function, &1.builtins, Server.exec_opts(&1)))
    end
  end

  defp by_movetype(server, entity, movetype) when movetype in [7, 13],
    do: Pusher.run(server, entity)

  defp by_movetype(server, entity, 0), do: server |> think(entity) |> elem(0)
  defp by_movetype(server, entity, movetype) when movetype in [1, 8], do: noclip(server, entity)
  defp by_movetype(server, entity, 4), do: step(server, entity)
  defp by_movetype(server, entity, 12), do: follow(server, entity)

  defp by_movetype(server, entity, 32) do
    case think(server, entity) do
      {server, false} -> server
      {server, true} -> World.link(server, entity, true)
    end
  end

  defp by_movetype(server, entity, movetype) when movetype in [5, 33] and entity == 1 do
    case think(server, entity) do
      {server, false} -> server
      {server, true} -> server |> Walk.check_stuck(entity) |> Walk.move(entity)
    end
  end

  defp by_movetype(server, entity, movetype) when movetype in [5, 6, 9, 10, 11, 14, 33],
    do: toss(server, entity)

  defp by_movetype(server, entity, 3), do: walk(server, entity)
  defp by_movetype(server, _entity, _movetype), do: server

  defp walk(server, entity) do
    case think(server, entity) do
      {server, false} ->
        server

      {server, true} ->
        {server, in_water?} = Walk.check_water(server, entity)

        server =
          if in_water? or Edicts.flag?(server, entity, :waterjump) or
               trunc(Edicts.float(server, entity, "pmove_flags")) |> Bitwise.band(2) != 0,
             do: server,
             else: Walk.add_gravity(server, entity)

        server = server |> Walk.check_stuck(entity) |> Walk.move(entity)
        if entity == 1, do: server, else: World.link(server, entity, true)
    end
  end

  defp noclip(server, entity) do
    case think(server, entity) do
      {server, false} ->
        server

      {server, true} ->
        dt = server.frametime

        angles =
          Vec.madd(
            Edicts.vector(server, entity, "angles"),
            Edicts.vector(server, entity, "avelocity"),
            dt
          )

        origin =
          Vec.madd(
            Edicts.vector(server, entity, "origin"),
            Edicts.vector(server, entity, "velocity"),
            dt
          )

        server
        |> Edicts.put(entity, "angles", angles)
        |> Edicts.put(entity, "origin", origin)
        |> World.link(entity, false)
    end
  end

  defp follow(server, entity) do
    case think(server, entity) do
      {server, false} -> server
      {server, true} -> attach(server, entity, Edicts.int(server, entity, "aiment"))
    end
  end

  defp attach(server, entity, leader) do
    leader_angles = Edicts.vector(server, leader, "angles")
    punch = Edicts.vector(server, entity, "punchangle")
    offset = Edicts.vector(server, entity, "view_ofs")
    leader_origin = Edicts.vector(server, leader, "origin")

    origin =
      if leader_angles == punch do
        Vec.add(leader_origin, offset)
      else
        local = turn(offset, mesh_angles(server, punch))
        {forward, right, up} = Angles.vectors(mesh_angles(server, leader_angles))

        Vec.add(
          leader_origin,
          {Vec.dot(local, forward), Vec.dot(local, right), Vec.dot(local, up)}
        )
      end

    server
    |> Edicts.put(entity, "origin", origin)
    |> Edicts.put(
      entity,
      "angles",
      Vec.add(leader_angles, Edicts.vector(server, entity, "v_angle"))
    )
    |> World.link(entity, true)
  end

  defp turn({x, y, z}, angles) do
    {forward, right, up} = Angles.vectors(angles)

    {x * elem(forward, 0) + y * elem(right, 0) + z * elem(up, 0),
     x * elem(forward, 1) + y * elem(right, 1) + z * elem(up, 1),
     x * elem(forward, 2) + y * elem(right, 2) + z * elem(up, 2)}
  end

  defp mesh_angles(server, {pitch, yaw, roll}),
    do:
      {pitch * Server.cvar(server, "r_meshpitch"), yaw, roll * Server.cvar(server, "r_meshroll")}

  defp toss(server, entity) do
    server = check_velocity(server, entity)

    case think(server, entity) do
      {server, false} -> server
      {server, true} -> toss_grounded(server, entity)
    end
  end

  defp toss_grounded(server, entity) do
    {_, _, vz} = Edicts.vector(server, entity, "velocity")

    cond do
      not Edicts.flag?(server, entity, :onground) ->
        toss_move(server, entity)

      vz >= 1 / 32 ->
        server |> Edicts.clear_flag(entity, :onground) |> toss_move(entity)

      Server.cvar(server, "sv_gameplayfix_noairborncorpse") != 0 and
          not Edicts.free?(server, Edicts.int(server, entity, "groundentity")) ->
        server

      Server.cvar(server, "sv_gameplayfix_noairborncorpse") != 0 ->
        toss_move(server, entity)

      true ->
        server
    end
  end

  defp toss_move(server, entity) do
    movetype = Edicts.int(server, entity, "movetype")

    server =
      if movetype in [5, 9, 11, 14, 33], do: server, else: Walk.add_gravity(server, entity)

    dt = server.frametime

    server =
      Edicts.put(
        server,
        entity,
        "angles",
        Vec.madd(
          Edicts.vector(server, entity, "angles"),
          Edicts.vector(server, entity, "avelocity"),
          dt
        )
      )

    move = Vec.scale(Edicts.vector(server, entity, "velocity"), dt)

    if Vec.dot(move, move) == 0 do
      if Edicts.int(server, entity, "solid") != 0 and
           Edicts.float(server, entity, "nextthink") != 0,
         do: World.link(server, entity, true),
         else: server
    else
      {server, trace} = Move.push(server, entity, move)
      bounced(server, entity, trace)
    end
  end

  defp bounced(server, _entity, %{fraction: fraction}) when fraction == 1.0, do: server
  defp bounced(server, _entity, %{hit: nil}), do: server

  defp bounced(server, entity, trace) do
    if Edicts.free?(server, entity), do: server, else: rebound(server, entity, trace)
  end

  defp rebound(server, entity, trace) do
    movetype = Edicts.int(server, entity, "movetype")
    backoff = backoff(movetype, Edicts.float(server, entity, "bouncefactor"))

    velocity =
      Move.clip_velocity(Edicts.vector(server, entity, "velocity"), trace.normal, backoff)

    server
    |> Edicts.put(entity, "velocity", velocity)
    |> settled(entity, trace, movetype, velocity)
    |> water_transition(entity)
  end

  defp backoff(10, factor) when factor != 0, do: 1 + factor
  defp backoff(10, _factor), do: 1.5
  defp backoff(11, factor) when factor != 0, do: 1 + factor
  defp backoff(11, _factor), do: 2.0
  defp backoff(_movetype, _factor), do: 1.0

  defp settled(server, entity, %{normal: {_, _, nz}} = trace, movetype, {_, _, vz}) do
    if nz > 0.7 and movetype != 11 and (vz < bounce_stop(server, entity) or movetype != 10),
      do:
        server
        |> Edicts.set_flag(entity, :onground)
        |> Edicts.put(entity, "groundentity", trace.hit || 0)
        |> Edicts.put(entity, "velocity", {0.0, 0.0, 0.0})
        |> Edicts.put(entity, "avelocity", {0.0, 0.0, 0.0}),
      else: server
  end

  defp bounce_stop(server, entity) do
    case Edicts.float(server, entity, "bouncestop") do
      stop when stop == 0 ->
        60.0

      stop ->
        gravity = Edicts.float(server, entity, "gravity")
        stop * Server.cvar(server, "sv_gravity") * if(gravity == 0, do: 1.0, else: gravity)
    end
  end

  defp step(server, entity) do
    origin = Edicts.vector(server, entity, "origin")
    {_, _, vz} = Edicts.vector(server, entity, "velocity")

    server =
      if vz >= 1 / 32 and Edicts.flag?(server, entity, :onground),
        do: Edicts.clear_flag(server, entity, :onground),
        else: server

    freefall? =
      if Edicts.flag?(server, entity, :swim),
        do: Edicts.float(server, entity, "waterlevel") <= 0,
        else: not (Edicts.flag?(server, entity, :onground) or Edicts.flag?(server, entity, :fly))

    server = if freefall?, do: fall(server, entity, vz), else: server
    {server, _} = think(server, entity)

    if Edicts.free?(server, entity) or Edicts.vector(server, entity, "origin") == origin,
      do: server,
      else: water_transition(server, entity)
  end

  defp fall(server, entity, vz) do
    hit_sound? = vz < Server.cvar(server, "sv_gravity") * -0.1

    server =
      server
      |> Walk.add_gravity(entity)
      |> check_velocity(entity)

    {server, _, _} = Move.fly(server, entity, server.frametime)
    server = World.link(server, entity, true)
    land = Server.cvar_string(server, "sv_sound_land")

    if Edicts.flag?(server, entity, :onground) and hit_sound? and land != "",
      do: Sounds.start(server, entity, 0, land, 1.0, 1.0),
      else: server
  end

  defp water_transition(server, entity) do
    bits = World.contents_world(server, Edicts.vector(server, entity, "origin"))
    contents = Contents.water_code(bits)
    type = Edicts.int(server, entity, "watertype")

    cond do
      type == 0 ->
        set_water(server, entity, contents, 1)

      type != contents and contents_transition(server, entity, type, contents) ->
        server
        |> contents_transition_run(entity, type, contents)
        |> set_water(entity, contents, 1)

      true ->
        splashed(server, entity, type, contents)
    end
  end

  defp splashed(server, entity, type, contents) when contents <= -3 do
    server = if type == -1, do: splash(server, entity), else: server
    set_water(server, entity, contents, 1)
  end

  defp splashed(server, entity, type, contents) do
    server = if type != -1, do: splash(server, entity), else: server
    set_water(server, entity, -1, contents)
  end

  defp splash(server, entity) do
    case Server.cvar_string(server, "sv_sound_watersplash") do
      "" -> server
      sound -> Sounds.start(server, entity, 0, sound, 1.0, 1.0)
    end
  end

  defp contents_transition(server, entity, _from, _to),
    do: Edicts.int(server, entity, "contentstransition") != 0

  defp contents_transition_run(server, entity, from, to) do
    function = Edicts.int(server, entity, "contentstransition")

    qc =
      server.qc
      |> QuakeC.put_slot(4, from / 1)
      |> QuakeC.put_slot(7, to / 1)

    server = %{server | qc: qc} |> Server.set_globals(entity, QuakeC.global(qc, "other"))
    Exec.call(server, function, server.builtins, Server.exec_opts(server))
  end

  defp set_water(server, entity, type, level) do
    server
    |> Edicts.put(entity, "watertype", type / 1)
    |> Edicts.put(entity, "waterlevel", level / 1)
  end

  defp think_once(server, entity, thinktime) do
    function = Edicts.int(server, entity, "think")
    server = Edicts.put(server, entity, "nextthink", 0.0)

    qc =
      server.qc
      |> QuakeC.put_global("time", thinktime)
      |> QuakeC.put_global("self", entity)
      |> QuakeC.put_global("other", 0)

    if function != 0,
      do: Exec.call(%{server | qc: qc}, function, server.builtins, Server.exec_opts(server)),
      else: %{server | qc: qc}
  end

  defp custom_physics(server, entity) do
    case QuakeC.field_offset(server.qc, "customphysics") do
      nil -> 0
      offset -> trunc(QuakeC.float(QuakeC.field_slot(server.qc, entity, offset)))
    end
  end

  defp retouch(server) do
    if QuakeC.global?(server.qc, "force_retouch"),
      do: QuakeC.float(QuakeC.global(server.qc, "force_retouch")),
      else: 0.0
  end

  defp put(server, name, value),
    do: %{server | qc: QuakeC.put_declared(server.qc, name, value / 1)}
end
