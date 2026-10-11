defmodule QuakeServer.Steps do
  @moduledoc """
  Monster movement as FTE's `sv_move.c` has it, with gravity along -z: a step that
  climbs stairs and slopes and refuses ledges, flying and swimming that rise or sink
  toward the enemy, turning toward `ideal_yaw`, and the choice of a new direction toward
  a goal when the way ahead is blocked.

      {server, moved?} = QuakeServer.Steps.move_step(server, monster, {dx, dy, 0.0}, true)

      {server, moved?} =
        QuakeServer.Steps.move_step(server, monster, move, true,
          on_trace: &QuakeServer.Builtins.put_trace/2
        )

  Steps are `QuakeServer.Physics.step_size/1` high. Angles are brought into 0 up to 360
  as FTE's `anglemod` does, in steps of 360/65536 degrees.
  """

  import Bitwise

  alias Cauldron3D.Hull.Trace
  alias Cauldron3D.Vec
  alias QuakeServer.{Edicts, Physics, Server, World}

  @type on_trace :: (Server.t(), Trace.t() -> Server.t())

  @no_direction -1.0

  @doc """
  Whether `entity` stands with every corner of its box over ground: all four corners
  just below the box in solid world, or a point trace down from each corner landing no
  more than a step below the trace from the middle, which must land within two steps.
  The box's top corner is sized from the world hull the entity's size chooses.
  """
  @spec bottom?(Server.t(), non_neg_integer()) :: boolean()
  def bottom?(%Server{} = server, entity) do
    {x0, y0, z0} = low = Vec.add(Edicts.vector(server, entity, "origin"), mins(server, entity))
    {x1, y1, _} = high_corner(server, entity, low)
    corners = for x <- [x0, x1], y <- [y0, y1], do: {x, y}

    Enum.all?(corners, fn {x, y} -> solid?(server, {x, y, z0 - 1}) end) or
      traced_bottom?(server, entity, {x0, y0, x1, y1}, z0, corners)
  end

  @doc """
  Move `entity` by `move` if it can go there, returning `{server, moved?}`.

  An entity flagged `:fly` or `:swim` first tries the move raised or lowered 8 units
  toward its enemy's height (lowered when more than 40 above it, raised when less than
  30), then the plain move; a swimmer whose move would end outside water, slime, lava
  or sky tries the next attempt. Anything else is pushed down from a step above the
  wished position, from the position itself when that start is inside something, and
  fails when it would walk off a ledge or leave a corner dangling, unless it is already
  `:partialground`, when it moves (falling, with `:onground` cleared, if nothing is
  below). Landing clears `:partialground` and sets `groundentity`.

  `relink?` links the entity and touches triggers after a move. Options:

    * `:enemy?` — whether flying and swimming look at the enemy (default `true`); when
      `false` only one attempt is made unless a swimmer would leave the water
    * `:on_trace` — `fun(server, trace)` called with every trace made, returning the server
  """
  @spec move_step(Server.t(), non_neg_integer(), Vec.t(), boolean(), keyword()) ::
          {Server.t(), boolean()}
  def move_step(%Server{} = server, entity, move, relink?, opts \\ []) do
    step = %{
      entity: entity,
      move: move,
      relink?: relink?,
      enemy?: Keyword.get(opts, :enemy?, true),
      on_trace: Keyword.get(opts, :on_trace, fn traced, _trace -> traced end)
    }

    if Edicts.flag?(server, entity, :swim) or Edicts.flag?(server, entity, :fly),
      do: airborne(server, step, 0),
      else: grounded(server, step)
  end

  @doc "Turn `entity`'s yaw toward its `ideal_yaw` by at most its `yaw_speed`."
  @spec change_yaw(Server.t(), non_neg_integer()) :: Server.t()
  def change_yaw(%Server{} = server, entity) do
    {server, _remaining} = turn(server, entity)
    server
  end

  @doc """
  Set `entity`'s `ideal_yaw` to `yaw`, turn toward it, and step `distance` along it.
  The step is taken back when the entity is still more than 45 degrees from facing
  `yaw`. Relinks the entity either way. Returns `{server, moved?}`, `moved?` true
  whenever the step was possible.
  """
  @spec step_direction(Server.t(), non_neg_integer(), number(), number()) ::
          {Server.t(), boolean()}
  def step_direction(%Server{} = server, entity, yaw, distance) do
    {server, remaining} = server |> Edicts.put(entity, "ideal_yaw", yaw / 1) |> turn(entity)
    radians = yaw * :math.pi() * 2 / 360
    move = {:math.cos(radians) * distance, :math.sin(radians) * distance, 0.0}
    origin = Edicts.vector(server, entity, "origin")

    case move_step(server, entity, move, false) do
      {server, true} ->
        server = keep_facing_step(server, entity, origin, anglemod(remaining))
        {World.link(server, entity, true), true}

      {server, false} ->
        {World.link(server, entity, true), false}
    end
  end

  @doc """
  Step `entity` `distance` toward its `goalentity`, as the `movetogoal` builtin does:
  nothing unless it is `:onground`, `:fly` or `:swim`; nothing when it has an enemy and
  the goal's box is within `distance` of its own; otherwise one time in four, or when
  the step along `ideal_yaw` fails, a new direction toward the goal.
  """
  @spec move_to_goal(Server.t(), non_neg_integer(), number()) :: Server.t()
  def move_to_goal(%Server{} = server, entity, distance) do
    goal = Edicts.int(server, entity, "goalentity")

    cond do
      not footed?(server, entity) -> server
      enemy?(server, entity) and close_enough?(server, entity, goal, distance) -> server
      random(3) == 1 -> new_chase_dir(server, entity, goal, distance)
      true -> ahead_or_around(server, entity, goal, distance)
    end
  end

  defp mins(server, entity), do: Edicts.vector(server, entity, "mins")

  defp maxs(server, entity), do: Edicts.vector(server, entity, "maxs")

  defp high_corner(server, entity, low) do
    hull = server.hull.(server.bsp.hulls, Vec.sub(maxs(server, entity), mins(server, entity)))
    low |> Vec.sub(hull.mins) |> Vec.add(hull.maxs)
  end

  defp solid?(server, point), do: World.point_contents(server, point) == -2

  defp fluid?(server, point), do: World.point_contents(server, point) in -6..-3//1

  defp traced_bottom?(server, entity, {x0, y0, x1, y1}, start_z, corners) do
    step = Physics.step_size(server)
    stop_z = start_z - 2 * step
    middle = trace_down(server, entity, {(x0 + x1) * 0.5, (y0 + y1) * 0.5}, start_z, stop_z)
    {_, _, middle_z} = middle.end_pos
    mid = (middle_z - start_z - step) / (stop_z - start_z)

    middle.fraction != 1.0 and
      Enum.all?(corners, fn corner ->
        trace = trace_down(server, entity, corner, start_z, stop_z)
        trace.fraction != 1.0 and trace.fraction <= mid
      end)
  end

  defp trace_down(server, entity, {x, y}, start_z, stop_z),
    do:
      World.move(
        server,
        {x, y, start_z},
        Vec.zero(),
        Vec.zero(),
        {x, y, stop_z},
        :nomonsters,
        entity
      )

  defp airborne(server, _step, attempt) when attempt > 1, do: {server, false}

  defp airborne(server, step, attempt) do
    origin = Edicts.vector(server, step.entity, "origin")
    enemy = if step.enemy?, do: Edicts.int(server, step.entity, "enemy"), else: 0
    target = origin |> Vec.add(step.move) |> toward_enemy(server, origin, enemy, attempt)

    trace =
      World.move(
        server,
        origin,
        mins(server, step.entity),
        maxs(server, step.entity),
        target,
        :normal,
        step.entity
      )

    server = step.on_trace.(server, trace)
    airborne_result(server, step, attempt, enemy, trace)
  end

  defp airborne_result(server, step, attempt, _enemy, %Trace{fraction: 1.0} = trace) do
    if Edicts.flag?(server, step.entity, :swim) and not fluid?(server, trace.end_pos) do
      airborne(server, step, attempt + 1)
    else
      server = Edicts.put(server, step.entity, "origin", trace.end_pos)
      {relink(server, step), true}
    end
  end

  defp airborne_result(server, _step, _attempt, 0, _trace), do: {server, false}

  defp airborne_result(server, step, attempt, _enemy, _trace),
    do: airborne(server, step, attempt + 1)

  defp toward_enemy(target, server, {_, _, origin_z}, enemy, 0) when enemy != 0 do
    {x, y, z} = target
    {_, _, enemy_z} = Edicts.vector(server, enemy, "origin")
    height = origin_z - enemy_z
    z = if height > 40, do: z - 8, else: z
    z = if height < 30, do: z + 8, else: z
    {x, y, z}
  end

  defp toward_enemy(target, _server, _origin, _enemy, _attempt), do: target

  defp grounded(server, step) do
    height = Physics.step_size(server)
    {x, y, z} = Vec.add(Edicts.vector(server, step.entity, "origin"), step.move)
    stop = {x, y, z + height - 2 * height}
    trace = ground_trace(server, step, {x, y, z + height}, stop)
    server = step.on_trace.(server, trace)

    cond do
      trace.all_solid -> {server, false}
      trace.start_solid -> grounded_lower(server, step, {x, y, z}, stop)
      true -> settle(server, step, trace)
    end
  end

  defp grounded_lower(server, step, start, stop) do
    trace = ground_trace(server, step, start, stop)
    server = step.on_trace.(server, trace)

    if trace.all_solid or trace.start_solid,
      do: {server, false},
      else: settle(server, step, trace)
  end

  defp ground_trace(server, step, start, stop) do
    World.move(
      server,
      start,
      mins(server, step.entity),
      maxs(server, step.entity),
      stop,
      :normal,
      step.entity
    )
  end

  defp settle(server, step, %Trace{fraction: 1.0}), do: fall(server, step)
  defp settle(server, step, trace), do: land(server, step, trace)

  defp fall(server, step) do
    if Edicts.flag?(server, step.entity, :partialground) do
      origin = Vec.add(Edicts.vector(server, step.entity, "origin"), step.move)

      server =
        server
        |> Edicts.put(step.entity, "origin", origin)
        |> relink(step)
        |> Edicts.clear_flag(step.entity, :onground)

      {server, true}
    else
      {server, false}
    end
  end

  defp land(server, step, trace) do
    origin = Edicts.vector(server, step.entity, "origin")
    server = Edicts.put(server, step.entity, "origin", trace.end_pos)
    land_on(server, step, trace, origin, bottom?(server, step.entity))
  end

  defp land_on(server, step, trace, _origin, true) do
    server =
      server
      |> Edicts.clear_flag(step.entity, :partialground)
      |> Edicts.put(step.entity, "groundentity", trace.hit || 0)

    {relink(server, step), true}
  end

  defp land_on(server, step, _trace, origin, false) do
    if Edicts.flag?(server, step.entity, :partialground),
      do: {relink(server, step), true},
      else: {Edicts.put(server, step.entity, "origin", origin), false}
  end

  defp relink(server, %{relink?: true, entity: entity}), do: World.link(server, entity, true)
  defp relink(server, _step), do: server

  defp turn(server, entity) do
    {pitch, yaw, roll} = Edicts.vector(server, entity, "angles")
    current = anglemod(yaw)
    ideal = Edicts.float(server, entity, "ideal_yaw")
    turn_from(server, entity, {pitch, roll}, current, ideal)
  end

  defp turn_from(server, _entity, _pitch_roll, current, ideal) when current == ideal,
    do: {server, 0.0}

  defp turn_from(server, entity, {pitch, roll}, current, ideal) do
    speed = Edicts.float(server, entity, "yaw_speed")
    move = ideal |> wrapped_turn(current) |> clamp_turn(speed)
    yaw = anglemod(current + move)
    {Edicts.put(server, entity, "angles", {pitch, yaw, roll}), ideal - yaw}
  end

  defp wrapped_turn(ideal, current) when ideal > current and ideal - current >= 180,
    do: ideal - current - 360

  defp wrapped_turn(ideal, current) when ideal <= current and ideal - current <= -180,
    do: ideal - current + 360

  defp wrapped_turn(ideal, current), do: ideal - current

  defp clamp_turn(move, speed) when move > 0, do: min(move, speed)
  defp clamp_turn(move, speed), do: max(move, -speed)

  defp keep_facing_step(server, entity, origin, remaining)
       when remaining > 45 and remaining < 315,
       do: Edicts.put(server, entity, "origin", origin)

  defp keep_facing_step(server, _entity, _origin, _remaining), do: server

  defp footed?(server, entity) do
    Edicts.flag?(server, entity, :onground) or Edicts.flag?(server, entity, :fly) or
      Edicts.flag?(server, entity, :swim)
  end

  defp enemy?(server, entity), do: Edicts.int(server, entity, "enemy") != 0

  defp ahead_or_around(server, entity, goal, distance) do
    case step_direction(server, entity, Edicts.float(server, entity, "ideal_yaw"), distance) do
      {server, true} -> server
      {server, false} -> new_chase_dir(server, entity, goal, distance)
    end
  end

  defp close_enough?(server, entity, goal, distance) do
    entity_min = Tuple.to_list(Edicts.vector(server, entity, "absmin"))
    entity_max = Tuple.to_list(Edicts.vector(server, entity, "absmax"))
    goal_min = Tuple.to_list(Edicts.vector(server, goal, "absmin"))
    goal_max = Tuple.to_list(Edicts.vector(server, goal, "absmax"))

    [goal_min, entity_max, goal_max, entity_min]
    |> Enum.zip()
    |> Enum.all?(fn {gmin, emax, gmax, emin} ->
      not (gmin > emax + distance) and not (gmax < emin - distance)
    end)
  end

  defp new_chase_dir(server, actor, enemy, distance) do
    old = anglemod(trunc(Edicts.float(server, actor, "ideal_yaw") / 45) * 45)
    turnaround = anglemod(old - 180)

    case first_step(server, actor, chase_tries(server, actor, enemy, old, turnaround), distance) do
      {server, true} -> server
      {server, false} -> give_up(server, actor, old)
    end
  end

  defp chase_tries(server, actor, enemy, old, turnaround) do
    {ax, ay, _} = Edicts.vector(server, actor, "origin")
    {ex, ey, _} = Edicts.vector(server, enemy, "origin")
    {delta_x, delta_y} = {ex - ax, ey - ay}
    {d1, d2} = {x_direction(delta_x), y_direction(delta_y)}
    diagonal = direct(d1, d2)
    swap? = random(1) == 1 or abs(delta_y) > abs(delta_x)
    {d1, d2} = if swap?, do: {d2, d1}, else: {d1, d2}

    Enum.reject([diagonal, d1, d2], fn yaw ->
      yaw == @no_direction or yaw == turnaround
    end) ++ [old | Enum.reject(sweep(random(1)), &(&1 == turnaround))] ++ [turnaround]
  end

  defp x_direction(delta) when delta > 10, do: 0.0
  defp x_direction(delta) when delta < -10, do: 180.0
  defp x_direction(_delta), do: @no_direction

  defp y_direction(delta) when delta < -10, do: 270.0
  defp y_direction(delta) when delta > 10, do: 90.0
  defp y_direction(_delta), do: @no_direction

  defp direct(@no_direction, _d2), do: @no_direction
  defp direct(_d1, @no_direction), do: @no_direction
  defp direct(+0.0, 90.0), do: 45.0
  defp direct(+0.0, _d2), do: 315.0
  defp direct(_d1, 90.0), do: 135.0
  defp direct(_d1, _d2), do: 215.0

  defp sweep(1), do: Enum.map(0..7, &(&1 * 45.0))
  defp sweep(0), do: Enum.map(7..0//-1, &(&1 * 45.0))

  defp first_step(server, actor, tries, distance) do
    Enum.reduce_while(tries, {server, false}, fn yaw, {acc, _} ->
      case step_direction(acc, actor, yaw, distance) do
        {acc, true} -> {:halt, {acc, true}}
        {acc, false} -> {:cont, {acc, false}}
      end
    end)
  end

  defp give_up(server, actor, old) do
    server = Edicts.put(server, actor, "ideal_yaw", old)
    if bottom?(server, actor), do: server, else: Edicts.set_flag(server, actor, :partialground)
  end

  defp random(mask), do: :rand.uniform(mask + 1) - 1

  defp anglemod(angle), do: 360.0 / 65_536 * band(trunc(angle * (65_536 / 360.0)), 65_535)
end
