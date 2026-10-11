defmodule QuakeServer.Builtins do
  @moduledoc """
  The engine functions a QuakeC program calls by number, as FTE runs them for a server
  program: vectors and angles, entities and models, traces, sounds, monster movement,
  searches, console variables, messages and level changes. Where FTE's rule depends on
  the kind of program, a QuakeWorld program is one whose `crc` is 54730.

  `call/3` takes the server (the QuakeC host), the builtin number and the argument
  count; arguments are read from the program's parameter slots and the result written
  to its return slot.

  `error` (10) prints its arguments joined, as a line. With the console variable
  `developer` set it then prints `break statement` and the program goes on; otherwise it
  raises `QuakeC.Exec.Error` with the message `Program error: ` and the text, which ends
  the call into the program. `objerror` (11) prints `Program error: ` and its arguments
  joined, removes `self` and stops every running function (`QuakeC.Exec.abort/1`).
  `breakpoint` (6) prints `break statement`; `dprint` (25) prints its arguments joined
  while `developer` is set.

  `random` (7) is FTE's: a step of 1/32768 from 0 up to 1, offset by half a step so it is
  never 0 or 1; with one argument it is scaled by it, with two it runs from the first
  toward the second. `ftos` (26) and `vtos` (27) write numbers as
  `QuakeServer.Builtins.Text` does, `ftos` as `%5.1f` while `pr_brokenfloatconvert` is
  set.

  `findradius` (22) chains, through the field its third argument names (`chain` without
  one), every entity whose centre (with `sv_gameplayfix_findradiusdistancetobox` set,
  nearest point of its box) lies within the radius, the last found first; an entity with
  `solid` 0 is left out unless its `flags` hold 16384 (`FL_FINDABLE_NONSOLID`) or
  `sv_gameplayfix_blowupfallenzombies` is set.

  `setmodel` (3) sets `model` and `modelindex` and then sizes the entity by the model's
  box: always for a world submodel (`*n`); for any model when the program is not a
  QuakeWorld one or `sv_gameplayfix_setmodelsize_qw` is set; otherwise only for a model
  that was found and is not a Quake alias model; any other keeps its size. The entity is
  linked either way.
  """

  import Bitwise, only: [bor: 2]

  alias Cauldron3D.{Hull, Vec}
  alias QuakeC.Exec
  alias QuakeServer.{Angles, Contents, Edicts, Events, Models, Q, Server, Steps, World}
  alias QuakeServer.World.Trace
  alias QuakeServer.Builtins.{Aim, Print, Text, Write}

  @return 1
  @ignore_hull 0x80000000
  @findable_nonsolid 16_384
  @quakeworld_crc 54_730

  @doc """
  Run builtin `number`, or the game's own function for a program function its source
  replaces (`QuakeServer.Source.replacements/0`), called by that function's name.
  """
  @spec call(Server.t(), non_neg_integer() | String.t(), non_neg_integer()) :: Server.t()
  def call(%Server{replacements: replacements} = server, name, argc)
      when is_map_key(replacements, name),
      do: Map.fetch!(replacements, name).(server, argc)

  def call(%Server{} = server, 16, argc), do: traceline(server, argc)

  def call(%Server{} = server, 32, argc),
    do: walkmove(server, num(server, 0), num(server, 1), argc >= 3 and num(server, 2) != 0)

  def call(%Server{} = server, number, argc) when number in [23, 24, 73],
    do: Print.call(server, number, argc)

  def call(%Server{} = server, 10, argc), do: program_error(server, argc)

  def call(%Server{} = server, 7, argc), do: random(server, argc)
  def call(%Server{} = server, 11, argc), do: objerror(server, argc)
  def call(%Server{} = server, 22, argc), do: find_radius(server, argc)
  def call(%Server{} = server, 25, argc), do: dprint(server, argc)

  def call(%Server{} = server, 51, argc), do: vectoangles(server, argc)

  def call(%Server{} = server, number, _argc), do: builtin(number, server)

  defp builtin(1, s), do: makevectors(s, vec(s, 0))

  defp builtin(2, s),
    do: s |> Edicts.put(ent(s, 0), "origin", vec(s, 1)) |> World.link(ent(s, 0), false)

  defp builtin(3, s), do: setmodel(s, ent(s, 0), slot(s, 1))
  defp builtin(4, s), do: size(s, ent(s, 0), vec(s, 1), vec(s, 2))
  defp builtin(6, s), do: Events.print(s, :notify, "break statement\n")

  defp builtin(8, s),
    do: QuakeServer.Sounds.start(s, ent(s, 0), trunc(num(s, 1)), str(s, 2), num(s, 3), num(s, 4))

  defp builtin(9, s), do: return(s, Vec.normalize(vec(s, 0)))
  defp builtin(12, s), do: return(s, Vec.length(vec(s, 0)))
  defp builtin(13, s), do: return(s, Angles.yaw(vec(s, 0)))
  defp builtin(14, s), do: s |> Edicts.alloc() |> then(fn {s, entity} -> return(s, entity) end)
  defp builtin(15, s), do: Edicts.free(s, ent(s, 0))
  defp builtin(17, s), do: return(s, check_client(s))
  defp builtin(18, s), do: return(s, find(s, ent(s, 0), trunc(num(s, 1)), str(s, 2)))
  defp builtin(19, s), do: s |> Models.precache_sound(str(s, 0)) |> return(slot(s, 0))
  defp builtin(20, s), do: s |> Models.precache(str(s, 0)) |> elem(0) |> return(slot(s, 0))
  defp builtin(21, s), do: Server.emit(s, {:stuff, str(s, 1)})

  defp builtin(26, s),
    do: return(s, Text.ftos(num(s, 0), broken: setting(s, "pr_brokenfloatconvert", 0.0) != 0))

  defp builtin(27, s), do: return(s, Text.vtos(vec(s, 0)))
  defp builtin(n, s) when n in [28, 29, 30, 31], do: s
  defp builtin(34, s), do: drop_to_floor(s)
  defp builtin(35, s), do: lightstyle(s, trunc(num(s, 0)), str(s, 1))
  defp builtin(36, s), do: return(s, rint(num(s, 0)))
  defp builtin(37, s), do: return(s, Float.floor(num(s, 0) / 1))
  defp builtin(38, s), do: return(s, Float.ceil(num(s, 0) / 1))
  defp builtin(40, s), do: return(s, bool(Steps.bottom?(s, ent(s, 0))))
  defp builtin(41, s), do: return(s, Contents.point_code(World.contents_world(s, vec(s, 0))) / 1)
  defp builtin(43, s), do: return(s, abs(num(s, 0)) / 1)
  defp builtin(44, s), do: return(s, Aim.aim(s, ent(s, 0)))
  defp builtin(45, s), do: return(s, Server.cvar(s, str(s, 0)))
  defp builtin(46, s), do: %{s | console: s.console ++ [str(s, 0)]}
  defp builtin(47, s), do: return(s, next_entity(s, ent(s, 0)))
  defp builtin(48, s), do: Events.particles(s, vec(s, 0), vec(s, 1), num(s, 2), num(s, 3))
  defp builtin(49, s), do: Steps.change_yaw(s, self(s))
  defp builtin(n, s) when n in 52..59, do: Write.write(s, n, slot(s, 1))
  defp builtin(67, s), do: Steps.move_to_goal(s, self(s), num(s, 0))
  defp builtin(68, s), do: return(s, slot(s, 0))
  defp builtin(69, s), do: make_static(s, ent(s, 0))
  defp builtin(70, s), do: if(s.changelevel, do: s, else: %{s | changelevel: str(s, 0)})

  defp builtin(72, s), do: Server.put_cvar(s, str(s, 0), str(s, 1))

  defp builtin(74, s),
    do: %{
      s
      | ambients: [
          %{origin: vec(s, 0), name: str(s, 1), volume: num(s, 2), attenuation: num(s, 3)}
          | s.ambients
        ]
    }

  defp builtin(75, s), do: builtin(20, s)
  defp builtin(76, s), do: builtin(19, s)
  defp builtin(77, s), do: builtin(68, s)
  defp builtin(78, s), do: spawn_parms(s)
  defp builtin(number, _s), do: raise(Exec.Error, "builtin #{number} is not one Quake has")

  defp slot(s, i), do: QuakeC.slot(s.qc, 4 + i * 3)
  defp num(s, i), do: QuakeC.float(slot(s, i))
  defp ent(s, i), do: trunc(num(s, i))
  defp vec(s, i), do: QuakeC.slot_vector(s.qc, 4 + i * 3)

  defp vectoangles(s, argc) do
    up = if argc >= 2, do: vec(s, 1)
    mesh = {Server.cvar(s, "r_meshpitch"), Server.cvar(s, "r_meshroll")}
    return(s, Angles.vectoangles(vec(s, 0), up, mesh))
  end

  defp str(s, i), do: QuakeC.string(s.qc, slot(s, i))

  defp program_error(s, argc) do
    text = joined(s, argc)
    s = Events.print(s, :notify, text <> "\n")

    if Server.cvar(s, "developer") != 0,
      do: Events.print(s, :notify, "break statement\n"),
      else: raise(Exec.Error, "Program error: " <> text)
  end

  defp self(s), do: trunc(QuakeC.float(QuakeC.global(s.qc, "self")))

  defp return(s, {_, _, _} = vector), do: %{s | qc: QuakeC.put_slot_vector(s.qc, @return, vector)}
  defp return(s, value), do: QuakeServer.Args.return(s, value)

  defp bool(true), do: 1.0
  defp bool(false), do: 0.0

  defp rint(value) when value > 0, do: trunc(value + 0.5) / 1
  defp rint(value), do: trunc(value - 0.5) / 1

  defp makevectors(s, angles) do
    {forward, right, up} = Angles.vectors(angles)

    qc =
      s.qc
      |> QuakeC.put_global("v_forward", forward)
      |> QuakeC.put_global("v_right", right)
      |> QuakeC.put_global("v_up", up)

    %{s | qc: qc}
  end

  defp setmodel(s, entity, name_value) do
    name = QuakeC.string(s.qc, name_value)
    {s, index} = Models.precache(s, name)
    model = Models.get(s, index)

    s =
      s |> Edicts.put(entity, "model", name_value) |> Edicts.put(entity, "modelindex", index / 1)

    if sized?(s, name, model),
      do: size(s, entity, model.mins, model.maxs),
      else: World.link(s, entity, false)
  end

  defp sized?(_s, "*" <> _, _model), do: true

  defp sized?(s, _name, model) do
    s.qc.progs.crc != @quakeworld_crc or setting(s, "sv_gameplayfix_setmodelsize_qw", 0.0) != 0 or
      model.kind not in [:alias, :missing]
  end

  defp size(s, entity, mins, maxs) do
    s
    |> Edicts.put(entity, "mins", mins)
    |> Edicts.put(entity, "maxs", maxs)
    |> Edicts.put(entity, "size", Vec.sub(maxs, mins))
    |> World.link(entity, false)
  end

  defp objerror(s, argc) do
    s
    |> Events.print(:notify, "Program error: #{joined(s, argc)}\n")
    |> Edicts.free(self(s))
    |> Exec.abort()
  end

  defp dprint(s, argc) do
    if Server.cvar(s, "developer") != 0,
      do: Events.print(s, :notify, joined(s, argc)),
      else: s
  end

  defp joined(s, argc), do: Enum.map_join(0..(argc - 1)//1, &str(s, &1))

  defp random(s, argc) do
    fraction = (:rand.uniform(0x8000) - 1) / 0x8000 + 0.5 / 0x8000

    value =
      case argc do
        0 -> fraction
        1 -> fraction * num(s, 0)
        _ -> num(s, 0) + fraction * (num(s, 1) - num(s, 0))
      end

    return(s, value)
  end

  defp traceline(s, argc) do
    entity = if argc == 3, do: self(s), else: ent(s, 3)
    {mins, maxs} = if argc == 6, do: {vec(s, 4), vec(s, 5)}, else: {Vec.zero(), Vec.zero()}
    trace(s, vec(s, 0), mins, maxs, vec(s, 1), num(s, 2), entity)
  end

  @doc """
  Trace a box from `from` to `to` for `entity` and set the program's `trace_` globals
  from what it hit, as `traceline` and `tracebox` do: `flags` is the program's `MOVE_`
  bits (`QuakeServer.World.trace/7`), the mover's `hull` field left out.
  """
  @spec trace(Server.t(), Vec.t(), Vec.t(), Vec.t(), Vec.t(), number(), non_neg_integer()) ::
          Server.t()
  def trace(s, from, mins, maxs, to, flags, entity) do
    type = bor(trunc(flags), @ignore_hull)
    {s, trace} = World.trace(s, from, mins, maxs, to, type, entity)
    put_trace(s, trace)
  end

  @doc """
  Set the program's `trace_` globals from `trace` (`set_trace_globals`): with
  `sv_gameplayfix_honest_tracelines` at 0 a trace that started inside something reports
  a fraction of 1.
  """
  @spec put_trace(Server.t(), Trace.t() | Hull.Trace.t()) :: Server.t()
  def put_trace(s, %Hull.Trace{} = trace), do: put_trace(s, Trace.from_hull(trace))

  def put_trace(s, %Trace{} = trace) do
    honest? = setting(s, "sv_gameplayfix_honest_tracelines", 1.0) != 0
    fraction = if trace.start_solid and not honest?, do: 1.0, else: trace.fraction / 1

    qc =
      s.qc
      |> QuakeC.put_declared("trace_allsolid", bool(trace.all_solid))
      |> QuakeC.put_declared("trace_startsolid", bool(trace.start_solid))
      |> QuakeC.put_declared("trace_fraction", fraction)
      |> QuakeC.put_declared("trace_inwater", bool(trace.in_water))
      |> QuakeC.put_declared("trace_inopen", bool(trace.in_open))
      |> QuakeC.put_declared("trace_surfaceflagsi", 0)
      |> QuakeC.put_declared("trace_surfacename", 0)
      |> QuakeC.put_declared("trace_endcontentsi", signed(trace.contents))
      |> QuakeC.put_declared("trace_brush_id", trace.brush_id)
      |> QuakeC.put_declared("trace_brush_faceid", trace.brush_face)
      |> QuakeC.put_declared("trace_surface_id", trace.surface_id)
      |> QuakeC.put_declared("trace_bone_id", trace.bone_id)
      |> QuakeC.put_declared("trace_triangle_id", trace.triangle_id)
      |> QuakeC.put_declared("trace_surfaceflagsf", 0.0)
      |> QuakeC.put_declared("trace_endcontentsf", trace.contents / 1)
      |> QuakeC.put_declared("trace_dphittexturename", 0)
      |> QuakeC.put_declared("trace_dpstartcontents", 0.0)
      |> QuakeC.put_declared("trace_dphitcontents", Contents.to_dp(trace.contents) / 1)
      |> QuakeC.put_declared("trace_dphitq3surfaceflags", 0.0)
      |> QuakeC.put_declared("trace_endpos", trace.end_pos)
      |> QuakeC.put_declared("trace_plane_normal", trace.normal)
      |> QuakeC.put_declared("trace_plane_dist", trace.distance / 1)
      |> QuakeC.put_declared("trace_ent", trace.hit || 0)

    %{s | qc: qc}
  end

  defp signed(bits) when bits >= 0x80000000, do: bits - 0x100000000
  defp signed(bits), do: bits

  defp setting(s, name, default),
    do: if(Server.cvar?(s, name), do: Server.cvar(s, name), else: default)

  defp check_client(s) do
    player = 1

    cond do
      s.parms == nil -> 0
      Edicts.free?(s, player) -> 0
      Edicts.float(s, player, "health") <= 0 -> 0
      Edicts.flag?(s, player, :notarget) -> 0
      sees?(s, player, self(s)) -> player
      true -> 0
    end
  end

  defp sees?(s, from, to) do
    eye = fn entity ->
      Vec.add(Edicts.vector(s, entity, "origin"), Edicts.vector(s, entity, "view_ofs"))
    end

    Cauldron3D.Bsp.sees?(
      s.bsp,
      Cauldron3D.Bsp.leaf_at(s.bsp, eye.(from)),
      Cauldron3D.Bsp.leaf_at(s.bsp, eye.(to))
    )
  end

  defp find(s, start, field, match) do
    Enum.find((start + 1)..(s.count - 1)//1, 0, fn entity ->
      not Edicts.free?(s, entity) and
        QuakeC.string(s.qc, QuakeC.field_slot(s.qc, entity, field)) == match
    end)
  end

  defp find_radius(s, argc) do
    origin = vec(s, 0)
    radius = num(s, 1)
    offset = if argc > 2, do: QuakeServer.Args.int(s, 2), else: QuakeC.field_offset(s.qc, "chain")
    nonsolid? = setting(s, "sv_gameplayfix_blowupfallenzombies", 0.0) != 0
    to_box? = setting(s, "sv_gameplayfix_findradiusdistancetobox", 0.0) != 0

    {chain, qc} =
      1..(s.count - 1)//1
      |> Enum.filter(&(findable?(s, &1, nonsolid?) and within?(s, &1, origin, radius, to_box?)))
      |> Enum.reduce({0, s.qc}, fn entity, {chain, qc} ->
        {entity, QuakeC.put_field_slot(qc, entity, offset, chain)}
      end)

    return(%{s | qc: qc}, chain)
  end

  defp findable?(s, entity, nonsolid?) do
    not Edicts.free?(s, entity) and
      (nonsolid? or Edicts.int(s, entity, "solid") != Q.solid(:not) or
         Bitwise.band(Edicts.int(s, entity, "flags"), @findable_nonsolid) != 0)
  end

  defp within?(s, entity, origin, radius, to_box?) do
    mins = Edicts.vector(s, entity, "mins")
    maxs = Edicts.vector(s, entity, "maxs")
    offset = Vec.sub(origin, Edicts.vector(s, entity, "origin"))

    {dx, dy, dz} =
      if to_box?,
        do: Vec.sub(offset, clamp_each(offset, mins, maxs)),
        else: Vec.sub(offset, Vec.scale(Vec.add(mins, maxs), 0.5))

    dx * dx + dy * dy + dz * dz <= radius * radius
  end

  defp clamp_each({x, y, z}, {x0, y0, z0}, {x1, y1, z1}),
    do: {x |> min(x1) |> max(x0), y |> min(y1) |> max(y0), z |> min(z1) |> max(z0)}

  defp walkmove(s, yaw, distance, settrace?) do
    entity = self(s)

    if Edicts.flag?(s, entity, :onground) or Edicts.flag?(s, entity, :fly) or
         Edicts.flag?(s, entity, :swim) do
      radians = yaw * :math.pi() * 2 / 360
      move = {:math.cos(radians) * distance, :math.sin(radians) * distance, 0.0}
      opts = if settrace?, do: [on_trace: &put_trace/2], else: []
      {s, moved?} = Steps.move_step(s, entity, move, true, opts)
      s = %{s | qc: QuakeC.put_global(s.qc, "self", entity)}
      return(s, bool(moved?))
    else
      return(s, 0.0)
    end
  end

  defp drop_to_floor(s) do
    entity = self(s)
    origin = Edicts.vector(s, entity, "origin")
    mins = Edicts.vector(s, entity, "mins")
    maxs = Edicts.vector(s, entity, "maxs")
    {_, _, down} = gravity = gravity_dir(s, entity)
    units = setting(s, "pr_droptofloorunits", 256.0)
    stop = Vec.madd(origin, gravity, if(units > 0, do: units, else: 256.0))
    {s, trace} = World.trace(s, origin, mins, maxs, stop, 0, entity)

    cond do
      trace.all_solid and setting(s, "sv_gameplayfix_droptofloorstartsolid", 0.0) != 0 and
          down == -1 ->
        drop_line(s, entity, {origin, stop}, {mins, maxs})

      trace.fraction == 1 or trace.all_solid ->
        return(s, 0.0)

      true ->
        land(s, entity, trace.end_pos, trace.hit)
    end
  end

  defp drop_line(s, entity, {origin, stop}, {mins, maxs}) do
    {ox, oy, _} = Vec.scale(Vec.add(maxs, mins), 0.5)
    {_, _, low} = mins
    offset = {ox, oy, low}
    from = Vec.add(origin, offset)
    to = Vec.add(stop, offset)
    {s, trace} = World.trace(s, from, Vec.zero(), Vec.zero(), to, 0, entity)

    if trace.fraction < 1,
      do: land(s, entity, Vec.sub(trace.end_pos, offset), trace.hit),
      else: s
  end

  defp land(s, entity, origin, hit) do
    s
    |> Edicts.put(entity, "origin", origin)
    |> World.link(entity, false)
    |> Edicts.set_flag(entity, :onground)
    |> Edicts.put(entity, "groundentity", hit || 0)
    |> return(1.0)
  end

  defp gravity_dir(s, entity) do
    case Edicts.vector(s, entity, "gravitydir") do
      {x, y, z} when x != 0 or y != 0 or z != 0 -> {x, y, z}
      _ -> {0.0, 0.0, -1.0}
    end
  end

  defp lightstyle(s, style, value) do
    s = %{s | lightstyles: Map.put(s.lightstyles, style, value)}
    Server.emit(s, {:lightstyle, style, value})
  end

  defp next_entity(s, entity) do
    Enum.find((entity + 1)..(s.count - 1)//1, 0, &(not Edicts.free?(s, &1)))
  end

  defp make_static(s, entity) do
    static = %{
      model: Edicts.string(s, entity, "model"),
      frame: Edicts.int(s, entity, "frame"),
      skin: Edicts.int(s, entity, "skin"),
      origin: Edicts.vector(s, entity, "origin"),
      angles: Edicts.vector(s, entity, "angles")
    }

    Edicts.free(%{s | statics: [static | s.statics]}, entity)
  end

  defp spawn_parms(s) do
    qc =
      (s.parms || [])
      |> Enum.with_index(1)
      |> Enum.reduce(s.qc, fn {value, i}, qc -> QuakeC.put_global(qc, "parm#{i}", value) end)

    %{s | qc: qc}
  end
end
