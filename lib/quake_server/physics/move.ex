defmodule QuakeServer.Physics.Move do
  @moduledoc """
  FTE's solid-body movement (`sv_phys.c`): sliding along what a box hits
  (`WPhys_FlyMove`), moving a box at once (`WPhys_PushEntity`), the touches two entities
  run when they meet (`WPhys_Impact`), and the velocity clip a surface gives
  (`ClipVelocity`).

      {server, blocked, step} = QuakeServer.Physics.Move.fly(server, entity, 0.05)
      {server, trace} = QuakeServer.Physics.Move.push(server, entity, {0.0, 0.0, 18.0})

  Gravity runs along -z.
  """

  alias Cauldron3D.Vec
  alias QuakeServer.{Builtins, Edicts, Q, Server, World}

  @stop_epsilon 0.1
  @most_planes 5
  @down {0.0, 0.0, -1.0}

  @doc "`velocity` slid along a surface of `normal`, `overbounce` times its push away; parts under 0.1 become 0."
  @spec clip_velocity(Vec.t(), Vec.t(), number()) :: Vec.t()
  def clip_velocity(velocity, normal, overbounce) do
    backoff = -Vec.dot(velocity, normal) * overbounce
    {x, y, z} = Vec.madd(velocity, normal, backoff)
    {settle(x), settle(y), settle(z)}
  end

  @doc """
  Move `entity` along its velocity for `seconds`, sliding along up to four surfaces and
  running the touches of what it hits (`WPhys_FlyMove`). Returns `{server, blocked,
  step}`: `blocked` has bit 1 for a floor, 2 for a wall, 4 for a dead stop (3 when
  trapped, 7 caught between more than two planes); `step` is the trace of the last wall
  hit, or `nil`.
  """
  @spec fly(Server.t(), non_neg_integer(), number()) :: {Server.t(), integer(), map() | nil}
  def fly(%Server{} = server, entity, seconds) do
    velocity = Edicts.vector(server, entity, "velocity")

    bump(
      %{
        server: server,
        entity: entity,
        left: seconds / 1,
        original: velocity,
        primal: velocity,
        planes: [],
        blocked: 0,
        step: nil
      },
      4
    )
  end

  @doc """
  Move `entity` by `push` at once, relink it touching triggers, and run the touches of
  what it hit (`WPhys_PushEntity`); its velocity is not changed. Returns `{server, trace}`.
  """
  @spec push(Server.t(), non_neg_integer(), Vec.t()) :: {Server.t(), map()}
  def push(%Server{} = server, entity, push) do
    origin = Edicts.vector(server, entity, "origin")

    trace =
      World.move(
        server,
        origin,
        Edicts.vector(server, entity, "mins"),
        Edicts.vector(server, entity, "maxs"),
        Vec.add(origin, push),
        push_type(server, entity),
        entity
      )

    server =
      server
      |> Edicts.put(entity, "origin", trace.end_pos)
      |> World.link(entity, true)

    server = if trace.hit != nil, do: impact(server, entity, trace), else: server
    {server, trace}
  end

  @doc """
  Run the touches of `entity` and what `trace` hit, each that has one and is solid, with
  the trace globals set from `trace` (`WPhys_Impact`); `self` and `other` are put back.
  """
  @spec impact(Server.t(), non_neg_integer(), map()) :: Server.t()
  def impact(%Server{} = server, entity, trace) do
    other = trace.hit || 0

    server
    |> touch(entity, other, trace)
    |> touch(other, entity, trace)
  end

  defp touch(server, entity, other, trace) do
    function = Edicts.int(server, entity, "touch")

    if function != 0 and Edicts.int(server, entity, "solid") != Q.solid(:not) and
         not Edicts.free?(server, entity) do
      self = QuakeC.global(server.qc, "self")
      previous = QuakeC.global(server.qc, "other")

      server
      |> Builtins.put_trace(trace)
      |> Server.run(function, entity, other)
      |> then(
        &%{
          &1
          | qc: &1.qc |> QuakeC.put_global("self", self) |> QuakeC.put_global("other", previous)
        }
      )
    else
      server
    end
  end

  defp push_type(server, entity) do
    solid = Edicts.int(server, entity, "solid")

    cond do
      Edicts.int(server, entity, "movetype") == Q.movetype(:flymissile) -> :missile
      solid == Q.solid(:trigger) or solid == Q.solid(:not) -> :nomonsters
      true -> :normal
    end
  end

  defp settle(value) when value > -@stop_epsilon and value < @stop_epsilon, do: 0.0
  defp settle(value), do: value

  defp bump(state, 0), do: done(state)

  defp bump(%{server: server, entity: entity} = state, left) do
    velocity = Edicts.vector(server, entity, "velocity")
    origin = Edicts.vector(server, entity, "origin")

    trace =
      World.move(
        server,
        origin,
        Edicts.vector(server, entity, "mins"),
        Edicts.vector(server, entity, "maxs"),
        Vec.madd(origin, velocity, state.left),
        :normal,
        entity
      )

    moved(state, trace, velocity, left)
  end

  defp moved(state, %{all_solid: true}, _velocity, _left),
    do: {Edicts.put(state.server, state.entity, "velocity", {0.0, 0.0, 0.0}), 3, state.step}

  defp moved(state, trace, velocity, left) do
    state =
      if trace.fraction > 0,
        do: %{
          state
          | server: Edicts.put(state.server, state.entity, "origin", trace.end_pos),
            original: velocity,
            planes: []
        },
        else: state

    if trace.fraction == 1.0, do: done(state), else: hit(state, trace, left)
  end

  defp hit(state, trace, left) do
    entity = state.entity
    other = trace.hit || 0
    up = -Vec.dot(@down, trace.normal)

    {server, blocked} =
      if up > 0.7,
        do: {floor(state.server, entity, other), Bitwise.bor(state.blocked, 1)},
        else: {state.server, state.blocked}

    {blocked, step} =
      if Vec.dot(@down, trace.normal) == 0,
        do: {Bitwise.bor(blocked, 2), trace},
        else: {blocked, state.step}

    server = impact(server, entity, trace)
    state = %{state | server: server, blocked: blocked, step: step}

    if Edicts.free?(server, entity),
      do: done(state),
      else: clip(%{state | left: state.left - state.left * trace.fraction}, trace, left)
  end

  defp floor(server, entity, other) do
    if Edicts.int(server, other, "solid") == Q.solid(:bsp),
      do:
        server
        |> Edicts.set_flag(entity, :onground)
        |> Edicts.put(entity, "groundentity", other),
      else: server
  end

  defp clip(%{planes: planes} = state, trace, _left) when length(planes) >= @most_planes,
    do: {Edicts.put(state.server, state.entity, "velocity", {0.0, 0.0, 0.0}), 3, trace}

  defp clip(%{planes: [first | _]} = state, trace, left) do
    if Vec.length(Vec.sub(first, trace.normal)) < 0.01,
      do: bump(state, left - 1),
      else: along(%{state | planes: state.planes ++ [trace.normal]}, left)
  end

  defp clip(state, trace, left), do: along(%{state | planes: [trace.normal]}, left)

  defp along(state, left) do
    case Enum.find_value(state.planes, &parallel(state, &1)) do
      nil -> crease(state, left)
      velocity -> onward(state, velocity, left)
    end
  end

  defp parallel(state, plane) do
    clipped = clip_velocity(state.original, plane, 1)

    if Enum.all?(state.planes, &(&1 == plane or Vec.dot(clipped, &1) >= 0)),
      do: clipped
  end

  defp crease(%{planes: [a, b]} = state, left) do
    direction = Vec.normalize(Vec.cross(a, b))
    velocity = Edicts.vector(state.server, state.entity, "velocity")
    onward(state, Vec.scale(direction, Vec.dot(direction, velocity)), left)
  end

  defp crease(state, _left),
    do: {Edicts.put(state.server, state.entity, "velocity", {0.0, 0.0, 0.0}), 7, state.step}

  defp onward(state, velocity, left) do
    server = Edicts.put(state.server, state.entity, "velocity", velocity)

    if Vec.dot(velocity, state.primal) <= 0,
      do:
        {Edicts.put(server, state.entity, "velocity", {0.0, 0.0, 0.0}), state.blocked, state.step},
      else: bump(%{state | server: server}, left - 1)
  end

  defp done(state), do: {state.server, state.blocked, state.step}
end
