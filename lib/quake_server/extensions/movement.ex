defmodule QuakeServer.Extensions.Movement do
  @moduledoc """
  FTE's movement builtins: the engine's player movement (`runstandardplayerphysics`),
  area portals (`openportal`) and the rigid-body physics calls.

  `runstandardplayerphysics(entity)` moves `entity` with `QuakeServer.Pmove` by the
  `input_timelength`, `input_angles`, `input_movevalues` and `input_buttons` globals,
  in steps of at most 50 milliseconds. It reads the entity's `origin`, `oldorigin`,
  `velocity`, `mins`, `maxs`, `gravitydir`, `gravity`, `maxspeed`, `hasted`, `flags`,
  `movetype`, `health`, `teleport_time` and `pmove_flags`. After each step it writes
  `origin`, `oldorigin`, `velocity`, `v_angle`, `waterlevel`, `watertype`,
  `teleport_time`, `pmove_flags` (1 jump held, 2 on a ladder), `flags` (`FL_ONGROUND`
  512) and, on ground, `groundentity`; links the entity, touching its triggers; and runs
  the touch of each entity the step ran into, each at most once per call.

  The player meets the world and the entities within 256 units whose `solid` is a box
  (2), slide box (3), brush (4), ladder (20) or a trigger (1) with a negative `skin`,
  other than its own missiles, those `dimension_hit` and `dimension_solid` keep apart
  (255 when the program lacks the fields) and those with no width. A negative `skin`
  gives contents to the whole entity: -2, -8 and -18 block the player, the others only
  fill. The movement settings are the cvars `sv_gravity`, `sv_stopspeed`,
  `sv_maxspeed`, `sv_spectatormaxspeed`, `sv_accelerate`, `sv_wateraccelerate`,
  `sv_friction`, `sv_waterfriction`, `sv_bigcoords`, `pm_noround`, `pm_bunnyspeedcap`,
  `pm_ktjump`, `pm_walljump`, `pm_slidefix`, `pm_airstep`, `pm_pground`,
  `pm_stepdown`, `pm_slidyslopes`, `pm_autobunny` and `pm_bunnyfriction`, and
  `pm_flyfriction` (4), `pm_watersinkspeed` (60), `pm_edgefriction` (2, testing ledges
  with the player's box while empty) and `pm_stepheight` (18), which take the value in
  brackets while empty. `sv_brokenmovetypes` and `sv_nqplayerphysics` choose the
  movement type as FTE does; entities 1 up to `sv_playerslots` are players.

  Portal states are kept in the host's `ext.portals`, entity number to state; a map
  without areas is not divided by them. There is no rigid-body engine:
  `physics_supported` answers false and `physics_enable`, `physics_addforce` and
  `physics_addtorque` change nothing.
  """

  import Bitwise

  alias Cauldron3D.Vec
  alias QuakeC.Progs
  alias QuakeServer.{Args, Contents, Edicts, Models, Pmove, Server, World}
  alias QuakeServer.Pmove.{Command, Movevars, Physent}

  @step_msec 50
  @reach {256.0, 256.0, 256.0}
  @onground 512
  @jump_held 1
  @on_ladder 2
  @dimension_default 255
  @zero {0.0, 0.0, 0.0}

  @doc "Run movement builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 347, _argc), do: run_player_physics(s, Args.int(s, 0))

  def call(s, 207, _argc),
    do: %{
      s
      | ext:
          Map.update(
            s.ext,
            :portals,
            %{Args.int(s, 0) => Args.num(s, 1)},
            &Map.put(&1, Args.int(s, 0), Args.num(s, 1))
          )
    }

  def call(s, "physics_supported", _argc), do: Args.return(s, false)
  def call(s, builtin, _argc) when builtin in 540..542, do: s

  defp run_player_physics(server, entity) do
    msecs = trunc(QuakeC.float(QuakeC.global(server.qc, "input_timelength")) * 1000 + 0.5)
    steps(player_state(server, entity), entity, max(msecs, 0), MapSet.new())
  end

  defp steps(pm, _entity, 0, _touched), do: pm.server

  defp steps(pm, entity, msecs, touched) do
    msec = min(msecs, @step_msec)
    pm = Pmove.player_move(%{pm | cmd: %{pm.cmd | msec: msec / 1}})
    {server, touched} = pm.server |> store(entity, pm) |> touch_all(entity, pm, touched)
    steps(%{pm | server: server, touched: []}, entity, msecs - msec, touched)
  end

  defp player_state(server, entity) do
    origin = Edicts.vector(server, entity, "origin")

    %Pmove{
      server: server,
      physents: physents(server, entity, origin),
      movevars: movevars(server, entity),
      cmd: command(server.qc),
      pm_type: pm_type(server, entity),
      origin: origin,
      velocity: Edicts.vector(server, entity, "velocity"),
      mins: Edicts.vector(server, entity, "mins"),
      maxs: Edicts.vector(server, entity, "maxs"),
      angles: QuakeC.global_vector(server.qc, "input_angles"),
      gravitydir: Edicts.vector(server, entity, "gravitydir"),
      safeorigin: Edicts.vector(server, entity, "oldorigin"),
      safeorigin_known: true,
      jump_held: (Edicts.int(server, entity, "pmove_flags") &&& @jump_held) != 0,
      jump_msec: 0,
      waterjumptime: Edicts.float(server, entity, "teleport_time") - server.time,
      onground: Edicts.flag?(server, entity, :onground),
      groundent: 0,
      waterlevel: 0,
      watertype: 0,
      onladder: false
    }
  end

  defp command(qc) do
    {forward, side, up} = QuakeC.global_vector(qc, "input_movevalues")
    {pitch, yaw, roll} = QuakeC.global_vector(qc, "input_angles")

    %Command{
      angles: {to_short(pitch), to_short(yaw), to_short(roll)},
      forward: move_value(forward),
      side: move_value(side),
      up: move_value(up),
      buttons: trunc(QuakeC.float(QuakeC.global(qc, "input_buttons"))),
      msec: 0.0
    }
  end

  defp move_value(value), do: value |> max(-32_767.0) |> min(32_767.0) |> trunc()

  defp to_short(angle) do
    value = trunc(angle * (65_536 / 360.0))

    value =
      if value > 2_147_483_647 or value < -2_147_483_648, do: -2_147_483_648, else: value

    bits = value &&& 0xFFFF
    if bits >= 0x8000, do: bits - 0x10000, else: bits
  end

  defp player?(server, entity),
    do: entity >= 1 and entity <= trunc(Server.cvar(server, "sv_playerslots"))

  defp pm_type(server, entity) do
    cond do
      Server.cvar(server, "sv_brokenmovetypes") != 0 -> dead_or_normal(server, entity)
      nq_physics?(server) -> :none
      true -> movetype_pm(Edicts.int(server, entity, "movetype"), server, entity)
    end
  end

  defp dead_or_normal(server, entity),
    do: if(Edicts.float(server, entity, "health") <= 0, do: :dead, else: :normal)

  defp movetype_pm(8, server, entity),
    do: if(player?(server, entity), do: :spectator, else: :old_spectator)

  defp movetype_pm(31, _server, _entity), do: :wallwalk
  defp movetype_pm(30, _server, _entity), do: :six_dof
  defp movetype_pm(movetype, _server, _entity) when movetype in [5, 33], do: :fly
  defp movetype_pm(0, _server, _entity), do: :none

  defp movetype_pm(_movetype, server, entity) do
    if player?(server, entity), do: dead_or_normal(server, entity), else: :normal
  end

  defp nq_physics?(server) do
    case Server.cvar_string(server, "sv_nqplayerphysics") do
      text when text in ["", "auto"] ->
        nq_by_program?(server)

      _value ->
        value = trunc(Server.cvar(server, "sv_nqplayerphysics"))
        value != 0 and value != 2
    end
  end

  defp nq_by_program?(server) do
    progs = server.qc.progs

    cond do
      Progs.function(progs, "SV_RunClientCommand") -> false
      Progs.function(progs, "SV_PlayerPhysics") -> true
      Server.cvar(server, "sv_playerslots") > 1 -> false
      true -> true
    end
  end

  defp movevars(server, entity) do
    %Movevars{
      gravity: Server.cvar(server, "sv_gravity"),
      stopspeed: Server.cvar(server, "sv_stopspeed"),
      maxspeed: max_speed(server, entity),
      spectatormaxspeed: Server.cvar(server, "sv_spectatormaxspeed"),
      accelerate: Server.cvar(server, "sv_accelerate"),
      wateraccelerate: Server.cvar(server, "sv_wateraccelerate"),
      friction: Server.cvar(server, "sv_friction"),
      waterfriction: Server.cvar(server, "sv_waterfriction"),
      flyfriction: or_default(server, "pm_flyfriction", 4.0),
      entgravity: ent_gravity(Edicts.float(server, entity, "gravity")),
      bunnyspeedcap: Server.cvar(server, "pm_bunnyspeedcap"),
      watersinkspeed: or_default(server, "pm_watersinkspeed", 60.0),
      ktjump: Server.cvar(server, "pm_ktjump"),
      edgefriction: or_default(server, "pm_edgefriction", 2.0),
      edge_box: Server.cvar_string(server, "pm_edgefriction") == "",
      walljump: trunc(Server.cvar(server, "pm_walljump")),
      slidefix: on?(server, "pm_slidefix"),
      airstep: on?(server, "pm_airstep"),
      pground: on?(server, "pm_pground"),
      stepdown: on?(server, "pm_stepdown"),
      slidyslopes: on?(server, "pm_slidyslopes"),
      autobunny: on?(server, "pm_autobunny"),
      bunnyfriction: on?(server, "pm_bunnyfriction"),
      stepheight: trunc(or_default(server, "pm_stepheight", 18.0)),
      coordtype: if(on?(server, "sv_bigcoords"), do: :float, else: :fixed_13_3),
      noround: on?(server, "pm_noround")
    }
  end

  defp on?(server, name), do: Server.cvar(server, name) != 0

  defp or_default(server, name, default) do
    if Server.cvar_string(server, name) == "", do: default, else: Server.cvar(server, name)
  end

  defp ent_gravity(gravity) when gravity == 0, do: 1.0
  defp ent_gravity(gravity), do: gravity

  defp max_speed(server, entity) do
    own = Edicts.float(server, entity, "maxspeed")
    speed = if own != 0, do: own, else: Server.cvar(server, "sv_maxspeed")
    hasted = Edicts.float(server, entity, "hasted")
    if hasted != 0, do: speed * hasted, else: speed
  end

  defp physents(server, entity, origin) do
    low = Vec.sub(origin, @reach)
    high = Vec.add(origin, @reach)

    world = %Physent{
      entity: 0,
      origin: @zero,
      model: Models.get(server, Edicts.int(server, 0, "modelindex"))
    }

    others =
      server
      |> World.near({low, high})
      |> Enum.sort()
      |> Enum.filter(&candidate?(server, entity, &1, {low, high}))
      |> Enum.flat_map(&physent(server, entity, &1))

    List.to_tuple([world | others])
  end

  defp candidate?(server, entity, other, {low, high}) do
    other != entity and not Edicts.free?(server, other) and
      Edicts.int(server, other, "owner") != entity and
      collides?(Edicts.int(server, other, "solid"), Edicts.float(server, other, "skin")) and
      overlaps?(
        Edicts.vector(server, other, "absmin"),
        Edicts.vector(server, other, "absmax"),
        low,
        high
      )
  end

  defp collides?(1, skin), do: skin < 0
  defp collides?(solid, _skin), do: solid in [2, 3, 4, 20]

  defp overlaps?({ax0, ay0, az0}, {ax1, ay1, az1}, {bx0, by0, bz0}, {bx1, by1, bz1}),
    do: not (ax0 > bx1 or ay0 > by1 or az0 > bz1 or ax1 < bx0 or ay1 < by0 or az1 < bz0)

  defp physent(server, player, other) do
    {size_x, _, _} = Edicts.vector(server, other, "size")

    cond do
      (dimension(server, player, "dimension_hit") &&& dimension(server, other, "dimension_solid")) ==
          0 ->
        []

      size_x == 0 ->
        []

      true ->
        [build_physent(server, player, other)]
    end
  end

  defp build_physent(server, player, other) do
    solid = Edicts.int(server, other, "solid")
    code = contents_code(solid, Edicts.int(server, other, "skin"))
    {model, mins, maxs, angles} = shape(server, other, solid)

    %Physent{
      entity: other,
      origin: Edicts.vector(server, other, "origin"),
      angles: angles,
      model: model,
      mins: mins,
      maxs: maxs,
      nonsolid: nonsolid?(code, solid),
      notouch:
        (dimension(server, player, "dimension_solid") &&&
           dimension(server, other, "dimension_hit")) == 0,
      contents: Contents.forced(code)
    }
  end

  defp dimension(server, entity, name) do
    if QuakeC.field_offset(server.qc, name) == nil,
      do: @dimension_default,
      else: Edicts.int(server, entity, name)
  end

  defp contents_code(20, _skin), do: -16
  defp contents_code(5, _skin), do: -19
  defp contents_code(_solid, skin), do: skin

  defp nonsolid?(code, _solid) when code in [-2, -8, -18], do: false
  defp nonsolid?(code, _solid) when code in -19..-1//1 and code != -7, do: true
  defp nonsolid?(_code, solid), do: solid == 1

  defp shape(server, other, 4) do
    case Models.get(server, Edicts.int(server, other, "modelindex")) do
      %{kind: :brush, hulls: [_ | _]} = model ->
        {model, @zero, @zero, Edicts.vector(server, other, "angles")}

      _other ->
        box_shape(server, other)
    end
  end

  defp shape(server, other, _solid), do: box_shape(server, other)

  defp box_shape(server, other) do
    {nil, Edicts.vector(server, other, "mins"), Edicts.vector(server, other, "maxs"), @zero}
  end

  defp store(server, entity, pm) do
    flags = Edicts.int(server, entity, "flags")

    server
    |> Edicts.put(entity, "pmove_flags", pmove_flags(pm) / 1)
    |> Edicts.put(entity, "teleport_time", server.time + pm.waterjumptime)
    |> Edicts.put(entity, "origin", pm.origin)
    |> Edicts.put(entity, "oldorigin", pm.safeorigin)
    |> Edicts.put(entity, "velocity", pm.velocity)
    |> Edicts.put(entity, "v_angle", Vec.float(pm.angles))
    |> Edicts.put(entity, "waterlevel", pm.waterlevel / 1)
    |> Edicts.put(entity, "watertype", water_code(pm.watertype) / 1)
    |> store_ground(entity, flags, pm)
    |> World.link(entity, true)
  end

  defp pmove_flags(pm) do
    if(pm.jump_held, do: @jump_held, else: 0) + if(pm.onladder, do: @on_ladder, else: 0)
  end

  defp water_code(bits) do
    cond do
      Contents.has?(bits, :solid) -> -2
      Contents.has?(bits, :sky) -> -6
      Contents.has?(bits, :lava) -> -5
      Contents.has?(bits, :slime) -> -4
      Contents.has?(bits, :water) -> -3
      true -> -1
    end
  end

  defp store_ground(server, entity, flags, %Pmove{onground: true} = pm) do
    server
    |> Edicts.put(entity, "flags", (flags ||| @onground) / 1)
    |> Edicts.put(entity, "groundentity", elem(pm.physents, pm.groundent).entity)
  end

  defp store_ground(server, entity, flags, _pm),
    do: Edicts.put(server, entity, "flags", (flags &&& bnot(@onground)) / 1)

  defp touch_all(server, entity, pm, touched) do
    pm.touched
    |> Enum.reverse()
    |> Enum.map(&elem(pm.physents, &1))
    |> Enum.reject(& &1.notouch)
    |> Enum.reduce({server, touched}, fn physent, acc -> touch(acc, physent.entity, entity) end)
  end

  defp touch({server, touched}, other, entity) do
    function = Edicts.int(server, other, "touch")

    if function == 0 or MapSet.member?(touched, other) do
      {server, touched}
    else
      self = QuakeC.global(server.qc, "self")
      prior = QuakeC.global(server.qc, "other")

      server =
        server
        |> Server.run(function, other, entity)
        |> restore(self, prior)

      {server, MapSet.put(touched, other)}
    end
  end

  defp restore(server, self, other) do
    qc =
      server.qc
      |> QuakeC.put_global("self", self)
      |> QuakeC.put_global("other", other)

    %{server | qc: qc}
  end
end
