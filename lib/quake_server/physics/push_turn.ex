defmodule QuakeServer.Physics.PushTurn do
  @moduledoc """
  FTE's turning push: a pusher moved by `move` and turned by `turn` takes along what
  stands on it and what its new place overlaps. Each one is moved by `move`, turned by
  `turn` and swung round the pusher's origin by it, then its spot is tested. One that
  will not fit is put back if that is free, else pushed by `move` through the world,
  else nudged an eighth of a unit each way. A box with no width, anything in a liquid
  pusher's way, or one not solid or a box trigger (flattened) never blocks; anything else
  blocks: everything goes back, the pusher's `blocked` runs. Once all have moved, each
  touches the triggers it is in.

  A turn in yaw alone also turns a client's view: its `v_angle` yaw moves with the
  pusher and its `fixangle` becomes 2, the turn to add to the view.

      {:ok, server} = QuakeServer.Physics.PushTurn.run(server, train, {4.0, 0.0, 0.0}, {0.0, 2.0, 0.0})
  """

  alias Cauldron3D.Vec
  alias QuakeServer.{Angles, Edicts, Q, Server, World}
  alias QuakeServer.Physics.{Move, Pushed}

  @doc "Push `pusher` by `move` and turn it by `turn`. Returns `{:ok, server}`, or `{:blocked, server}` with everything put back."
  @spec run(Server.t(), non_neg_integer(), Vec.t(), Vec.t()) :: {:ok | :blocked, Server.t()}
  def run(%Server{} = server, pusher, move, turn) do
    old_min = Edicts.vector(server, pusher, "absmin")
    old_max = Edicts.vector(server, pusher, "absmax")
    box = {Vec.add(old_min, move), Vec.add(old_max, move)}
    first = snapshot(server, pusher)

    server =
      server
      |> Edicts.put(pusher, "origin", Vec.add(first.origin, move))
      |> Edicts.put(pusher, "angles", Vec.add(first.angles, turn))
      |> World.link(pusher, false)

    push = %{
      pusher: pusher,
      move: move,
      turn: turn,
      axes: Angles.vectors(Vec.scale(turn, -1.0)),
      yaw: yaw_change(turn)
    }

    skip = Enum.map([:push, :none, :noclip, :angle_noclip], &Q.movetype/1)
    entities = Pushed.candidates(server, pusher, box, {old_min, old_max}, skip)
    each(server, push, entities, [first])
  end

  defp yaw_change({pitch, yaw, roll}) when pitch == 0 and roll == 0, do: yaw
  defp yaw_change(_turn), do: 0.0

  defp snapshot(server, entity) do
    %{
      entity: entity,
      origin: Edicts.vector(server, entity, "origin"),
      angles: Edicts.vector(server, entity, "angles")
    }
  end

  defp each(server, _push, [], pushed) do
    server = Enum.reduce(pushed, server, &World.touch_triggers(&2, &1.entity))
    {:ok, server}
  end

  defp each(server, push, [entity | rest], pushed) do
    carried? =
      Edicts.int(server, push.pusher, "movetype") == Q.movetype(:push) or
        Edicts.int(server, entity, "groundentity") == push.pusher

    if carried? do
      before = snapshot(server, entity)

      case carry(server, push, entity, before) do
        {:kept, server} -> each(server, push, rest, [before | pushed])
        {:left, server} -> each(server, push, rest, pushed)
        {:stuck, server} -> unmoved(server, push, entity, rest, [before | pushed])
      end
    else
      unmoved(server, push, entity, rest, pushed)
    end
  end

  defp carry(server, push, entity, before) do
    server =
      server
      |> Edicts.put(entity, "origin", Vec.add(before.origin, push.move))
      |> Edicts.put(entity, "angles", Vec.add(before.angles, push.turn))
      |> turn_view(entity, push.yaw)
      |> swing(push, entity)
      |> ground(push.pusher, entity)

    cond do
      not World.stuck?(server, entity) ->
        {:kept, World.link(server, entity, false)}

      not World.stuck?(Edicts.put(server, entity, "origin", before.origin), entity) ->
        {:left, Edicts.put(server, entity, "origin", before.origin)}

      true ->
        shove(Edicts.put(server, entity, "origin", before.origin), push.move, entity)
    end
  end

  defp swing(server, push, entity) do
    {forward, right, up} = push.axes
    pivot = Edicts.vector(server, push.pusher, "origin")
    at = Edicts.vector(server, entity, "origin")
    relative = Vec.sub(at, pivot)
    swung = {Vec.dot(relative, forward), -Vec.dot(relative, right), Vec.dot(relative, up)}
    Edicts.put(server, entity, "origin", Vec.add(at, Vec.sub(swung, relative)))
  end

  defp ground(server, pusher, entity) do
    server =
      if Edicts.int(server, entity, "movetype") != Q.movetype(:walk),
        do: Pushed.unground(server, entity),
        else: server

    if Edicts.int(server, entity, "groundentity") != pusher,
      do: Edicts.put(server, entity, "groundentity", 0),
      else: server
  end

  defp shove(server, move, entity) do
    {server, _trace} = Move.push(server, entity, move)

    if World.stuck?(server, entity),
      do: jiggle(server, entity, Edicts.vector(server, entity, "origin"), 0),
      else: {:kept, server}
  end

  defp jiggle(server, _entity, _at, 8), do: {:stuck, server}

  defp jiggle(server, entity, {x, y, z}, i) do
    step = fn bit -> if Bitwise.band(i, bit) != 0, do: -1 / 8, else: 1 / 8 end
    server = Edicts.put(server, entity, "origin", {x + step.(1), y + step.(2), z + step.(4)})

    if World.stuck?(server, entity),
      do: jiggle(server, entity, {x, y, z}, i + 1),
      else: {:kept, World.link(server, entity, false)}
  end

  defp unmoved(server, push, entity, rest, pushed) do
    cond do
      Pushed.flat?(server, entity) -> each(World.link(server, entity, false), push, rest, pushed)
      Pushed.liquid?(server, push.pusher) -> each(server, push, rest, pushed)
      Pushed.soft?(server, entity) -> each(Pushed.flatten(server, entity), push, rest, pushed)
      true -> {:blocked, block(server, push, entity, pushed)}
    end
  end

  defp block(server, push, blocker, pushed) do
    server = Pushed.blocked(server, push.pusher, blocker)

    Enum.reduce(pushed, server, fn before, acc ->
      acc
      |> Edicts.put(before.entity, "origin", before.origin)
      |> Edicts.put(before.entity, "angles", before.angles)
      |> turn_view(before.entity, -push.yaw)
      |> World.link(before.entity, false)
    end)
  end

  defp turn_view(server, entity, yaw) when yaw == 0 or entity != 1, do: server

  defp turn_view(server, entity, yaw) do
    {pitch, view_yaw, roll} = Edicts.vector(server, entity, "v_angle")

    server
    |> Edicts.put(entity, "v_angle", {pitch, view_yaw + yaw, roll})
    |> Edicts.put(entity, "fixangle", 2.0)
  end
end
