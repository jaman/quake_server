defmodule QuakeServer.Physics.Walk do
  @moduledoc """
  FTE's walking movement (`sv_phys.c`), for walking entities other than players that move
  themselves: gravity (`WPhys_AddGravity`), the water check (`WPhys_CheckWater`), getting
  out of the world when stuck (`WPhys_CheckStuck`), and the walk itself with stepping up
  and down stairs (`WPhys_WalkMove`), slowed against walls it faces (`WPhys_WallFriction`).

      server = QuakeServer.Physics.Walk.move(server, entity)

  Steps are `QuakeServer.Physics.step_size/1` high; gravity runs along -z.
  """

  import Bitwise

  alias Cauldron3D.Vec
  alias QuakeServer.{Angles, Contents, Edicts, Physics, Q, Server, World}
  alias QuakeServer.Physics.Move

  @ladder 2

  @doc "Add a frame of gravity to `entity`'s velocity, scaled by its `gravity` field (0.5 for a bouncing missile with none)."
  @spec add_gravity(Server.t(), non_neg_integer()) :: Server.t()
  def add_gravity(%Server{} = server, entity) do
    scale =
      case Edicts.float(server, entity, "gravity") do
        value when value != 0 -> value
        _ -> if Edicts.int(server, entity, "movetype") == 11, do: 0.5, else: 1.0
      end

    {x, y, z} = Edicts.vector(server, entity, "velocity")
    fall = scale * Server.cvar(server, "sv_gravity") * server.frametime
    Edicts.put(server, entity, "velocity", {x, y, z - fall})
  end

  @doc """
  Set `entity`'s `waterlevel` (0 to 3) and `watertype` from the contents at its feet,
  middle and eyes, brush entities included, and its `pmove_flags` ladder bit from the
  contents its box is in; `{server, waterlevel > 1}`.
  """
  @spec check_water(Server.t(), non_neg_integer()) :: {Server.t(), boolean()}
  def check_water(%Server{} = server, entity) do
    server = ladder(server, entity)
    {x, y, z} = Edicts.vector(server, entity, "origin")
    {_, _, low} = Edicts.vector(server, entity, "mins")
    {_, _, high} = Edicts.vector(server, entity, "maxs")
    {_, _, eye} = Edicts.vector(server, entity, "view_ofs")
    feet = World.contents_all(server, {x, y, z + low + 1})

    {level, type} =
      cond do
        not Contents.fluid?(feet) ->
          {0, -1}

        not Contents.fluid?(World.contents_all(server, {x, y, z + (low + high) * 0.5})) ->
          {1, Contents.fluid_code(feet)}

        not Contents.fluid?(World.contents_all(server, {x, y, z + eye})) ->
          {2, Contents.fluid_code(feet)}

        true ->
          {3, Contents.fluid_code(feet)}
      end

    server =
      server
      |> Edicts.put(entity, "waterlevel", level / 1)
      |> Edicts.put(entity, "watertype", type / 1)

    {server, level > 1}
  end

  @doc """
  Leave `entity` where it is when it is not stuck, remembering the spot in `oldorigin`;
  otherwise move it back there, or failing that to the first free spot up to a step above
  and a unit to each side.
  """
  @spec check_stuck(Server.t(), non_neg_integer()) :: Server.t()
  def check_stuck(%Server{} = server, entity) do
    origin = Edicts.vector(server, entity, "origin")

    cond do
      not World.stuck?(server, entity) ->
        Edicts.put(server, entity, "oldorigin", origin)

      not stuck_at?(server, entity, Edicts.vector(server, entity, "oldorigin")) ->
        server
        |> Edicts.put(entity, "origin", Edicts.vector(server, entity, "oldorigin"))
        |> World.link(entity, true)

      true ->
        free_spot(server, entity, origin)
    end
  end

  @doc "Walk `entity` along its velocity for the frame, stepping up and down stairs."
  @spec move(Server.t(), non_neg_integer()) :: Server.t()
  def move(%Server{} = server, entity) do
    server = Physics.check_velocity(server, entity)
    grounded? = Edicts.flag?(server, entity, :onground)
    server = Edicts.clear_flag(server, entity, :onground)
    start = Edicts.vector(server, entity, "origin")
    start_velocity = Edicts.vector(server, entity, "velocity")
    {server, blocked, _step} = Move.fly(server, entity, server.frametime)
    server = Physics.check_velocity(server, entity)

    original = %{
      origin: Edicts.vector(server, entity, "origin"),
      velocity: Edicts.vector(server, entity, "velocity"),
      flags: Edicts.float(server, entity, "flags"),
      ground: Edicts.float(server, entity, "groundentity")
    }

    walk = %{
      entity: entity,
      grounded?: grounded?,
      start: start,
      start_velocity: start_velocity,
      original: original
    }

    cond do
      Edicts.flag?(server, entity, :waterjump) -> server
      (blocked &&& 2) != 0 -> step_up(server, walk)
      not step_down?(server, walk) -> server
      true -> step_down(server, walk)
    end
  end

  defp step_down?(server, walk) do
    {_, _, vz} = walk.start_velocity

    Server.cvar(server, "sv_gameplayfix_stepdown") != 0 and walk.grounded? and vz <= 0 and
      not Edicts.flag?(server, walk.entity, :onground) and
      Edicts.float(server, walk.entity, "waterlevel") < 2
  end

  defp step_up(server, %{start_velocity: {vx, vy, vz}} = walk) do
    movetype = Edicts.int(server, walk.entity, "movetype")
    fly? = movetype == Q.movetype(:fly)

    cond do
      abs(vx) < 0.03125 and abs(vy) < 0.03125 -> server
      not fly? and movetype != Q.movetype(:walk) -> server
      not fly? and not air_step?(server, walk) -> server
      true -> climb(server, walk, {vx, vy, vz})
    end
  end

  defp air_step?(server, walk) do
    Server.cvar(server, "pm_airstep") != 0 or walk.grounded? or
      Edicts.float(server, walk.entity, "waterlevel") != 0
  end

  defp climb(server, walk, {vx, vy, vz}) do
    entity = walk.entity

    server =
      server
      |> Edicts.put(entity, "origin", walk.start)
      |> Edicts.put(entity, "velocity", walk.start_velocity)

    {server, _} = Move.push(server, entity, {0.0, 0.0, Physics.step_size(server)})
    server = Edicts.put(server, entity, "velocity", {vx, vy, 0.0})
    {server, blocked, step} = Move.fly(server, entity, server.frametime)
    {sx, sy, _} = Edicts.vector(server, entity, "velocity")

    server =
      server
      |> Edicts.put(entity, "velocity", {sx, sy, vz})
      |> Physics.check_velocity(entity)

    {x, y, _} = Edicts.vector(server, entity, "origin")
    {ox, oy, _} = walk.original.origin

    cond do
      blocked != 0 and abs(oy - y) < 0.03125 and abs(ox - x) < 0.03125 ->
        restore(server, walk)

      (blocked &&& 2) != 0 and Server.cvar(server, "sv_wallfriction") != 0 and step != nil ->
        server |> wall_friction(entity, step) |> step_down(walk)

      true ->
        step_down(server, walk)
    end
  end

  defp step_down(server, walk) do
    entity = walk.entity
    {_, _, vz} = walk.start_velocity
    drop = Physics.step_size(server) + 1 / 32 + vz * server.frametime
    {server, down} = Move.push(server, entity, {0.0, 0.0, -drop})
    {_, _, nz} = down.normal

    if down.fraction < 1 and nz > 0.7 do
      server =
        if Vec.dot(down.normal, Edicts.vector(server, entity, "velocity")) <= 0,
          do:
            server
            |> Edicts.set_flag(entity, :onground)
            |> Edicts.put(entity, "groundentity", down.hit || 0),
          else: server

      Physics.check_velocity(server, entity)
    else
      server |> restore(walk) |> Physics.check_velocity(entity)
    end
  end

  defp restore(server, walk) do
    server
    |> Edicts.put(walk.entity, "origin", walk.original.origin)
    |> Edicts.put(walk.entity, "velocity", walk.original.velocity)
    |> Edicts.put(walk.entity, "flags", walk.original.flags)
    |> Edicts.put(walk.entity, "groundentity", walk.original.ground)
  end

  defp wall_friction(server, entity, trace) do
    {forward, _right, _up} = Angles.vectors(Edicts.vector(server, entity, "v_angle"))
    d = Vec.dot(trace.normal, forward) + 0.5

    if d >= 0 do
      server
    else
      velocity = Edicts.vector(server, entity, "velocity")
      into = Vec.scale(trace.normal, Vec.dot(trace.normal, velocity))
      {sx, sy, _} = Vec.sub(velocity, into)
      {_, _, vz} = velocity
      Edicts.put(server, entity, "velocity", {sx * (1 + d), sy * (1 + d), vz})
    end
  end

  defp ladder(server, entity) do
    origin = Edicts.vector(server, entity, "origin")
    mins = Edicts.vector(server, entity, "mins")
    maxs = Edicts.vector(server, entity, "maxs")
    flags = trunc(Edicts.float(server, entity, "pmove_flags"))

    on_ladder? =
      Contents.has?(World.box_contents(server, origin, mins, maxs, entity), :ladder) and
        facing_ladder?(server, entity, origin, mins, maxs)

    flags = if on_ladder?, do: flags ||| @ladder, else: flags &&& bnot(@ladder)
    QuakeServer.Edicts.put(server, entity, "pmove_flags", flags / 1)
  end

  defp facing_ladder?(server, entity, origin, mins, maxs) do
    {_, yaw, _} = Edicts.vector(server, entity, "angles")
    radians = yaw * :math.pi() / 180
    ahead = Vec.add(origin, {24 * :math.cos(radians), 24 * :math.sin(radians), 0.0})
    World.move(server, origin, mins, maxs, ahead, :normal, entity).fraction < 1
  end

  defp stuck_at?(server, entity, spot) do
    origin = Edicts.vector(server, entity, "origin")
    server = Edicts.put(server, entity, "origin", spot)
    stuck? = World.stuck?(server, entity)
    Edicts.put(server, entity, "origin", origin)
    stuck?
  end

  defp free_spot(server, entity, {x, y, z} = origin) do
    height = trunc(Float.ceil(Physics.step_size(server)))
    spots = for dz <- 0..(height - 1)//1, dx <- -1..1, dy <- -1..1, do: {x + dx, y + dy, z + dz}

    case Enum.find(spots, &(not stuck_at?(server, entity, &1))) do
      nil -> Edicts.put(server, entity, "origin", origin)
      spot -> server |> Edicts.put(entity, "origin", spot) |> World.link(entity, true)
    end
  end
end
