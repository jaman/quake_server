defmodule QuakeServer.Player do
  @moduledoc """
  The player's command applied before physics for a program that does not run its
  players' commands itself, as FTE's NetQuake player physics (`SV_ClientThink`) does: view
  angles and buttons copied in, the body turned to the view and rolled by strafing,
  punch angles decayed, and the velocity accelerated on the ground (with friction,
  stronger at ledges), in the air, or in water.

      server = QuakeServer.Player.think(server, 1, command)
  """

  alias Cauldron3D.Vec
  alias QuakeServer.{Angles, Edicts, Q, Server, World}

  @doc "Apply `command` to player entity `entity`."
  @spec think(Server.t(), non_neg_integer(), Server.command()) :: Server.t()
  def think(%Server{parms: nil} = server, _entity, _command), do: server

  def think(%Server{} = server, entity, command) do
    server = read(server, entity, command)

    if Edicts.int(server, entity, "movetype") == Q.movetype(:none) do
      server
    else
      server = drop_punch(server, entity)

      if Edicts.float(server, entity, "health") <= 0,
        do: server,
        else: steer(server, entity, command)
    end
  end

  defp read(server, entity, command) do
    server =
      server
      |> Edicts.put(entity, "v_angle", Vec.float(command.angles))
      |> Edicts.put(entity, "button0", if(command.attack, do: 1.0, else: 0.0))
      |> Edicts.put(entity, "button2", if(command.jump, do: 1.0, else: 0.0))

    if command.impulse != 0,
      do: Edicts.put(server, entity, "impulse", command.impulse / 1),
      else: server
  end

  defp drop_punch(server, entity) do
    punch = Edicts.vector(server, entity, "punchangle")
    length = max(Vec.length(punch) - 10 * server.frametime, 0.0)
    Edicts.put(server, entity, "punchangle", Vec.scale(Vec.normalize(punch), length))
  end

  defp steer(server, entity, command) do
    {pitch, yaw, _} =
      Vec.add(
        Edicts.vector(server, entity, "v_angle"),
        Edicts.vector(server, entity, "punchangle")
      )

    {body_pitch, body_yaw, _} = Edicts.vector(server, entity, "angles")

    roll =
      roll(Edicts.vector(server, entity, "angles"), Edicts.vector(server, entity, "velocity")) * 4

    angles =
      if Edicts.float(server, entity, "fixangle") != 0,
        do: {body_pitch, body_yaw, roll},
        else: {-pitch / 3, yaw, roll}

    server = Edicts.put(server, entity, "angles", angles)

    cond do
      Edicts.flag?(server, entity, :waterjump) ->
        water_jump(server, entity)

      Edicts.float(server, entity, "waterlevel") >= 2 and
          Edicts.int(server, entity, "movetype") != Q.movetype(:noclip) ->
        swim(server, entity, command)

      true ->
        air(server, entity, command)
    end
  end

  defp roll(angles, velocity) do
    {_, right, _} = Angles.vectors(angles)
    side = Vec.dot(velocity, right)
    sign = if side < 0, do: -1, else: 1
    side = abs(side)
    sign * if(side < 200, do: side * 2.0 / 200, else: 2.0)
  end

  defp water_jump(server, entity) do
    server =
      if server.time > Edicts.float(server, entity, "teleport_time") or
           Edicts.float(server, entity, "waterlevel") == 0,
         do:
           server
           |> Edicts.clear_flag(entity, :waterjump)
           |> Edicts.put(entity, "teleport_time", 0.0),
         else: server

    {mx, my, _} = Edicts.vector(server, entity, "movedir")
    {_, _, vz} = Edicts.vector(server, entity, "velocity")
    Edicts.put(server, entity, "velocity", {mx, my, vz})
  end

  defp swim(server, entity, command) do
    {forward, right, _up} = Angles.vectors(Edicts.vector(server, entity, "v_angle"))
    wish = forward |> Vec.scale(command.forward) |> Vec.madd(right, command.side)
    {wx, wy, wz} = wish
    idle? = command.forward == 0 and command.side == 0 and command.up == 0
    wish = if idle?, do: {wx, wy, wz - 60}, else: {wx, wy, wz + command.up}
    max_speed = Server.cvar(server, "sv_maxspeed")
    speed = Vec.length(wish)

    {wish, speed} =
      if speed > max_speed,
        do: {Vec.scale(wish, max_speed / speed), max_speed},
        else: {wish, speed}

    speed = speed * 0.7
    velocity = Edicts.vector(server, entity, "velocity")
    current = Vec.length(velocity)

    {velocity, current} =
      if current > 0 do
        slowed =
          max(current - server.frametime * current * Server.cvar(server, "sv_friction"), 0.0)

        {Vec.scale(velocity, slowed / current), slowed}
      else
        {velocity, 0.0}
      end

    add = speed - current

    velocity =
      if speed == 0 or add <= 0 do
        velocity
      else
        accel = min(Server.cvar(server, "sv_accelerate") * speed * server.frametime, add)
        Vec.madd(velocity, Vec.normalize(wish), accel)
      end

    Edicts.put(server, entity, "velocity", velocity)
  end

  defp air(server, entity, command) do
    {forward, right, _up} = Angles.vectors(Edicts.vector(server, entity, "angles"))

    forward_move =
      if server.time < Edicts.float(server, entity, "teleport_time") and command.forward < 0,
        do: 0,
        else: command.forward

    {wx, wy, _} = forward |> Vec.scale(forward_move) |> Vec.madd(right, command.side)
    walking? = Edicts.int(server, entity, "movetype") == Q.movetype(:walk)
    wish = if walking?, do: {wx, wy, 0.0}, else: {wx, wy, command.up / 1}
    max_speed = Server.cvar(server, "sv_maxspeed")
    speed = Vec.length(wish)

    {wish, speed} =
      if speed > max_speed,
        do: {Vec.scale(wish, max_speed / speed), max_speed},
        else: {wish, speed}

    direction = Vec.normalize(wish)
    velocity = Edicts.vector(server, entity, "velocity")

    velocity =
      cond do
        Edicts.int(server, entity, "movetype") == Q.movetype(:noclip) ->
          wish

        Edicts.flag?(server, entity, :onground) ->
          server |> friction(entity, velocity) |> accelerate(direction, speed, server)

        true ->
          air_accelerate(velocity, wish, speed, server)
      end

    Edicts.put(server, entity, "velocity", velocity)
  end

  defp friction(server, entity, {vx, vy, _vz} = velocity) do
    speed = :math.sqrt(vx * vx + vy * vy)

    if speed == 0 do
      velocity
    else
      {ox, oy, oz} = Edicts.vector(server, entity, "origin")
      {_, _, low} = Edicts.vector(server, entity, "mins")
      start = {ox + vx / speed * 16, oy + vy / speed * 16, oz + low}
      {sx, sy, sz} = start

      trace =
        World.move(server, start, Vec.zero(), Vec.zero(), {sx, sy, sz - 34}, :nomonsters, entity)

      base = Server.cvar(server, "sv_friction")

      friction =
        if trace.fraction == 1.0, do: base * Server.cvar(server, "sv_edgefriction"), else: base

      control = max(speed, Server.cvar(server, "sv_stopspeed"))
      slowed = max(speed - server.frametime * control * friction, 0.0) / speed
      Vec.scale(velocity, slowed)
    end
  end

  defp accelerate(velocity, direction, speed, server) do
    add = speed - Vec.dot(velocity, direction)

    if add <= 0 do
      velocity
    else
      accel = min(Server.cvar(server, "sv_accelerate") * server.frametime * speed, add)
      Vec.madd(velocity, direction, accel)
    end
  end

  defp air_accelerate(velocity, wish, speed, server) do
    direction = Vec.normalize(wish)
    capped = min(Vec.length(wish), 30.0)
    add = capped - Vec.dot(velocity, direction)

    if add <= 0 do
      velocity
    else
      accel = min(Server.cvar(server, "sv_accelerate") * speed * server.frametime, add)
      Vec.madd(velocity, direction, accel)
    end
  end
end
