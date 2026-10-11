defmodule QuakeServer.Physics.Push do
  @moduledoc """
  FTE's straight push: a pusher moved by `move` takes along what stands on it and what
  its new place overlaps, by setting each one's origin and testing the spot. One that
  will not fit is nudged an eighth of a unit further, then left where it was if that is
  free; a box with no width, one not solid or a box trigger (flattened), or anything in
  a liquid pusher's way never blocks. Anything else blocks: the pusher and everything
  moved go back, and the pusher's `blocked` runs. Nothing is touched by the push itself.

      {:ok, server} = QuakeServer.Physics.Push.run(server, train, {4.0, 0.0, 0.0})
  """

  alias Cauldron3D.Vec
  alias QuakeServer.{Edicts, Q, Server, World}
  alias QuakeServer.Physics.Pushed

  @doc "Push `pusher` by `move`. Returns `{:ok, server}`, or `{:blocked, server}` with everything put back."
  @spec run(Server.t(), non_neg_integer(), Vec.t()) :: {:ok | :blocked, Server.t()}
  def run(%Server{} = server, pusher, move) do
    edge = {1 / 32, 1 / 32, 1 / 32}
    old_min = Edicts.vector(server, pusher, "absmin")
    old_max = Edicts.vector(server, pusher, "absmax")
    box = {old_min |> Vec.add(move) |> Vec.sub(edge), old_max |> Vec.add(move) |> Vec.add(edge)}
    from = Edicts.vector(server, pusher, "origin")

    server =
      server
      |> Edicts.put(pusher, "origin", Vec.add(from, move))
      |> World.link(pusher, false)

    skip = Enum.map([:push, :none, :follow, :noclip, :angle_noclip], &Q.movetype/1)
    entities = Pushed.candidates(server, pusher, box, {old_min, old_max}, skip)
    each(server, %{pusher: pusher, move: move, from: from}, entities, [])
  end

  defp each(server, _push, [], _moved), do: {:ok, server}

  defp each(server, push, [entity | rest], moved) do
    {stuck?, server} = stuck_without?(server, push.pusher, entity)

    if stuck? do
      each(server, push, rest, moved)
    else
      origin = Edicts.vector(server, entity, "origin")

      case shove(server, push, entity, origin) do
        {:kept, server} -> each(server, push, rest, [{entity, origin} | moved])
        {:left, server} -> each(server, push, rest, moved)
        {:blocks, server} -> {:blocked, block(server, push, entity, [{entity, origin} | moved])}
      end
    end
  end

  defp shove(server, push, entity, origin) do
    server =
      if Edicts.int(server, entity, "groundentity") != push.pusher,
        do: Pushed.unground(server, entity),
        else: server

    moved_to = Vec.add(origin, push.move)
    nudged_to = Vec.add(moved_to, Vec.scale(push.move, 1 / 8 / Vec.length(push.move)))

    with {false, server} <- try_spot(server, push.pusher, entity, moved_to),
         {false, server} <- try_spot(server, push.pusher, entity, nudged_to) do
      stay(Edicts.put(server, entity, "origin", origin), push.pusher, entity)
    else
      {true, server} -> {:kept, World.link(server, entity, false)}
    end
  end

  defp stay(server, pusher, entity) do
    cond do
      not World.stuck?(server, entity) -> {:left, settle(server, entity)}
      Pushed.flat?(server, entity) -> {:kept, World.link(server, entity, false)}
      Pushed.soft?(server, entity) -> {:kept, Pushed.flatten(server, entity)}
      Pushed.liquid?(server, pusher) -> {:kept, server}
      true -> {:blocks, server}
    end
  end

  defp settle(server, entity) do
    if Edicts.int(server, entity, "movetype") != Q.movetype(:walk),
      do: Pushed.unground(server, entity),
      else: server
  end

  defp fits?(server, pusher, entity) do
    if Pushed.liquid?(server, pusher) do
      {stuck?, server} = stuck_without?(server, pusher, entity)
      {not stuck?, server}
    else
      {not World.stuck?(server, entity), server}
    end
  end

  defp try_spot(server, pusher, entity, origin) do
    server = Edicts.put(server, entity, "origin", origin)
    fits?(server, pusher, entity)
  end

  defp stuck_without?(server, pusher, entity) do
    solid = Edicts.float(server, pusher, "solid")
    server = Edicts.put(server, pusher, "solid", Q.solid(:not) / 1)
    stuck? = World.stuck?(server, entity)
    {stuck?, Edicts.put(server, pusher, "solid", solid)}
  end

  defp block(server, push, blocker, moved) do
    server =
      server
      |> Edicts.put(push.pusher, "origin", push.from)
      |> World.link(push.pusher, false)
      |> Pushed.blocked(push.pusher, blocker)

    Enum.reduce(moved, server, fn {entity, origin}, acc ->
      acc |> Edicts.put(entity, "origin", origin) |> World.link(entity, false)
    end)
  end
end
