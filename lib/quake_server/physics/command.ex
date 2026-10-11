defmodule QuakeServer.Physics.Command do
  @moduledoc """
  A player's command run by a program that defines `SV_RunClientCommand`, as FTE runs
  one when it arrives (`SV_RunFullQCMovement`, then `SV_PostRunCmd`): the `input_`
  globals are set from the command; unless the server is fixing the player's view
  (`fixangle`), `v_angle` and `movement` are too; the button fields and `impulse` are set;
  the velocity is bounded; while alive, the body turns to the view (a third of the pitch)
  and rolls with sideways speed; then `PlayerPreThink`, the player's think and
  `SV_RunClientCommand` run, and `PlayerPostThink` and the missile it spawned (`newmis`)
  after. When the program turned the view itself, the new view angles are kept for the
  client in the server's `ext.setangle`. The player is from then on left out of the
  physics frames (`QuakeServer.Physics.independent?/2`).

      server = QuakeServer.Physics.Command.run(server, 1, command)

  A command is `%{angles:, forward:, side:, up:, buttons:, impulse:, msec:}`, with an
  optional `sequence:`: the view angles in degrees (sent as 16-bit angles), the moves in
  units a second, the buttons as bits (bit 0 `button0`, bit 1 `button2`, bits 2 to 7
  `button3` to `button8`, bit 8 `buttonuse`, bit 9 `buttonchat`, bit 10 `cursor_active`,
  bits 11 to 18 `button9` to `button16`), the time it covers in milliseconds, and the
  client's number for it (the `input_sequence` global, 0 when not given). The program's
  `time` is the server's host clock throughout.
  """

  import Bitwise

  alias Cauldron3D.Vec
  alias QuakeServer.{Angles, Edicts, Physics, Server}

  @buttons [
    {"button3", 2},
    {"button4", 3},
    {"button5", 4},
    {"button6", 5},
    {"button7", 6},
    {"button8", 7},
    {"buttonuse", 8},
    {"buttonchat", 9},
    {"cursor_active", 10},
    {"button9", 11},
    {"button10", 12},
    {"button11", 13},
    {"button12", 14},
    {"button13", 15},
    {"button14", 16},
    {"button15", 17},
    {"button16", 18}
  ]

  @doc "Whether `server`'s program runs its players' commands itself."
  @spec program_moves?(Server.t()) :: boolean()
  def program_moves?(%Server{} = server),
    do: QuakeC.Progs.function(server.qc.progs, "SV_RunClientCommand") != nil

  @doc """
  Run `command` for player entity `entity`, marking it as running its own commands unless
  `independent?: false` is given (a physics frame re-running the last command for a
  player that has sent none yet); nothing until a player has connected.
  """
  @spec run(Server.t(), non_neg_integer(), map(), keyword()) :: Server.t()
  def run(server, entity, command, opts \\ [])

  def run(%Server{parms: nil} = server, _entity, _command, _opts), do: server

  def run(%Server{} = server, entity, command, opts) do
    angles = command |> Map.get(:angles, {0.0, 0.0, 0.0}) |> short_angles()
    fixed? = Edicts.float(server, entity, "fixangle") != 0

    server =
      server
      |> Edicts.put(entity, "idealpitch", 0.0)
      |> inputs(command, angles)
      |> view(entity, command, angles, fixed?)
      |> buttons(entity, Map.get(command, :buttons, 0))
      |> impulse(entity, Map.get(command, :impulse, 0))
      |> Physics.check_velocity(entity)
      |> body(entity, fixed?)

    start = Edicts.vector(server, entity, "v_angle")

    server =
      server
      |> clock_time()
      |> self_is(entity)
      |> Server.call_named("PlayerPreThink")
      |> then(&elem(Physics.think(&1, entity), 0))
      |> self_is(entity)
      |> Server.call_named("SV_RunClientCommand")
      |> turned_view(entity, start)
      |> clock_time()
      |> self_is(entity)
      |> Server.call_named("PlayerPostThink")
      |> Physics.run_newmis()

    if Keyword.get(opts, :independent?, true),
      do: Physics.independent(server, entity),
      else: server
  end

  defp inputs(server, command, angles) do
    msec = Map.get(command, :msec, 0)

    qc =
      server.qc
      |> QuakeC.put_declared("input_sequence", Map.get(command, :sequence, 0) / 1)
      |> QuakeC.put_declared("input_timelength", Float.round(msec / 1000, 6))
      |> QuakeC.put_declared("input_impulse", Map.get(command, :impulse, 0) / 1)
      |> QuakeC.put_declared("input_angles", angles)
      |> QuakeC.put_declared("input_movevalues", movevalues(command))
      |> QuakeC.put_declared("input_servertime", server.clock / 1)
      |> QuakeC.put_declared("input_buttons", Map.get(command, :buttons, 0) / 1)

    %{server | qc: qc}
  end

  defp view(server, _entity, _command, _angles, true), do: server

  defp view(server, entity, command, angles, false) do
    server
    |> Edicts.put(entity, "v_angle", angles)
    |> Edicts.put(entity, "movement", movevalues(command))
  end

  defp buttons(server, entity, bits) do
    server =
      server
      |> Edicts.put(entity, "button0", (bits &&& 1) / 1)
      |> Edicts.put(entity, "button2", (bits >>> 1 &&& 1) / 1)

    Enum.reduce(@buttons, server, fn {field, bit}, acc ->
      Edicts.put(acc, entity, field, (bits >>> bit &&& 1) / 1)
    end)
  end

  defp impulse(server, _entity, 0), do: server
  defp impulse(server, entity, impulse), do: Edicts.put(server, entity, "impulse", impulse / 1)

  defp body(server, entity, fixed?) do
    if Edicts.float(server, entity, "health") > 0 do
      {pitch, yaw, _} = Edicts.vector(server, entity, "v_angle")
      {old_pitch, old_yaw, _} = Edicts.vector(server, entity, "angles")

      {body_pitch, body_yaw} =
        if fixed?,
          do: {old_pitch, old_yaw},
          else: {mesh_pitch(server) * pitch / 3, yaw}

      roll =
        calc_roll(server, {body_pitch, body_yaw, 0.0}, Edicts.vector(server, entity, "velocity"))

      Edicts.put(server, entity, "angles", {body_pitch, body_yaw, roll * 4})
    else
      server
    end
  end

  defp calc_roll(server, angles, velocity) do
    {_forward, right, _up} = Angles.vectors(angles)
    side = Vec.dot(velocity, right)
    sign = if side < 0, do: -1, else: 1
    side = abs(side)
    angle = cvar(server, "cl_rollangle", 2.0)
    speed = cvar(server, "cl_rollspeed", 200.0)
    if side < speed, do: side * angle / speed * sign, else: angle * sign
  end

  defp turned_view(server, entity, start) do
    angles = Edicts.vector(server, entity, "v_angle")

    if Edicts.float(server, entity, "fixangle") == 0 and angles != start,
      do: %{server | ext: Map.put(server.ext, :setangle, angles)},
      else: server
  end

  defp self_is(server, entity), do: %{server | qc: QuakeC.put_global(server.qc, "self", entity)}

  defp clock_time(server),
    do: %{server | qc: QuakeC.put_global(server.qc, "time", server.clock / 1)}

  defp mesh_pitch(server) do
    if Server.cvar(server, "r_meshpitch") > 0, do: 1.0, else: -1.0
  end

  defp cvar(server, name, default) do
    if Server.cvar?(server, name), do: Server.cvar(server, name), else: default
  end

  defp movevalues(command) do
    {Map.get(command, :forward, 0) / 1, Map.get(command, :side, 0) / 1,
     Map.get(command, :up, 0) / 1}
  end

  defp short_angles({pitch, yaw, roll}), do: {short(pitch), short(yaw), short(roll)}

  defp short(angle) do
    steps = trunc(angle * 65_536 / 360) &&& 0xFFFF
    signed = if steps >= 0x8000, do: steps - 0x10000, else: steps
    signed * 360 / 65_536
  end
end
