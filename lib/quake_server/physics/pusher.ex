defmodule QuakeServer.Physics.Pusher do
  @moduledoc """
  Doors, lifts and trains, as FTE runs them (`WPhys_Physics_Pusher`): brush models that
  move on their own clock (`ltime`) by their `velocity` and turn by their `avelocity`,
  through `QuakeServer.Physics.Push` (moving only) or `QuakeServer.Physics.PushTurn`
  (turning). Each frame a pusher moves for the frame, or only until its `nextthink` when
  that comes first; the clock advances only when the push went through. When the clock
  has reached `nextthink` the think runs, with the program's `time` the frame's start. A
  pusher its think moved or turned is put back and pushed that far, taking along what it
  carries.

      server = QuakeServer.Physics.Pusher.run(server, door)
  """

  alias Cauldron3D.Vec
  alias QuakeServer.{Edicts, Server}
  alias QuakeServer.Physics.{Push, PushTurn}

  @doc "Move pusher `entity` through this frame, and run its think when its clock has reached it."
  @spec run(Server.t(), non_neg_integer()) :: Server.t()
  def run(%Server{} = server, entity) do
    old = Edicts.float(server, entity, "ltime")
    at = Edicts.float(server, entity, "nextthink")
    movetime = if at < old + server.frametime, do: max(at - old, 0.0), else: server.frametime
    server = if movetime > 0, do: push_move(server, entity, movetime), else: server

    if at > old and at <= Edicts.float(server, entity, "ltime"),
      do: think(server, entity, Edicts.int(server, entity, "think"), server.time),
      else: server
  end

  @doc "Push `pusher` by `move` and turn it by `turn` at once, as after its think moved it."
  @spec push(Server.t(), non_neg_integer(), Vec.t(), Vec.t()) :: {:ok | :blocked, Server.t()}
  def push(server, pusher, move, {pitch, yaw, roll}) when pitch == 0 and yaw == 0 and roll == 0,
    do: Push.run(server, pusher, move)

  def push(server, pusher, move, turn), do: PushTurn.run(server, pusher, move, turn)

  defp push_move(server, pusher, movetime) do
    velocity = Edicts.vector(server, pusher, "velocity")
    spin = Edicts.vector(server, pusher, "avelocity")
    ltime = Edicts.float(server, pusher, "ltime")

    if still?(velocity) and still?(spin) do
      Edicts.put(server, pusher, "ltime", ltime + movetime)
    else
      case push(server, pusher, Vec.scale(velocity, movetime), Vec.scale(spin, movetime)) do
        {:ok, server} -> Edicts.put(server, pusher, "ltime", ltime + movetime)
        {:blocked, server} -> server
      end
    end
  end

  defp still?({x, y, z}), do: x == 0 and y == 0 and z == 0

  defp think(server, entity, function, moment) do
    origin = Edicts.vector(server, entity, "origin")
    angles = Edicts.vector(server, entity, "angles")
    server = Edicts.put(server, entity, "nextthink", 0.0)
    server = if function != 0, do: run_at(server, function, entity, moment), else: server
    snap(server, entity, origin, angles)
  end

  defp run_at(server, function, entity, moment) do
    server = Server.set_globals(server, entity, 0)
    server = %{server | qc: QuakeC.put_global(server.qc, "time", moment)}
    QuakeC.Exec.call(server, function, server.builtins, Server.exec_opts(server))
  end

  defp snap(server, entity, origin, angles) do
    if Edicts.free?(server, entity) do
      server
    else
      move = Vec.sub(Edicts.vector(server, entity, "origin"), origin)
      turn = Vec.sub(Edicts.vector(server, entity, "angles"), angles)

      if Vec.length(move) + Vec.length(turn) > 1 / 64 do
        server
        |> Edicts.put(entity, "origin", origin)
        |> Edicts.put(entity, "angles", angles)
        |> push(entity, move, turn)
        |> elem(1)
      else
        server
      end
    end
  end
end
