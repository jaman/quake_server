defmodule QuakeServer.Pmove do
  @moduledoc """
  FTE's QuakeWorld player movement (`PM_PlayerMove`): one command of a player's input
  moving a box through the world and the entities near it.

      pm = QuakeServer.Pmove.player_move(pm)

  The caller fills a `QuakeServer.Pmove` with the player's state, the command
  (`QuakeServer.Pmove.Command`), the movement settings (`QuakeServer.Pmove.Movevars`)
  and the things it can meet (`physents`, a tuple of `QuakeServer.Pmove.Physent`, the
  world first), and reads the state back.

    * `pm_type` — `:normal`, `:dead` (no acceleration, no jumping), `:fly` (flying,
      bumping into walls), `:none` and `:freeze` (no movement), `:spectator` and
      `:old_spectator` (flying through everything; the old one stops moving while at
      speed), `:wallwalk` (the wall under the player is the ground) or `:six_dof`
    * `gravitydir` — the way down; a zero vector is taken as `{0, 0, -1}`
    * `onground`, `groundent` (an index into `physents`) and `groundplane` (its normal) —
      what the player stands on
    * `waterlevel` 0 to 3 and `watertype`, the contents bits (`QuakeServer.Contents`) at
      the player's feet
    * `onladder` — set on reaching a ladder; only the caller clears it
    * `jump_held`, `jump_msec`, `waterjumptime` — the jump button's state and the seconds
      left of a jump out of water
    * `safeorigin` — the last spot the player was found to fit, where a stuck player is
      returned when `safeorigin_known`
    * `touched` — indexes into `physents` of what the move ran into, newest first
  """

  import Bitwise

  alias Cauldron3D.{Hull, Vec}
  alias Cauldron3D.Hull.Trace
  alias QuakeServer.{Angles, Contents, World}

  defmodule Physent do
    @moduledoc """
    Something the player can collide with or stand in: entity number `entity` at
    `origin`, either a brush model (`model`, as `QuakeServer.Models.get/2` gives it,
    turned by `angles`) or, with `model` `nil`, a box of `mins`..`maxs`.

    `nonsolid` ones only add contents. `contents` are the bits it forces on what it
    holds, 0 for its own. `notouch` ones are not touched.
    """

    @enforce_keys [:entity, :origin]
    defstruct entity: 0,
              origin: {0.0, 0.0, 0.0},
              angles: {0.0, 0.0, 0.0},
              model: nil,
              mins: {0.0, 0.0, 0.0},
              maxs: {0.0, 0.0, 0.0},
              nonsolid: false,
              notouch: false,
              contents: 0

    @type t :: %__MODULE__{
            entity: non_neg_integer(),
            origin: Cauldron3D.Vec.t(),
            angles: Cauldron3D.Vec.t(),
            model: map() | nil,
            mins: Cauldron3D.Vec.t(),
            maxs: Cauldron3D.Vec.t(),
            nonsolid: boolean(),
            notouch: boolean(),
            contents: non_neg_integer()
          }
  end

  defmodule Command do
    @moduledoc """
    One command: `angles` as signed 16-bit numbers (360 degrees is 65536), the
    `forward`, `side` and `up` moves, the `buttons` bits (2 is jump) and its length
    `msec` in milliseconds.
    """

    defstruct angles: {0, 0, 0}, forward: 0, side: 0, up: 0, buttons: 0, msec: 0.0

    @type t :: %__MODULE__{
            angles: {integer(), integer(), integer()},
            forward: integer(),
            side: integer(),
            up: integer(),
            buttons: integer(),
            msec: float()
          }
  end

  defmodule Movevars do
    @moduledoc """
    The movement settings. `entgravity` scales `gravity` for the player; `edge_box`
    tests for ledges with the player's box instead of a line; `coordtype` is `:float`,
    or `:fixed_13_3` for positions snapped to eighths before testing where the player
    fits, unless `noround`.
    """

    defstruct gravity: 800.0,
              stopspeed: 100.0,
              maxspeed: 320.0,
              spectatormaxspeed: 500.0,
              accelerate: 10.0,
              wateraccelerate: 10.0,
              friction: 4.0,
              waterfriction: 4.0,
              flyfriction: 4.0,
              entgravity: 1.0,
              bunnyspeedcap: 0.0,
              watersinkspeed: 60.0,
              ktjump: 0.0,
              edgefriction: 2.0,
              edge_box: true,
              walljump: 0,
              slidefix: false,
              airstep: false,
              pground: false,
              stepdown: false,
              slidyslopes: false,
              autobunny: false,
              bunnyfriction: false,
              stepheight: 18,
              coordtype: :float,
              noround: false

    @type t :: %__MODULE__{}
  end

  @min_step_normal 0.7
  @blocked_floor 1
  @blocked_step 2
  @blocked_other 4
  @max_clip_planes 5
  @max_physents 2048
  @jumpspeed 270.0
  @maxairspeed 30.0
  @viewheight 22
  @signs [0.0, -0.125, 0.125]
  @player_solid 0x00000001 ||| 0x00010000 ||| 0x00000002 ||| 0x02000000
  @zero {0.0, 0.0, 0.0}

  @enforce_keys [:server, :physents, :movevars, :cmd, :pm_type, :origin, :velocity, :mins, :maxs]
  defstruct server: nil,
            physents: {},
            movevars: nil,
            cmd: nil,
            pm_type: :normal,
            origin: @zero,
            velocity: @zero,
            mins: @zero,
            maxs: @zero,
            angles: @zero,
            gravitydir: @zero,
            safeorigin: @zero,
            safeorigin_known: false,
            jump_held: false,
            jump_msec: 0,
            waterjumptime: 0.0,
            onground: false,
            groundent: 0,
            groundplane: @zero,
            waterlevel: 0,
            watertype: 0,
            onladder: false,
            touched: [],
            frametime: 0.0,
            forward: @zero,
            right: @zero,
            up: @zero

  @type pm_type ::
          :normal
          | :old_spectator
          | :spectator
          | :dead
          | :fly
          | :none
          | :freeze
          | :wallwalk
          | :six_dof

  @type t :: %__MODULE__{
          server: QuakeServer.Server.t(),
          physents: tuple(),
          movevars: Movevars.t(),
          cmd: Command.t(),
          pm_type: pm_type(),
          origin: Vec.t(),
          velocity: Vec.t(),
          mins: Vec.t(),
          maxs: Vec.t(),
          angles: Vec.t(),
          gravitydir: Vec.t(),
          safeorigin: Vec.t(),
          safeorigin_known: boolean(),
          jump_held: boolean(),
          jump_msec: integer(),
          waterjumptime: float(),
          onground: boolean(),
          groundent: non_neg_integer() | nil,
          groundplane: Vec.t(),
          waterlevel: 0..3,
          watertype: non_neg_integer(),
          onladder: boolean(),
          touched: [non_neg_integer()],
          frametime: float(),
          forward: Vec.t(),
          right: Vec.t(),
          up: Vec.t()
        }

  @doc "Move the player for its command (`PM_PlayerMove`); `touched` starts empty."
  @spec player_move(t()) :: t()
  def player_move(%__MODULE__{} = pm) do
    move_by_type(%{pm | frametime: pm.cmd.msec * 0.001, touched: []})
  end

  defp move_by_type(%{pm_type: type} = pm) when type in [:none, :freeze], do: categorize(pm)

  defp move_by_type(pm) do
    angles = short_angles(pm.cmd.angles)
    {forward, right, up} = Angles.vectors(angles)
    steer(%{pm | angles: angles, forward: forward, right: right, up: up})
  end

  defp short_angles({pitch, yaw, roll}),
    do: {pitch * (360.0 / 65536), yaw * (360.0 / 65536), roll * (360.0 / 65536)}

  defp steer(%{pm_type: type} = pm) when type in [:spectator, :old_spectator],
    do: %{spectator_move(pm) | onground: false}

  defp steer(pm) do
    pm
    |> nudge_position()
    |> categorize()
    |> release_for_autobunny()
    |> check_water_jump()
    |> end_water_jump()
    |> count_down_water_jump()
    |> count_jump_msec()
    |> qw_jump()
    |> friction()
    |> move_through_medium()
    |> nq_jump()
    |> categorize()
    |> clip_landing()
  end

  defp release_for_autobunny(%{movevars: %{autobunny: true}, onground: false} = pm),
    do: %{pm | jump_held: false}

  defp release_for_autobunny(pm), do: pm

  defp check_water_jump(%{waterlevel: 2, pm_type: type} = pm) when type != :fly,
    do: water_jump(pm)

  defp check_water_jump(pm), do: pm

  defp end_water_jump(pm) do
    if up_speed(pm, pm.velocity) < 0 or pm.pm_type == :dead,
      do: %{pm | waterjumptime: 0.0},
      else: pm
  end

  defp count_down_water_jump(%{waterjumptime: time} = pm) when time != 0,
    do: %{pm | waterjumptime: max(time - pm.frametime, 0.0)}

  defp count_down_water_jump(pm), do: pm

  defp count_jump_msec(%{jump_msec: 0} = pm), do: pm

  defp count_jump_msec(pm) do
    msec = trunc(pm.jump_msec + pm.cmd.msec)
    %{pm | jump_msec: if(msec > 50, do: 0, else: msec)}
  end

  defp qw_jump(%{movevars: %{bunnyfriction: true}} = pm), do: pm
  defp qw_jump(pm), do: check_jump(pm)

  defp nq_jump(%{movevars: %{bunnyfriction: true}} = pm), do: check_jump(pm)
  defp nq_jump(pm), do: pm

  defp clip_landing(pm) do
    if not pm.movevars.pground and pm.onground and up_speed(pm, pm.velocity) < -300 and
         Vec.dot(pm.velocity, pm.groundplane) < -0.1,
       do: %{pm | velocity: clip_velocity(pm.velocity, pm.groundplane, 1)},
       else: pm
  end

  defp up_speed(pm, vector), do: -Vec.dot(pm.gravitydir, vector)

  defp flatten(vector, down), do: Vec.madd(vector, down, -Vec.dot(vector, down))

  defp steep?(pm, normal), do: up_speed(pm, normal) < @min_step_normal

  defp jump?(cmd), do: (cmd.buttons &&& 2) != 0

  defp wish(forward, right, cmd),
    do: forward |> Vec.scale(cmd.forward) |> Vec.madd(right, cmd.side)

  defp flat_forward(%{forward: {x, y, _}}), do: Vec.normalize({x, y, 0.0})

  defp fall(pm) do
    gravity = pm.movevars.entgravity * pm.movevars.gravity * pm.frametime
    %{pm | velocity: Vec.madd(pm.velocity, pm.gravitydir, gravity)}
  end

  defp clip_velocity({vx, vy, vz} = velocity, {nx, ny, nz} = normal, overbounce) do
    backoff = Vec.dot(velocity, normal) * overbounce
    {stop_small(vx - nx * backoff), stop_small(vy - ny * backoff), stop_small(vz - nz * backoff)}
  end

  defp stop_small(value) when value > -0.1 and value < 0.1, do: 0.0
  defp stop_small(value), do: value

  defp add_touched(%{touched: touched} = pm, _index) when length(touched) >= @max_physents,
    do: pm

  defp add_touched(%{touched: [index | _]} = pm, index), do: pm
  defp add_touched(pm, index), do: %{pm | touched: [index | pm.touched]}

  defp categorize(pm) do
    pm = pm |> default_gravity() |> wall_gravity()
    {pm, trace} = find_ground(pm)
    pm |> water_level() |> ladder() |> snap_to_ground(trace)
  end

  defp default_gravity(%{gravitydir: {x, y, z}} = pm) when x == 0 and y == 0 and z == 0,
    do: %{pm | gravitydir: {0.0, 0.0, -1.0}}

  defp default_gravity(pm), do: pm

  defp wall_gravity(%{pm_type: :wallwalk} = pm) do
    below = Vec.madd(pm.origin, pm.up, -48.0)

    probes = [
      fn -> trace_line(pm, pm.origin, Vec.madd(below, pm.forward, 48.0)) end,
      fn -> trace_line(pm, pm.origin, below) end,
      fn ->
        beyond = Vec.madd(below, pm.forward, 48.0)
        trace_line(pm, beyond, Vec.madd(beyond, pm.forward, 48.0))
      end,
      fn -> trace_line(pm, pm.origin, Vec.madd(below, pm.forward, -48.0)) end
    ]

    case Enum.find_value(probes, &short(&1.())) do
      nil -> pm
      trace -> %{pm | gravitydir: Vec.scale(trace.normal, -1.0)}
    end
  end

  defp wall_gravity(pm), do: pm

  defp short(%Trace{fraction: fraction} = trace) when fraction < 1, do: trace
  defp short(_trace), do: nil

  defp find_ground(pm) do
    unknown = %Trace{start_solid: true, all_solid: true, end_pos: @zero}

    cond do
      up_speed(pm, pm.velocity) > 180 -> {%{pm | onground: false}, unknown}
      not pm.movevars.pground or pm.onground -> stand(pm)
      true -> {pm, unknown}
    end
  end

  defp stand(pm) do
    point = Vec.add(pm.origin, pm.gravitydir)
    trace = pm |> trace(pm.origin, point) |> slide_off_slope(pm)
    {pm |> ground_from(trace) |> touch_ground(trace), trace}
  end

  defp slide_off_slope(trace, pm) do
    if not trace.start_solid and trace.fraction < 1 and steep?(pm, trace.normal) do
      bounce = clip_velocity(pm.gravitydir, trace.normal, 2)
      trace(pm, trace.end_pos, Vec.madd(trace.end_pos, bounce, 1 - trace.fraction))
    else
      trace
    end
  end

  defp ground_from(pm, trace) do
    if not trace.start_solid and (trace.fraction == 1 or steep?(pm, trace.normal)) do
      %{pm | onground: false}
    else
      %{
        pm
        | onground: not trace.start_solid,
          groundent: trace.hit,
          groundplane: trace.normal,
          waterjumptime: 0.0
      }
    end
  end

  defp touch_ground(pm, %Trace{hit: hit}) when is_integer(hit) and hit > 0,
    do: add_touched(pm, hit)

  defp touch_ground(pm, _trace), do: pm

  defp water_level(pm) do
    {x, y, z} = pm.origin
    {_, _, low} = pm.mins
    {_, _, high} = pm.maxs
    feet = point_contents(pm, {x, y, z + low + 1})

    if Contents.fluid?(feet) do
      level =
        cond do
          not Contents.fluid?(point_contents(pm, {x, y, z + (low + high) * 0.5})) -> 1
          not Contents.fluid?(point_contents(pm, {x, y, z + low + 24 + @viewheight})) -> 2
          true -> 3
        end

      %{pm | waterlevel: level, watertype: feet}
    else
      %{pm | waterlevel: 0, watertype: 0}
    end
  end

  defp ladder(pm) do
    if Contents.has?(extra_box_contents(pm, pm.origin), :ladder) and wall_ahead?(pm),
      do: %{pm | onladder: true, onground: false},
      else: pm
  end

  defp wall_ahead?(pm) do
    ahead = Vec.madd(pm.origin, flat_forward(pm), 24.0)
    trace(pm, pm.origin, ahead).fraction < 1
  end

  defp snap_to_ground(pm, trace) do
    if not pm.movevars.pground and pm.onground and pm.pm_type != :fly and pm.waterlevel < 2 and
         not trace.start_solid and not trace.all_solid,
       do: %{pm | origin: trace.end_pos},
       else: pm
  end

  defp check_jump(%{pm_type: :fly} = pm), do: pm
  defp check_jump(%{pm_type: :dead} = pm), do: %{pm | jump_held: true}

  defp check_jump(pm) do
    cond do
      not jump?(pm.cmd) -> %{pm | jump_held: false}
      pm.waterjumptime != 0 -> pm
      pm.waterlevel >= 2 -> swim_up(pm)
      not pm.onground -> pm
      pm.jump_held and pm.jump_msec == 0 -> pm
      true -> jump(pm)
    end
  end

  defp swim_up(pm) do
    speed =
      cond do
        pm.watertype == Contents.bit(:water) -> 100.0
        pm.watertype == Contents.bit(:slime) -> 80.0
        true -> 50.0
      end

    rise = -speed - Vec.dot(pm.velocity, pm.gravitydir)
    %{pm | onground: false, velocity: Vec.madd(pm.velocity, pm.gravitydir, rise)}
  end

  defp jump(pm) do
    velocity =
      if not pm.movevars.pground and up_speed(pm, pm.velocity) < 0 and
           Vec.dot(pm.velocity, pm.groundplane) < -0.1,
         do: clip_velocity(pm.velocity, pm.groundplane, 1),
         else: pm.velocity

    velocity = velocity |> Vec.madd(pm.gravitydir, -@jumpspeed) |> kt_jump(pm)

    %{
      pm
      | onground: false,
        velocity: velocity,
        jump_held: true,
        jump_msec: trunc(pm.cmd.msec)
    }
  end

  defp kt_jump({vx, vy, vz} = velocity, %{movevars: %{ktjump: kt}, pm_type: type})
       when kt > 0 and type != :wallwalk do
    kt = min(kt, 1.0)
    if vz < @jumpspeed, do: {vx, vy, vz * (1 - kt) + @jumpspeed * kt}, else: velocity
  end

  defp kt_jump(velocity, _pm), do: velocity

  defp water_jump(%{waterjumptime: time} = pm) when time > 0, do: pm
  defp water_jump(%{pm_type: :dead} = pm), do: pm
  defp water_jump(%{velocity: {_, _, vz}} = pm) when vz < -180, do: pm

  defp water_jump(pm) do
    flat = flat_forward(pm)
    {x, y, z} = pm.origin
    {_, _, low} = pm.mins
    spot = {x, y, z + (8 + 24 + low)}

    with {:blocked, waist} <- waist_wall(pm, spot, flat),
         false <- wall?(pm, lift(waist, 24), flat) do
      {jx, jy, _} = Vec.scale(flat, 50.0)
      %{pm | velocity: {jx, jy, 310.0}, waterjumptime: 2.0, jump_held: true}
    else
      _open -> pm
    end
  end

  defp waist_wall(pm, spot, flat) do
    cond do
      wall?(pm, spot, flat) -> {:blocked, spot}
      wall?(pm, lift(spot, 2), flat) -> {:blocked, lift(spot, 2)}
      true -> :open
    end
  end

  defp wall?(pm, spot, flat), do: trace_line(pm, spot, Vec.madd(spot, flat, 24.0)).fraction < 1

  defp lift({x, y, z}, height), do: {x, y, z + height}

  defp nudge_position(pm) do
    base = pm.origin
    nudged = rounded(base, pm.movevars)
    spots = nudges(base, nudged, pm.movevars.stepheight)

    case Enum.find(spots, &fits?(pm, &1)) do
      nil -> stuck(pm, base, List.last(spots))
      spot -> %{pm | origin: spot, safeorigin: spot, safeorigin_known: true}
    end
  end

  defp stuck(pm, base, last) do
    if pm.safeorigin_known and fits?(pm, pm.safeorigin),
      do: %{pm | origin: last, safeorigin: last},
      else: %{pm | origin: base}
  end

  defp rounded(base, %Movevars{noround: true}), do: base
  defp rounded(base, %Movevars{coordtype: :float}), do: base

  defp rounded({x, y, z}, %Movevars{coordtype: :fixed_13_3}),
    do: {eighth(x), eighth(y), eighth(z)}

  defp rounded({x, y, z}, _movevars),
    do: {trunc(x * 8) * 0.125, trunc(y * 8) * 0.125, trunc(z * 8) * 0.125}

  defp eighth(value) when value >= 0, do: trunc(value * 8 + 0.5) / 8.0
  defp eighth(value), do: trunc(value * 8 - 0.5) / 8.0

  defp nudges(base, {nx, ny, nz} = nudged, stepheight) do
    around = for dz <- @signs, dx <- @signs, dy <- @signs, do: {nx + dx, ny + dy, nz + dz}

    axial =
      for axis <- 0..2,
          shift <- [0.25, -0.25],
          do: put_elem(base, axis, elem(nudged, axis) + shift)

    upward =
      for dz <- 1..(stepheight - 1)//1,
          dx <- @signs,
          dy <- @signs,
          do: {nx + dx, ny + dy, nz + dz}

    around ++ axial ++ upward
  end

  defp fits?(pm, position),
    do: pm.physents |> Tuple.to_list() |> Enum.all?(&clear_of?(pm, &1, position))

  defp clear_of?(_pm, %Physent{nonsolid: true}, _position), do: true

  defp clear_of?(_pm, %Physent{contents: contents}, _position)
       when contents != 0 and (contents &&& @player_solid) == 0,
       do: true

  defp clear_of?(pm, %Physent{model: nil} = physent, position) do
    hull = Hull.box(Vec.sub(physent.mins, pm.maxs), Vec.sub(physent.maxs, pm.mins))
    contents = Contents.of_code(Hull.contents(hull, Vec.sub(position, physent.origin)))
    (contents &&& @player_solid) == 0
  end

  defp clear_of?(pm, physent, position) do
    case model_trace(pm, physent, position, position, pm.mins, pm.maxs) do
      nil -> true
      trace -> not trace.all_solid
    end
  end

  defp friction(%{waterjumptime: time} = pm) when time != 0, do: pm

  defp friction(pm) do
    speed = Vec.length(pm.velocity)
    if speed < 1, do: halt(pm), else: slow(pm, speed, drop(pm, speed))
  end

  defp halt(%{velocity: {_, _, vz}, pm_type: type} = pm) do
    vz = if type in [:fly, :six_dof], do: 0.0, else: vz
    %{pm | velocity: {0.0, 0.0, vz}}
  end

  defp drop(%{waterlevel: level} = pm, speed) when level >= 2,
    do: speed * pm.movevars.waterfriction * level * pm.frametime

  defp drop(%{pm_type: type} = pm, speed) when type in [:fly, :six_dof],
    do: speed * pm.movevars.flyfriction * pm.frametime

  defp drop(%{onground: true} = pm, speed),
    do: control(pm, speed) * ground_friction(pm, speed) * pm.frametime

  defp drop(%{onladder: true} = pm, speed),
    do: control(pm, speed) * pm.movevars.friction * pm.frametime * 6

  defp drop(_pm, _speed), do: nil

  defp control(pm, speed),
    do: if(speed < pm.movevars.stopspeed, do: pm.movevars.stopspeed, else: speed)

  defp slow(pm, _speed, nil), do: pm

  defp slow(pm, speed, drop),
    do: %{pm | velocity: Vec.scale(pm.velocity, max(speed - drop, 0.0) / speed)}

  defp ground_friction(%{movevars: %{edgefriction: edge, friction: friction}}, _speed)
       when edge == 1.0,
       do: friction

  defp ground_friction(pm, speed) do
    {x, y, z} = pm.origin
    {vx, vy, _} = pm.velocity
    {_, _, low} = pm.mins
    start = {x + vx / speed * 16, y + vy / speed * 16, z + low}
    {sx, sy, sz} = start
    stop = {sx, sy, sz - 34}

    trace =
      if pm.movevars.edge_box,
        do: trace(pm, start, stop),
        else: trace_line(pm, start, stop)

    if trace.fraction == 1 and not trace.start_solid,
      do: pm.movevars.friction * pm.movevars.edgefriction,
      else: pm.movevars.friction
  end

  defp accelerate(%{pm_type: :dead} = pm, _wishdir, _wishspeed, _accel), do: pm

  defp accelerate(%{waterjumptime: time} = pm, _wishdir, _wishspeed, _accel) when time != 0,
    do: pm

  defp accelerate(pm, wishdir, wishspeed, accel) do
    add = wishspeed - Vec.dot(pm.velocity, wishdir)

    if add <= 0,
      do: pm,
      else: %{
        pm
        | velocity: Vec.madd(pm.velocity, wishdir, min(accel * pm.frametime * wishspeed, add))
      }
  end

  defp air_accelerate(%{pm_type: :dead} = pm, _wishdir, _wishspeed, _accel), do: pm

  defp air_accelerate(%{waterjumptime: time} = pm, _wishdir, _wishspeed, _accel)
       when time != 0,
       do: pm

  defp air_accelerate(pm, wishdir, wishspeed, accel) do
    add = min(wishspeed, @maxairspeed) - Vec.dot(pm.velocity, wishdir)

    if add <= 0 do
      pm
    else
      original = flat_speed(pm.velocity)
      velocity = Vec.madd(pm.velocity, wishdir, min(accel * wishspeed * pm.frametime, add))
      %{pm | velocity: cap_bunny(velocity, original, pm.movevars)}
    end
  end

  defp flat_speed({vx, vy, _}), do: :math.sqrt(vx * vx + vy * vy)

  defp cap_bunny(velocity, _original, %Movevars{bunnyspeedcap: cap}) when cap <= 0, do: velocity

  defp cap_bunny({vx, vy, vz} = velocity, original, movevars) do
    newspeed = flat_speed(velocity)
    speedcap = movevars.maxspeed * movevars.bunnyspeedcap

    if newspeed > original and newspeed > speedcap do
      original = max(original, speedcap)
      {vx * (original / newspeed), vy * (original / newspeed), vz}
    else
      velocity
    end
  end

  defp move_through_medium(%{waterlevel: level} = pm) when level >= 2, do: water_move(pm)
  defp move_through_medium(%{pm_type: type} = pm) when type in [:fly, :six_dof], do: fly_move(pm)
  defp move_through_medium(%{onladder: true} = pm), do: ladder_move(pm)
  defp move_through_medium(pm), do: air_move(pm)

  defp water_move(pm) do
    %{cmd: cmd, movevars: movevars} = pm
    wishvel = wish(pm.forward, pm.right, cmd)

    wishvel =
      if pm.pm_type != :fly and cmd.forward == 0 and cmd.side == 0 and cmd.up == 0 and
           not pm.onladder,
         do: Vec.madd(wishvel, pm.gravitydir, movevars.watersinkspeed),
         else: Vec.madd(wishvel, pm.gravitydir, -cmd.up)

    wishspeed = min(Vec.length(wishvel), movevars.maxspeed) * 0.7

    pm
    |> accelerate(Vec.normalize(wishvel), wishspeed, movevars.wateraccelerate)
    |> step_slide_move(false)
    |> elem(0)
  end

  defp fly_move(pm) do
    wishvel = fly_wish(pm)

    pm
    |> accelerate(
      Vec.normalize(wishvel),
      min(Vec.length(wishvel), pm.movevars.maxspeed),
      pm.movevars.accelerate
    )
    |> step_slide_move(false)
    |> elem(0)
  end

  defp fly_wish(%{pm_type: :six_dof} = pm),
    do: pm.forward |> wish(pm.right, pm.cmd) |> Vec.madd(pm.up, pm.cmd.up)

  defp fly_wish(pm),
    do: pm.forward |> wish(pm.right, pm.cmd) |> Vec.madd(pm.gravitydir, -pm.cmd.up)

  defp ladder_move(pm) do
    %{cmd: cmd, movevars: movevars} = pm
    {wx, wy, wz} = pm.forward |> wish(pm.right, cmd) |> Vec.madd(pm.up, cmd.up)
    wz = if wz >= 100 or wz <= -100, do: wz * 10, else: wz

    wishvel =
      if jump?(cmd),
        do: Vec.madd({wx, wy, wz}, pm.gravitydir, -movevars.maxspeed),
        else: {wx, wy, wz}

    pm =
      accelerate(
        pm,
        Vec.normalize(wishvel),
        min(Vec.length(wishvel), movevars.maxspeed),
        movevars.wateraccelerate
      )

    dest = Vec.madd(pm.origin, pm.velocity, pm.frametime)
    start = Vec.madd(dest, pm.gravitydir, -(movevars.stepheight + 1))
    trace = trace(pm, start, dest)

    if not trace.start_solid and not trace.all_solid,
      do: %{pm | origin: trace.end_pos},
      else: fly_move(pm)
  end

  defp air_move(pm) do
    pm = level_axes(pm)
    move = pm.forward |> wish(pm.right, pm.cmd) |> flatten(pm.gravitydir)
    wishdir = Vec.normalize(move)
    wishspeed = min(Vec.length(move), pm.movevars.maxspeed)

    if pm.onground,
      do: ground_move(pm, wishdir, wishspeed),
      else: airborne_move(pm, wishdir, wishspeed)
  end

  defp level_axes(pm) do
    {forward, right, up} = steady_axes(pm)

    %{
      pm
      | forward: forward |> flatten(pm.gravitydir) |> Vec.normalize(),
        right: right |> flatten(pm.gravitydir) |> Vec.normalize(),
        up: up
    }
  end

  defp steady_axes(%{gravitydir: {_, _, down}, angles: {pitch, yaw, roll}})
       when down == -1 and (pitch == 90 or pitch == -90),
       do: Angles.vectors({pitch * 0.99, yaw, roll})

  defp steady_axes(pm), do: {pm.forward, pm.right, pm.up}

  defp ground_move(pm, wishdir, wishspeed) do
    movevars = pm.movevars
    pm = ground_accelerate(pm, wishdir, wishspeed)
    horizontal = flatten(pm.velocity, pm.gravitydir)

    if Vec.dot(horizontal, horizontal) == 0 and not movevars.slidyslopes do
      %{pm | velocity: @zero}
    else
      pm |> level_unless_sliding() |> step_slide_move(false) |> elem(0)
    end
  end

  defp ground_accelerate(%{movevars: %Movevars{slidefix: true} = movevars} = pm, wishdir, speed) do
    pm
    |> lift_off_ramp()
    |> accelerate(wishdir, speed, movevars.accelerate)
    |> fall()
  end

  defp ground_accelerate(pm, wishdir, speed) do
    %{pm | velocity: flatten(pm.velocity, pm.gravitydir)}
    |> accelerate(wishdir, speed, pm.movevars.accelerate)
  end

  defp lift_off_ramp(pm) do
    if Vec.dot(pm.velocity, pm.gravitydir) < 0,
      do: %{pm | velocity: flatten(pm.velocity, pm.gravitydir)},
      else: pm
  end

  defp level_unless_sliding(%{movevars: %{slidefix: false, slidyslopes: false}} = pm),
    do: %{pm | velocity: flatten(pm.velocity, pm.gravitydir)}

  defp level_unless_sliding(pm), do: pm

  defp airborne_move(pm, wishdir, wishspeed) do
    {pm, blocked} =
      pm
      |> air_accelerate(wishdir, wishspeed, pm.movevars.accelerate)
      |> fall()
      |> airborne_slide()

    if pm.movevars.pground and (blocked &&& @blocked_floor) != 0,
      do: %{pm | onground: true},
      else: pm
  end

  defp airborne_slide(pm) do
    cond do
      Vec.dot(pm.velocity, pm.velocity) > 1000 * 1000 -> step_slide_move(pm, false)
      pm.movevars.airstep -> step_slide_move(pm, true)
      true -> slide_move(pm)
    end
  end

  defp spectator_move(pm) do
    pm = spectator_friction(pm)
    forward = Vec.normalize(pm.forward)
    right = Vec.normalize(pm.right)
    {wx, wy, wz} = wish(forward, right, pm.cmd)
    wishvel = {wx, wy, wz + pm.cmd.up}
    wishdir = Vec.normalize(wishvel)
    wishspeed = min(Vec.length(wishvel), pm.movevars.spectatormaxspeed)
    add = wishspeed - Vec.dot(pm.velocity, wishdir)
    spectator_push(%{pm | forward: forward, right: right}, wishdir, wishspeed, add)
  end

  defp spectator_friction(pm) do
    speed = Vec.length(pm.velocity)

    if speed < 1 do
      %{pm | velocity: @zero}
    else
      friction = pm.movevars.friction * 1.5
      drop = control(pm, speed) * friction * pm.frametime
      %{pm | velocity: Vec.scale(pm.velocity, max(speed - drop, 0.0) / speed)}
    end
  end

  defp spectator_push(%{pm_type: :old_spectator} = pm, _wishdir, _wishspeed, add) when add <= 0,
    do: pm

  defp spectator_push(pm, wishdir, wishspeed, add) do
    velocity =
      if add > 0,
        do:
          Vec.madd(
            pm.velocity,
            wishdir,
            min(pm.movevars.accelerate * pm.frametime * wishspeed, add)
          ),
        else: pm.velocity

    %{pm | velocity: velocity, origin: Vec.madd(pm.origin, velocity, pm.frametime)}
  end

  defp slide_move(pm) do
    slide(pm, %{
      bump: 0,
      planes: [],
      primal: pm.velocity,
      original: pm.velocity,
      time_left: pm.frametime,
      blocked: 0
    })
  end

  defp slide(pm, %{bump: 4} = slide), do: finish_slide(pm, slide)

  defp slide(pm, slide) do
    trace = trace(pm, pm.origin, Vec.madd(pm.origin, pm.velocity, slide.time_left))

    if trace.start_solid or trace.all_solid do
      {%{pm | velocity: @zero}, 3}
    else
      {pm, slide} =
        if trace.fraction > 0,
          do: {%{pm | origin: trace.end_pos}, %{slide | planes: []}},
          else: {pm, slide}

      if trace.fraction == 1,
        do: finish_slide(pm, slide),
        else: impact(add_touched(pm, trace.hit), slide, trace)
    end
  end

  defp impact(pm, slide, trace) do
    slide = %{
      slide
      | blocked: slide.blocked ||| blocked_by(trace.normal),
        time_left: slide.time_left - slide.time_left * trace.fraction
    }

    if length(slide.planes) >= @max_clip_planes,
      do: finish_slide(%{pm | velocity: @zero}, slide),
      else: redirect(pm, %{slide | planes: slide.planes ++ [trace.normal]})
  end

  defp blocked_by({_, _, z}) when z >= @min_step_normal, do: @blocked_floor
  defp blocked_by({_, _, z}) when z == 0, do: @blocked_step
  defp blocked_by(_normal), do: @blocked_other

  defp redirect(pm, slide) do
    case along_planes(pm, slide) do
      {:bounced, pm} -> {pm, slide.blocked}
      {:along, pm} -> continue_slide(pm, slide)
      {:crease, pm} -> crease(pm, slide)
    end
  end

  defp along_planes(pm, slide) do
    indexed = Enum.with_index(slide.planes)

    Enum.reduce_while(indexed, {:crease, pm}, fn {plane, index}, {_, pm} ->
      case off_plane(pm, slide, plane) do
        {:bounced, pm} ->
          {:halt, {:bounced, pm}}

        {:clipped, pm} ->
          if clear_of_others?(pm.velocity, indexed, index),
            do: {:halt, {:along, pm}},
            else: {:cont, {:crease, pm}}
      end
    end)
  end

  defp off_plane(%{movevars: %{walljump: 2}} = pm, slide, plane),
    do: {:bounced, %{pm | velocity: clip_velocity(slide.original, plane, 2)}}

  defp off_plane(pm, slide, plane) do
    if wall_jump?(pm, plane) do
      {vx, vy, vz} = clip_velocity(slide.original, plane, 2)

      {:bounced,
       %{
         pm
         | velocity: {vx, vy, if(vz < @jumpspeed, do: @jumpspeed, else: vz)},
           jump_msec: trunc(pm.cmd.msec),
           jump_held: true,
           waterjumptime: 0.0
       }}
    else
      {:clipped, %{pm | velocity: clip_velocity(slide.original, plane, 1)}}
    end
  end

  defp wall_jump?(pm, {_, _, z}) do
    pm.movevars.walljump != 0 and z != 1 and Vec.length(pm.velocity) > 200 and jump?(pm.cmd) and
      not pm.jump_held and pm.waterjumptime == 0
  end

  defp clear_of_others?(velocity, indexed, index),
    do:
      Enum.all?(indexed, fn {plane, other} -> other == index or Vec.dot(velocity, plane) >= 0 end)

  defp crease(pm, %{planes: [first, second]} = slide) do
    direction = Vec.cross(first, second)

    continue_slide(
      %{pm | velocity: Vec.scale(direction, Vec.dot(direction, pm.velocity))},
      slide
    )
  end

  defp crease(pm, slide), do: finish_slide(%{pm | velocity: @zero}, slide)

  defp continue_slide(pm, slide) do
    if Vec.dot(pm.velocity, slide.primal) <= 0,
      do: finish_slide(%{pm | velocity: @zero}, slide),
      else: slide(pm, %{slide | bump: slide.bump + 1})
  end

  defp finish_slide(%{waterjumptime: time} = pm, slide) when time != 0,
    do: {%{pm | velocity: slide.primal}, slide.blocked}

  defp finish_slide(pm, slide), do: {pm, slide.blocked}

  defp step_slide_move(pm, in_air) do
    start = %{origin: pm.origin, velocity: pm.velocity}
    {pm, blocked} = slide_move(pm)
    step_after(pm, blocked, start, in_air)
  end

  defp step_after(pm, 0, _start, in_air), do: {step_down(pm, in_air), 0}

  defp step_after(pm, blocked, start, true) do
    if (blocked &&& @blocked_step) == 0,
      do: {pm, blocked},
      else: air_step(pm, blocked, start)
  end

  defp step_after(pm, blocked, start, false),
    do: step_up(pm, blocked, start, pm.movevars.stepheight, false)

  defp step_down(%{movevars: %{stepdown: true}} = pm, false) do
    trace =
      trace(pm, pm.origin, Vec.madd(pm.origin, pm.gravitydir, pm.movevars.stepheight))

    if trace.fraction != 1 and up_speed(pm, trace.normal) > @min_step_normal and
         not trace.start_solid and not trace.all_solid,
       do: %{pm | origin: trace.end_pos},
       else: pm
  end

  defp step_down(pm, _in_air), do: pm

  defp air_step(pm, blocked, start) do
    from = if up_speed(pm, start.velocity) < 0, do: pm.origin, else: start.origin
    trace = trace(pm, from, Vec.madd(from, pm.gravitydir, pm.movevars.stepheight))

    if trace.fraction == 1 or steep?(pm, trace.normal) do
      {pm, blocked}
    else
      {_, _, from_z} = from
      {_, _, end_z} = trace.end_pos
      step_up(pm, blocked, start, pm.movevars.stepheight - (from_z - end_z), true)
    end
  end

  defp step_up(pm, blocked, start, stepsize, in_air) do
    down = %{origin: pm.origin, velocity: pm.velocity}
    pm = %{pm | origin: start.origin, velocity: start.velocity}
    lift = trace(pm, pm.origin, Vec.madd(pm.origin, pm.gravitydir, -stepsize))

    pm =
      if not lift.start_solid and not lift.all_solid,
        do: %{pm | origin: lift.end_pos},
        else: pm

    pm =
      if in_air and up_speed(pm, start.origin) < 0,
        do: %{pm | velocity: flatten(pm.velocity, pm.gravitydir)},
        else: pm

    {pm, _blocked} = slide_move(pm)
    press = trace(pm, pm.origin, Vec.madd(pm.origin, pm.gravitydir, stepsize))

    if press.fraction != 1 and steep?(pm, press.normal) do
      use_down(pm, down, blocked)
    else
      pm =
        if not press.start_solid and not press.all_solid,
          do: %{pm | origin: press.end_pos},
          else: pm

      choose_step(pm, down, start, blocked)
    end
  end

  defp choose_step(pm, down, start, blocked) do
    cond do
      up_speed(pm, pm.origin) < up_speed(pm, start.origin) ->
        use_down(pm, down, blocked)

      across(pm, down.origin, start.origin) >= across(pm, pm.origin, start.origin) ->
        use_down(pm, down, blocked)

      true ->
        {pm |> keep_fall(down) |> slow_air_step(start, blocked), blocked}
    end
  end

  defp across(pm, to, from) do
    distance = flatten(Vec.sub(to, from), pm.gravitydir)
    Vec.dot(distance, distance)
  end

  defp use_down(pm, down, blocked),
    do: {%{pm | origin: down.origin, velocity: down.velocity}, blocked}

  defp keep_fall(pm, down) do
    shift = Vec.dot(down.velocity, pm.gravitydir) - Vec.dot(pm.velocity, pm.gravitydir)
    %{pm | velocity: Vec.madd(pm.velocity, pm.gravitydir, shift)}
  end

  defp slow_air_step(pm, start, blocked) do
    if not pm.onground and pm.waterlevel < 2 and (blocked &&& @blocked_step) != 0 do
      {_, _, z} = pm.origin
      {_, _, start_z} = start.origin
      scale = 1 - 0.01 * (z - start_z)
      {vx, vy, vz} = pm.velocity
      %{pm | velocity: {vx * scale, vy * scale, vz}}
    else
      pm
    end
  end

  defp trace(pm, start, stop), do: player_trace(pm, start, stop, pm.mins, pm.maxs)
  defp trace_line(pm, start, stop), do: player_trace(pm, start, stop, @zero, @zero)

  defp player_trace(pm, start, stop, mins, maxs) do
    blank = %Trace{fraction: 1.0, end_pos: stop, all_solid: false, start_solid: false, hit: nil}

    total =
      pm.physents
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce(blank, fn {physent, index}, total ->
        nearer(total, physent_trace(pm, physent, start, stop, mins, maxs), index)
      end)

    if total.start_solid, do: %{total | fraction: 0.0}, else: total
  end

  defp nearer(total, nil, _index), do: total

  defp nearer(total, trace, index) do
    trace = if trace.all_solid, do: %{trace | start_solid: true}, else: trace

    if trace.fraction < total.fraction or (trace.start_solid and not total.start_solid),
      do: %{trace | hit: index},
      else: total
  end

  defp physent_trace(_pm, %Physent{nonsolid: true}, _start, _stop, _mins, _maxs), do: nil

  defp physent_trace(_pm, %Physent{contents: contents}, _start, _stop, _mins, _maxs)
       when contents != 0 and (contents &&& @player_solid) == 0,
       do: nil

  defp physent_trace(_pm, %Physent{model: nil} = physent, start, stop, mins, maxs),
    do: box_trace(physent, start, stop, mins, maxs)

  defp physent_trace(pm, physent, start, stop, mins, maxs),
    do: model_trace(pm, physent, start, stop, mins, maxs)

  defp box_trace(physent, start, stop, mins, maxs) do
    low = Vec.sub(physent.mins, maxs)
    high = Vec.sub(physent.maxs, mins)
    from = Vec.sub(start, physent.origin)
    to = Vec.sub(stop, physent.origin)

    if missed?(from, to, mins, maxs, low, high) do
      nil
    else
      trace = Hull.trace(Hull.box(low, high), from, to)
      %{trace | end_pos: Vec.add(trace.end_pos, physent.origin)}
    end
  end

  defp model_trace(pm, physent, start, stop, mins, maxs) do
    from = Vec.sub(start, physent.origin)
    to = Vec.sub(stop, physent.origin)
    hull = pm.server.hull.(physent.model.hulls, Vec.sub(maxs, mins))
    offset = Vec.sub(hull.mins, mins)

    cond do
      turned?(physent.angles) ->
        turned_trace(hull, offset, physent, {start, stop}, {from, to})

      missed?(from, to, mins, maxs, physent.model.mins, physent.model.maxs) ->
        nil

      true ->
        trace = Hull.trace(hull, Vec.sub(from, offset), Vec.sub(to, offset))
        %{trace | end_pos: trace.end_pos |> Vec.add(offset) |> Vec.add(physent.origin)}
    end
  end

  defp turned_trace(hull, offset, physent, {start, stop}, {from, to}) do
    axes = Angles.vectors(physent.angles)
    local_from = from |> to_local(axes) |> Vec.sub(offset)
    local_to = to |> to_local(axes) |> Vec.sub(offset)
    trace = Hull.trace(hull, local_from, local_to)

    %{
      trace
      | end_pos: Vec.lerp(start, stop, trace.fraction),
        normal: to_world(trace.normal, axes)
    }
  end

  defp turned?({pitch, yaw, roll}), do: pitch != 0 or yaw != 0 or roll != 0

  defp to_local(point, {forward, right, up}),
    do: {Vec.dot(point, forward), -Vec.dot(point, right), Vec.dot(point, up)}

  defp to_world({x, y, z}, {forward, right, up}),
    do: forward |> Vec.scale(x) |> Vec.madd(right, -y) |> Vec.madd(up, z)

  defp missed?(from, to, mins, maxs, low, high) do
    Enum.any?(0..2, fn axis ->
      start = elem(from, axis)
      stop = elem(to, axis)
      bottom = elem(mins, axis)
      top = elem(maxs, axis)

      (start + bottom > elem(high, axis) and stop + bottom > elem(high, axis)) or
        (start + top < elem(low, axis) and stop + top < elem(low, axis))
    end)
  end

  defp point_contents(pm, point) do
    pm.physents
    |> Tuple.to_list()
    |> tl()
    |> Enum.reduce(World.contents_world(pm.server, point), fn physent, bits ->
      bits ||| physent_contents(physent, point)
    end)
  end

  defp physent_contents(%Physent{model: nil, contents: 0}, _point), do: 0

  defp physent_contents(%Physent{model: nil} = physent, point) do
    if inside?(
         point,
         Vec.add(physent.origin, physent.mins),
         Vec.add(physent.origin, physent.maxs)
       ),
       do: physent.contents,
       else: 0
  end

  defp physent_contents(physent, point) do
    low = Vec.add(physent.origin, physent.model.mins)
    high = Vec.add(physent.origin, physent.model.maxs)
    if inside?(point, low, high), do: model_contents(physent, point), else: 0
  end

  defp model_contents(%Physent{contents: 0, nonsolid: true}, _point), do: 0
  defp model_contents(%Physent{contents: 0} = physent, point), do: local_contents(physent, point)

  defp model_contents(physent, point),
    do: if(local_contents(physent, point) != 0, do: physent.contents, else: 0)

  defp local_contents(physent, point) do
    local = Vec.sub(point, physent.origin)

    local =
      if turned?(physent.angles),
        do: to_local(local, Angles.vectors(physent.angles)),
        else: local

    Contents.of_code(Hull.contents(hd(physent.model.hulls), local))
  end

  defp inside?({x, y, z}, {x0, y0, z0}, {x1, y1, z1}),
    do: x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z0 and z <= z1

  defp extra_box_contents(pm, point) do
    pm.physents
    |> Tuple.to_list()
    |> tl()
    |> Enum.reduce(0, fn physent, bits -> bits ||| extra_contents(pm, physent, point) end)
  end

  defp extra_contents(_pm, %Physent{nonsolid: false}, _point), do: 0
  defp extra_contents(_pm, %Physent{contents: 0}, _point), do: 0

  defp extra_contents(pm, %Physent{model: nil} = physent, point) do
    overlap =
      Enum.all?(0..2, fn axis ->
        elem(point, axis) + elem(pm.maxs, axis) >=
          elem(physent.origin, axis) + elem(physent.mins, axis) and
          elem(point, axis) + elem(pm.mins, axis) <=
            elem(physent.origin, axis) + elem(physent.maxs, axis)
      end)

    if overlap, do: physent.contents, else: 0
  end

  defp extra_contents(pm, physent, point) do
    case model_trace(pm, physent, point, point, pm.mins, pm.maxs) do
      nil -> 0
      trace -> if trace.start_solid or trace.in_water, do: physent.contents, else: 0
    end
  end
end
