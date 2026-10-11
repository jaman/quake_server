defmodule QuakeServer.World do
  @moduledoc """
  Where a level's entities are, and what moving boxes run into, as FTE's `world.c` has it.

  Linking an entity records its box (`absmin`..`absmax`) and the map leaves it touches
  (`leaves`, kept after unlinking; `QuakeServer.Visibility`), and files it in the grid
  of `QuakeServer.World.Area` (`near/2` reads it back); traces test the world model and
  then the entities filed where the move passes, in the order they were filed. Triggers
  are touched when an entity is linked with `touch?` true.

      {server, trace} = QuakeServer.World.trace(server, start, mins, maxs, stop, 0, mover)
      QuakeServer.World.move(server, start, mins, maxs, stop, :normal, mover)

  A trace's `type` is FTE's `MOVE_` bits: 1 no monsters (only brush models block), 2
  missile (monsters are hit as 30-unit boxes), 3 the world alone, 4 against studio models'
  hitboxes, 16 triggers marked findable, 32 every entity marked findable whether linked
  or not, 128 a chain of the entities hit through their `chain` field, 256 the entity in
  the program's `other` alone, and `0x80000000` the mover's `hull` field left out. What
  stops the move is the mover's `hitcontentsmaski` (or `dphitcontentsmask`), otherwise
  the contents its solid kind and flags give.
  """

  import Bitwise

  alias Cauldron3D.Formats.Studio
  alias Cauldron3D.{Hull, Vec}
  alias QuakeServer.{Angles, Contents, Edicts, Models, Q, Server, Visibility}
  alias QuakeServer.World.{Area, Hitboxes, Hulls, Trace}

  @nomonsters 1
  @missile 2
  @world_only 3
  @hitmodel 4
  @triggers 16
  @everything 32
  @entity_chain 128
  @other_only 256
  @ignore_hull 0x80000000

  @findable_nonsolid 16_384

  @solid_not 0
  @solid_trigger 1
  @solid_slidebox 3
  @solid_bsp 4
  @solid_corpse 5
  @solid_ladder 20
  @solid_portal 21
  @solid_bsp_trigger 22

  @all_contents 0xFFFFFFFF
  @world_solid 0x00000003
  @player_solid 0x02010003
  @dimension_default 255

  @type type :: :normal | :nomonsters | :missile | non_neg_integer()

  @doc "Record `entity`'s box, and touch the triggers it is in when `touch?`."
  @spec link(Server.t(), non_neg_integer(), boolean()) :: Server.t()
  def link(%Server{} = server, entity, touch?) do
    server = unlink(server, entity)

    cond do
      entity == 0 -> server
      Edicts.free?(server, entity) -> server
      true -> place(server, entity, touch?)
    end
  end

  @doc "Forget `entity`'s box."
  @spec unlink(Server.t(), non_neg_integer()) :: Server.t()
  def unlink(%Server{} = server, entity) do
    case Map.pop(server.links, entity) do
      {nil, _links} ->
        server

      {link, links} ->
        %{server | links: links, area: Area.unfile(server.area, entity, link.cells)}
    end
  end

  @doc "The linked entities filed where the box `{mins, maxs}` lies."
  @spec near(Server.t(), {Vec.t(), Vec.t()}) :: MapSet.t(non_neg_integer())
  def near(%Server{} = server, box), do: server |> filed(box) |> MapSet.new()

  @doc """
  Run the touch of every trigger whose box `entity`'s box overlaps, last filed first,
  stopping once `entity` is freed (`World_TouchAllLinks`).
  """
  @spec touch_triggers(Server.t(), non_neg_integer()) :: Server.t()
  def touch_triggers(%Server{} = server, entity) do
    box = abs_box(server, entity)

    server
    |> filed(box)
    |> Enum.filter(&trigger_near?(server, &1, box))
    |> Enum.reverse()
    |> Enum.reduce_while(server, fn trigger, acc ->
      acc = touch(acc, trigger, entity)
      if Edicts.free?(acc, entity), do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  @doc "A line from `start` to `stop` through the world model alone, no entities."
  @spec trace_world(Server.t(), Vec.t(), Vec.t()) :: Hull.Trace.t()
  def trace_world(%Server{} = server, start, stop),
    do: move(server, start, Vec.zero(), Vec.zero(), stop, @world_only, 0)

  @doc "The contents bits (`QuakeServer.Contents`) of the world model at `point` (`World_PointContentsWorldOnly`)."
  @spec contents_world(Server.t(), Vec.t()) :: non_neg_integer()
  def contents_world(%Server{bsp: bsp}, point),
    do: Contents.of_code(Hull.contents(hd(bsp.hulls), point))

  @doc """
  The contents bits at `point` of the world and of every `SOLID_BSP` entity whose box
  holds it, a brush entity with a negative `skin` giving the contents that skin forces
  wherever it has any (`World_PointContentsAllBSPs`).
  """
  @spec contents_all(Server.t(), Vec.t()) :: non_neg_integer()
  def contents_all(%Server{} = server, point) do
    server
    |> filed({point, point})
    |> Enum.reduce(contents_world(server, point), fn entity, bits ->
      bor(bits, entity_contents(server, entity, point))
    end)
  end

  @doc """
  The contents bits of everything a box of `mins`..`maxs` at `origin` is inside: the
  world at `origin`, and every brush entity it overlaps, other than `entity`, by the
  contents its negative `skin` forces or as solid.
  """
  @spec box_contents(Server.t(), Vec.t(), Vec.t(), Vec.t(), non_neg_integer()) ::
          non_neg_integer()
  def box_contents(%Server{} = server, origin, mins, maxs, entity) do
    box = {Vec.add(origin, mins), Vec.add(origin, maxs)}

    server
    |> filed(box)
    |> Enum.reduce(contents_world(server, origin), fn other, bits ->
      bor(bits, box_entity_contents(server, other, entity, {origin, mins, maxs}))
    end)
  end

  @doc "What `point` is in: a contents value, liquids by kind."
  @spec point_contents(Server.t(), Vec.t()) :: integer()
  def point_contents(%Server{bsp: bsp}, point) do
    case Hull.contents(hd(bsp.hulls), point) do
      current when current <= -9 and current >= -14 -> Q.contents(:water)
      contents -> contents
    end
  end

  @doc """
  Whether `entity`'s box, where it stands, is inside something solid; brush models only
  for a non-solid or trigger entity (`World_TestEntityPosition`).
  """
  @spec stuck?(Server.t(), non_neg_integer()) :: boolean()
  def stuck?(%Server{} = server, entity) do
    origin = Edicts.vector(server, entity, "origin")
    solid = Edicts.int(server, entity, "solid")
    type = if solid in [@solid_not, @solid_trigger, @solid_bsp_trigger], do: @nomonsters, else: 0

    {_server, trace} =
      trace(
        server,
        origin,
        Edicts.vector(server, entity, "mins"),
        Edicts.vector(server, entity, "maxs"),
        origin,
        type,
        entity
      )

    trace.start_solid or trace.all_solid
  end

  @doc """
  A box of `mins`..`maxs` moved from `start` to `stop` for `mover`, as `trace/7` with
  `type` `:normal` (0), `:nomonsters` (1), `:missile` (2) or `MOVE_` bits without the
  entity chain; the result as a `Cauldron3D.Hull.Trace`.
  """
  @spec move(Server.t(), Vec.t(), Vec.t(), Vec.t(), Vec.t(), type(), non_neg_integer()) ::
          Hull.Trace.t()
  def move(%Server{} = server, start, mins, maxs, stop, type, mover) do
    {_server, trace} = trace(server, start, mins, maxs, stop, type_bits(type), mover)
    Trace.to_hull(trace)
  end

  @doc """
  A box of `mins`..`maxs` moved from `start` to `stop` for `mover`, stopped by the first
  thing in the way (`World_Move`). `type` is `MOVE_` bits (see the module doc). Starting
  inside something marks the trace `start_solid` without stopping it there: whatever
  the box meets later still stops it. The server comes back with the `chain` fields an
  entity-chain trace writes.
  """
  @spec trace(Server.t(), Vec.t(), Vec.t(), Vec.t(), Vec.t(), type(), non_neg_integer()) ::
          {Server.t(), Trace.t()}
  def trace(%Server{} = server, start, mins, maxs, stop, type, mover) do
    type = type_bits(type)

    clip = %{
      start: start,
      stop: stop,
      mins: mins,
      maxs: maxs,
      type: type,
      mover: mover,
      passer: if(mover == 0, do: nil, else: mover),
      hull: world_hull(server, mover, type, mins, maxs),
      mask: hit_mask(server, mover, mins, maxs)
    }

    cond do
      (type &&& @other_only) != 0 -> {server, clip_other(server, clip)}
      (type &&& @world_only) == @world_only -> {server, clip_world(server, clip, hitmodel?(type))}
      true -> clip_around(server, clip)
    end
  end

  @doc """
  The hull of `hulls` a box of `size` moves through, as FTE chooses it with no hull
  forced (`Q1BSP_ChooseHull`): under 3 wide the point hull, up to 32.1 wide hull 3 (Half-
  Life's crouching hull) when under 54.1 high or else hull 1, wider hull 2, each falling
  back to a smaller hull the list has.
  """
  @spec choose_hull([Hull.t()], Vec.t()) :: Hull.t()
  def choose_hull(hulls, size) do
    {hull, _offset} = Hulls.choose(hulls, 0, Vec.zero(), size)
    hull
  end

  defp place(server, entity, touch?) do
    {absmin, absmax} = bounds(server, entity)
    cells = Area.cells(grid(server), absmin, absmax)

    server =
      server
      |> Edicts.put(entity, "absmin", absmin)
      |> Edicts.put(entity, "absmax", absmax)

    server = %{
      server
      | leaves: Map.put(server.leaves, entity, Visibility.touched(server.bsp, absmin, absmax)),
        links: Map.put(server.links, entity, %{absmin: absmin, absmax: absmax, cells: cells}),
        area: Area.file(server.area, entity, cells)
    }

    if touch? and Edicts.int(server, entity, "solid") != @solid_not,
      do: touch_triggers(server, entity),
      else: server
  end

  defp grid(%Server{bsp: bsp}) do
    world = elem(bsp.models, 0)
    Area.grid(world.mins, world.maxs)
  end

  defp filed(server, box), do: Area.entities(server.area, grid(server), box)

  @doc """
  The box (`absmin`, `absmax`) linking `entity` would give it now, from its origin, size,
  `solid` and angles; an entity that changed these without being linked again still holds
  its old box.
  """
  @spec bounds(Server.t(), non_neg_integer()) :: {Vec.t(), Vec.t()}
  def bounds(%Server{} = server, entity) do
    origin = Edicts.vector(server, entity, "origin")
    solid = Edicts.int(server, entity, "solid")
    {mins, maxs} = extent(server, entity, solid)

    {absmin, absmax} =
      if solid in [@solid_bsp, @solid_bsp_trigger] and
           turned?(Edicts.vector(server, entity, "angles")),
         do: cube(origin, mins, maxs),
         else: {Vec.add(origin, mins), Vec.add(origin, maxs)}

    pad = if Edicts.flag?(server, entity, :item), do: {15.0, 15.0, 1.0}, else: {1.0, 1.0, 1.0}
    {Vec.sub(absmin, pad), Vec.add(absmax, pad)}
  end

  defp extent(server, entity, @solid_bsp) do
    case Models.get(server, Edicts.int(server, entity, "modelindex")) do
      %{kind: :brush, mins: mins, maxs: maxs} -> {mins, maxs}
      _ -> {Edicts.vector(server, entity, "mins"), Edicts.vector(server, entity, "maxs")}
    end
  end

  defp extent(server, entity, _solid),
    do: {Edicts.vector(server, entity, "mins"), Edicts.vector(server, entity, "maxs")}

  defp cube(origin, {x0, y0, z0}, {x1, y1, z1}) do
    reach = Enum.max(Enum.map([x0, y0, z0, x1, y1, z1], &abs/1))
    {Vec.sub(origin, {reach, reach, reach}), Vec.add(origin, {reach, reach, reach})}
  end

  defp turned?({pitch, yaw, roll}), do: pitch != 0 or yaw != 0 or roll != 0

  defp abs_box(server, entity),
    do: {Edicts.vector(server, entity, "absmin"), Edicts.vector(server, entity, "absmax")}

  defp trigger_near?(server, other, {absmin, absmax}) do
    Edicts.int(server, other, "solid") in [@solid_trigger, @solid_bsp_trigger] and
      overlap?(abs_box(server, other), {absmin, absmax})
  end

  defp touch(server, trigger, entity) do
    if touches?(server, trigger, entity) do
      self = QuakeC.global(server.qc, "self")
      other = QuakeC.global(server.qc, "other")

      server
      |> Server.run(Edicts.int(server, trigger, "touch"), trigger, entity)
      |> restore(self, other)
    else
      server
    end
  end

  defp touches?(server, trigger, entity) do
    solid = Edicts.int(server, trigger, "solid")

    not Edicts.free?(server, trigger) and Edicts.int(server, trigger, "touch") != 0 and
      solid in [@solid_trigger, @solid_bsp_trigger] and trigger != entity and
      overlap?(abs_box(server, entity), abs_box(server, trigger)) and
      (dimension(server, entity, "dimension_solid") &&&
         dimension(server, trigger, "dimension_hit")) !=
        0 and
      (solid != @solid_bsp_trigger or in_shape?(server, trigger, entity))
  end

  defp in_shape?(server, trigger, entity) do
    origin = Edicts.vector(server, entity, "origin")

    move =
      {origin, origin, Edicts.vector(server, entity, "mins"),
       Edicts.vector(server, entity, "maxs")}

    clip_to_entity(server, trigger, move, 0, false, @world_solid).start_solid
  end

  defp restore(server, self, other) do
    qc =
      server.qc
      |> QuakeC.put_global("self", self)
      |> QuakeC.put_global("other", other)

    %{server | qc: qc}
  end

  defp overlap?({{ax0, ay0, az0}, {ax1, ay1, az1}}, {{bx0, by0, bz0}, {bx1, by1, bz1}}),
    do: not (ax0 > bx1 or ay0 > by1 or az0 > bz1 or ax1 < bx0 or ay1 < by0 or az1 < bz0)

  defp dimension(server, entity, name) do
    if QuakeC.field_offset(server.qc, name) == nil,
      do: @dimension_default,
      else: Edicts.int(server, entity, name)
  end

  defp type_bits(:normal), do: 0
  defp type_bits(:nomonsters), do: @nomonsters
  defp type_bits(:missile), do: @missile
  defp type_bits(type) when is_integer(type), do: type

  defp hitmodel?(type), do: (type &&& @hitmodel) != 0

  defp world_hull(server, mover, type, mins, maxs) do
    hull = Edicts.float(server, mover, "hull")

    cond do
      hull != 0 and (type &&& @ignore_hull) == 0 -> trunc(hull)
      setting(server, "sv_compatiblehulls", 1.0) != 0 -> 0
      true -> nearest_hull(server.bsp.hulls, mins, maxs)
    end
  end

  defp nearest_hull(hulls, {mx, _, mz}, {_, xy, xz}) do
    {index, _best} =
      0..7
      |> Enum.filter(&Hulls.available?(hulls, &1))
      |> Enum.reduce({0, 8192}, fn index, {chosen, best} ->
        %Hull{mins: {hx0, _, hz0}, maxs: {_, hy1, hz1}} = Enum.at(hulls, index)

        difference =
          trunc(square(hz1 - xz) + square(hz0 - mz) + square(hy1 - xy) + square(hx0 - mx))

        if difference < best, do: {index, difference}, else: {chosen, best}
      end)

    index + 1
  end

  defp square(value), do: value * value

  defp setting(server, name, default),
    do: if(Server.cvar?(server, name), do: Server.cvar(server, name), else: default)

  defp hit_mask(server, mover, mins, maxs) do
    own = int_field(server, mover, "hitcontentsmaski")
    dp = Edicts.int(server, mover, "dphitcontentsmask")

    cond do
      own != 0 -> own
      dp != 0 -> Contents.from_dp(dp &&& @all_contents)
      true -> solid_mask(server, mover, Edicts.int(server, mover, "solid"), mins, maxs)
    end
  end

  defp int_field(server, entity, name) do
    case Edicts.get(server, entity, name) do
      value when is_integer(value) -> value &&& @all_contents
      value when is_float(value) -> trunc(value) &&& @all_contents
      _ -> 0
    end
  end

  defp solid_mask(server, mover, @solid_slidebox, {x0, _, _}, {x1, _, _}) do
    base = Contents.bit(:solid) ||| Contents.bit(:window) ||| Contents.bit(:body)

    cond do
      Edicts.flag?(server, mover, :monster) -> base ||| Contents.bit(:monster_clip)
      x1 - x0 > 0 -> base ||| Contents.bit(:player_clip)
      true -> base
    end
  end

  defp solid_mask(_server, _mover, solid, _mins, _maxs)
       when solid in [@solid_corpse, @solid_trigger, @solid_bsp_trigger],
       do: Contents.bit(:solid) ||| Contents.bit(:window) ||| Contents.bit(:body)

  defp solid_mask(_server, _mover, _solid, _mins, _maxs),
    do:
      Contents.bit(:solid) ||| Contents.bit(:window) ||| Contents.bit(:body) |||
        Contents.bit(:corpse)

  defp clip_other(server, clip) do
    other = trunc(QuakeC.float(QuakeC.global(server.qc, "other")))
    move = {clip.start, clip.stop, clip.mins, clip.maxs}
    clip_to_entity(server, other, move, clip.hull, hitmodel?(clip.type), clip.mask)
  end

  defp clip_world(server, clip, hitmodel?) do
    move = {clip.start, clip.stop, clip.mins, clip.maxs}
    clip_to_entity(server, 0, move, clip.hull, hitmodel?, clip.mask)
  end

  defp clip_around(server, clip) do
    world = clip_world(server, clip, false)

    {mins2, maxs2} =
      if (clip.type &&& @missile) != 0,
        do: {{-15.0, -15.0, -15.0}, {15.0, 15.0, 15.0}},
        else: {clip.mins, clip.maxs}

    clip =
      Map.merge(clip, %{
        mins2: mins2,
        maxs2: maxs2,
        box: move_bounds(clip.start, mins2, maxs2, clip.stop)
      })

    candidates =
      if (clip.type &&& @everything) != 0,
        do: Enum.filter(1..(server.count - 1)//1, &everything?(server, clip, &1)),
        else: Enum.filter(filed(server, clip.box), &linked?(server, clip, &1))

    Enum.reduce(candidates, {server, world}, fn touch, {acc, trace} ->
      clip_candidate(acc, clip, touch, trace)
    end)
  end

  defp move_bounds(start, mins, maxs, stop) do
    {low, high} =
      [start, stop, mins, maxs]
      |> Enum.map(&Tuple.to_list/1)
      |> Enum.zip()
      |> Enum.map(&axis_bounds/1)
      |> Enum.unzip()

    {List.to_tuple(low), List.to_tuple(high)}
  end

  defp axis_bounds({from, to, low, high}) when to > from, do: {from + low - 1, to + high + 1}
  defp axis_bounds({from, to, low, high}), do: {to + low - 1, from + high + 1}

  defp linked?(server, clip, touch) do
    solid = Edicts.int(server, touch, "solid")

    cond do
      solid == @solid_not -> false
      touch == clip.passer -> false
      trigger_kind?(solid) and not findable_trigger?(server, clip, touch) -> false
      nomonsters?(clip) and solid not in [@solid_bsp, @solid_portal] -> false
      true -> reachable?(server, clip, touch)
    end
  end

  defp trigger_kind?(solid), do: solid in [@solid_trigger, @solid_bsp_trigger, @solid_ladder]

  defp findable_trigger?(server, clip, touch),
    do: (clip.type &&& @triggers) != 0 and findable?(server, touch)

  defp findable?(server, entity),
    do: (Edicts.int(server, entity, "flags") &&& @findable_nonsolid) != 0

  defp nomonsters?(clip), do: (clip.type &&& @nomonsters) != 0

  defp everything?(server, clip, touch) do
    solid = Edicts.int(server, touch, "solid")
    not excluded?(server, clip, touch, solid) and reachable?(server, clip, touch)
  end

  defp excluded?(server, clip, touch, solid) do
    Edicts.free?(server, touch) or unfound?(server, touch, solid) or touch == clip.passer or
      (nomonsters?(clip) and solid != @solid_bsp) or corpse_passes?(server, clip.passer, solid)
  end

  defp unfound?(server, touch, solid),
    do: solid in [@solid_not, @solid_trigger, @solid_bsp_trigger] and not findable?(server, touch)

  defp corpse_passes?(_server, nil, _solid), do: false

  defp corpse_passes?(server, passer, solid) do
    case Edicts.int(server, passer, "solid") do
      @solid_corpse -> solid in [@solid_slidebox, @solid_corpse]
      @solid_slidebox -> solid == @solid_corpse
      _ -> false
    end
  end

  defp reachable?(server, clip, touch) do
    cond do
      not dimension_meets?(server, clip.passer, touch) -> false
      not overlap?(clip.box, abs_box(server, touch)) -> false
      point_against_point?(server, clip.passer, touch) -> false
      owned?(server, clip.passer, touch) -> false
      true -> true
    end
  end

  defp dimension_meets?(_server, nil, _touch), do: true

  defp dimension_meets?(server, passer, touch),
    do:
      (dimension(server, passer, "dimension_hit") &&& dimension(server, touch, "dimension_solid")) !=
        0

  defp point_against_point?(_server, nil, _touch), do: false

  defp point_against_point?(server, passer, touch) do
    {passer_x, _, _} = Edicts.vector(server, passer, "size")
    {touch_x, _, _} = Edicts.vector(server, touch, "size")
    passer_x != 0 and touch_x == 0
  end

  defp owned?(_server, nil, _touch), do: false

  defp owned?(server, passer, touch),
    do:
      Edicts.int(server, touch, "owner") == passer or Edicts.int(server, passer, "owner") == touch

  defp clip_candidate(server, clip, touch, current) do
    {mins, maxs} =
      if Edicts.flag?(server, touch, :monster),
        do: {clip.mins2, clip.maxs2},
        else: {clip.mins, clip.maxs}

    move = {clip.start, clip.stop, mins, maxs}
    trace = clip_to_entity(server, touch, move, 0, hitmodel?(clip.type), clip.mask)
    combine(server, current, trace, touch, (clip.type &&& @entity_chain) != 0)
  end

  defp combine(server, current, trace, touch, true) when trace.fraction < current.fraction do
    server = Edicts.put(server, touch, "chain", (current.hit || 0) / 1)
    {server, %{current | hit: touch}}
  end

  defp combine(server, current, trace, touch, _chain?) when trace.fraction < current.fraction do
    hit = if current.start_solid and not trace.start_solid, do: current.hit, else: touch

    {server,
     %{
       trace
       | start_solid: trace.start_solid or current.start_solid,
         all_solid: trace.all_solid or current.all_solid,
         hit: hit
     }}
  end

  defp combine(server, current, trace, touch, _chain?)
       when trace.start_solid or trace.all_solid do
    hit =
      if current.hit == nil or trace.fraction == current.fraction, do: touch, else: current.hit

    {server,
     %{
       current
       | start_solid: current.start_solid or trace.start_solid,
         all_solid: current.all_solid or trace.all_solid,
         contents: current.contents ||| trace.contents,
         hit: hit
     }}
  end

  defp combine(server, current, _trace, _touch, _chain?), do: {server, current}

  defp clip_to_entity(server, entity, move, hull, hitmodel?, mask) do
    solid = Edicts.int(server, entity, "solid")
    model = brush_model(server, entity, solid)

    server
    |> clipped(entity, {model, solid}, move, hull, mask)
    |> meshed(server, entity, move, mask, hitmodel? and model == nil)
    |> struck(entity)
  end

  defp clipped(server, entity, {model, solid}, move, hull, mask) do
    cond do
      solid == @solid_corpse ->
        forced(server, entity, model, move, hull, mask, Contents.bit(:corpse))

      (skin = Edicts.int(server, entity, "skin")) < 0 ->
        forced(server, entity, model, move, hull, mask, Contents.forced(skin))

      true ->
        transformed(server, entity, model, move, hull, mask)
    end
  end

  defp meshed(trace, server, entity, move, mask, true)
       when trace.fraction != 1 or trace.start_solid,
       do: on_mesh(server, entity, move, mask, trace)

  defp meshed(trace, _server, _entity, _move, _mask, _mesh?), do: trace

  defp struck(trace, entity) when trace.fraction < 1 or trace.start_solid or trace.all_solid,
    do: %{trace | hit: entity}

  defp struck(trace, _entity), do: trace

  defp brush_model(server, entity, solid)
       when solid in [@solid_bsp, @solid_bsp_trigger, @solid_portal] do
    case Edicts.int(server, entity, "modelindex") do
      0 -> nil
      index -> brush(Models.get(server, index))
    end
  end

  defp brush_model(_server, _entity, _solid), do: nil

  defp brush(%{kind: :brush, hulls: [_ | _]} = model), do: model
  defp brush(_model), do: nil

  defp forced(server, entity, model, {_start, stop, _mins, _maxs} = move, hull, mask, bits) do
    if (mask &&& bits) != 0 do
      trace = transformed(server, entity, model, move, hull, @all_contents)
      if trace.contents != 0, do: %{trace | contents: bits}, else: trace
    else
      %Trace{fraction: 1.0, all_solid: false, start_solid: false, in_open: true, end_pos: stop}
    end
  end

  defp transformed(server, entity, nil, {start, stop, mins, maxs}, _hull, mask) do
    origin = Edicts.vector(server, entity, "origin")
    from = Vec.sub(start, origin)
    to = Vec.sub(stop, origin)
    blank = %Trace{fraction: 1.0, all_solid: true, in_open: true, end_pos: stop}

    if (mask &&& Contents.bit(:body)) != 0 do
      box =
        Hull.box(
          Vec.sub(Edicts.vector(server, entity, "mins"), maxs),
          Vec.sub(Edicts.vector(server, entity, "maxs"), mins)
        )

      trace = Hulls.check(box, from, to, @player_solid, %{blank | end_pos: to})
      trace = %{trace | end_pos: Vec.add(trace.end_pos, origin)}
      if trace.contents != 0, do: %{trace | contents: Contents.bit(:body)}, else: trace
    else
      blank
    end
  end

  defp transformed(server, entity, model, {start, stop, mins, maxs}, hull, mask) do
    origin = Edicts.vector(server, entity, "origin")
    axes = axes(Edicts.vector(server, entity, "angles"))

    trace =
      Hulls.trace(
        model.hulls,
        hull,
        axes,
        Vec.sub(start, origin),
        Vec.sub(stop, origin),
        mins,
        maxs,
        mask
      )

    %{trace | end_pos: Vec.add(trace.end_pos, origin)}
  end

  defp axes(angles) do
    if turned?(angles) do
      {forward, right, up} = Angles.vectors(angles)
      {forward, Vec.scale(right, -1.0), up}
    end
  end

  defp on_mesh(server, entity, {start, stop, mins, maxs}, mask, trace) do
    case Models.get(server, Edicts.int(server, entity, "modelindex")) do
      %{kind: :studio, data: %Studio{} = studio} ->
        origin = Edicts.vector(server, entity, "origin")
        axes = axes(Edicts.vector(server, entity, "angles"))
        from = Vec.sub(start, origin)
        to = Vec.sub(stop, origin)

        case Hitboxes.trace(studio, pose(server, entity), axes, from, to, mins, maxs, mask) do
          {:ok, struck} -> %{struck | end_pos: Vec.add(struck.end_pos, origin)}
          :unposed -> trace
        end

      _ ->
        trace
    end
  end

  defp pose(server, entity) do
    %{
      sequence: Edicts.int(server, entity, "frame"),
      time: Edicts.float(server, entity, "frame1time"),
      base_sequence: Edicts.int(server, entity, "baseframe"),
      base_bones: Edicts.int(server, entity, "basebone")
    }
  end

  defp entity_contents(server, entity, point) do
    with @solid_bsp <- Edicts.int(server, entity, "solid"),
         true <- inside?(point, abs_box(server, entity)),
         index when index != 0 <- Edicts.int(server, entity, "modelindex"),
         %{hulls: [hull | _]} <- brush(Models.get(server, index)) do
      at =
        point
        |> Vec.sub(Edicts.vector(server, entity, "origin"))
        |> local(entity_axes(server, entity))

      bits = Contents.of_code(Hull.contents(hull, at))
      skin = Edicts.int(server, entity, "skin")
      if bits != 0 and skin < 0, do: Contents.forced(skin), else: bits
    else
      _ -> 0
    end
  end

  defp entity_axes(server, entity), do: axes(Edicts.vector(server, entity, "angles"))

  defp local(point, nil), do: point

  defp local(point, {a0, a1, a2}),
    do: {Vec.dot(point, a0), Vec.dot(point, a1), Vec.dot(point, a2)}

  defp inside?({x, y, z}, {{x0, y0, z0}, {x1, y1, z1}}),
    do: x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z0 and z <= z1

  defp box_entity_contents(_server, entity, entity, _place), do: 0

  defp box_entity_contents(server, other, _entity, {origin, mins, maxs}) do
    solid = Edicts.int(server, other, "solid")

    with true <- Map.has_key?(server.links, other),
         true <- Q.brush?(solid),
         %{} = model <- brush_model(server, other, solid),
         move = {origin, origin, mins, maxs},
         %Trace{start_solid: true} <-
           transformed(server, other, model, move, 0, Contents.bit(:solid)) do
      skin = Edicts.int(server, other, "skin")
      if skin < 0, do: Contents.forced(skin), else: Contents.bit(:solid)
    else
      _ -> 0
    end
  end
end
