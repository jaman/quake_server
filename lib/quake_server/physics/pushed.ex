defmodule QuakeServer.Physics.Pushed do
  @moduledoc """
  What FTE's two pushes share (`QuakeServer.Physics.Push` and
  `QuakeServer.Physics.PushTurn`): which entities a pusher's move reaches, the pusher's
  `blocked` call, and putting moved entities back.

  An entity is a candidate when it is not freed, its move type lets it be pushed, and it
  either stands on the pusher or overlaps the pusher's new box and is stuck there.
  """

  import Bitwise

  alias Cauldron3D.Vec
  alias QuakeServer.{Edicts, Q, Server, World}

  @onground 512

  @doc """
  The entities `pusher`'s move may reach, by number, whose move type is not in `skip`:
  those standing on it, and those overlapping box `{mins, maxs}` (the pusher's new box)
  that are stuck there. `{old_min, old_max}` is the pusher's box before it moved.
  """
  @spec candidates(Server.t(), non_neg_integer(), {tuple(), tuple()}, {tuple(), tuple()}, [
          integer()
        ]) :: [
          non_neg_integer()
        ]
  def candidates(server, pusher, {mins, maxs} = box, {old_min, old_max}, skip) do
    reach = {Vec.min(mins, old_min), Vec.max(maxs, old_max)}

    server
    |> World.near(reach)
    |> MapSet.delete(pusher)
    |> MapSet.delete(0)
    |> Enum.sort()
    |> Enum.filter(&candidate?(server, pusher, box, skip, &1))
  end

  @doc "Whether `entity` stands on `pusher`."
  @spec rider?(Server.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def rider?(server, pusher, entity),
    do: on_ground?(server, entity) and Edicts.int(server, entity, "groundentity") == pusher

  @doc "Clear `entity`'s on-ground flag."
  @spec unground(Server.t(), non_neg_integer()) :: Server.t()
  def unground(server, entity) do
    flags = Edicts.int(server, entity, "flags")
    Edicts.put(server, entity, "flags", band(flags, bnot(@onground)) / 1)
  end

  @doc "Whether `entity` is a box with no width, which a pusher never blocks on."
  @spec flat?(Server.t(), non_neg_integer()) :: boolean()
  def flat?(server, entity),
    do:
      elem(Edicts.vector(server, entity, "mins"), 0) ==
        elem(Edicts.vector(server, entity, "maxs"), 0)

  @doc "Whether `entity` is not solid or a box trigger: flattened rather than blocking."
  @spec soft?(Server.t(), non_neg_integer()) :: boolean()
  def soft?(server, entity),
    do: Edicts.int(server, entity, "solid") in [Q.solid(:not), Q.solid(:trigger)]

  @doc "Flatten `entity` to a point at its feet and relink it."
  @spec flatten(Server.t(), non_neg_integer()) :: Server.t()
  def flatten(server, entity) do
    {_, _, z} = Edicts.vector(server, entity, "mins")

    server
    |> Edicts.put(entity, "mins", {0.0, 0.0, z})
    |> Edicts.put(entity, "maxs", {0.0, 0.0, z})
    |> World.link(entity, false)
  end

  @doc "Run `pusher`'s `blocked` with `other` as `other`, keeping `self` and `other` as they were."
  @spec blocked(Server.t(), non_neg_integer(), non_neg_integer()) :: Server.t()
  def blocked(server, pusher, other) do
    case Edicts.int(server, pusher, "blocked") do
      0 -> %{server | qc: QuakeC.put_global(server.qc, "other", 0)}
      function -> Server.keeping_self(server, &Server.run(&1, function, pusher, other))
    end
  end

  @doc "Whether `pusher` is a liquid brush (negative `skin`), which moves things but never blocks."
  @spec liquid?(Server.t(), non_neg_integer()) :: boolean()
  def liquid?(server, pusher), do: Edicts.float(server, pusher, "skin") < 0

  @doc "Whether `entity` stands somewhere."
  @spec on_ground?(Server.t(), non_neg_integer()) :: boolean()
  def on_ground?(server, entity), do: band(Edicts.int(server, entity, "flags"), @onground) != 0

  defp candidate?(server, pusher, {mins, maxs}, skip, entity) do
    cond do
      Edicts.free?(server, entity) -> false
      Edicts.int(server, entity, "movetype") in skip -> false
      rider?(server, pusher, entity) -> true
      not overlap?(server, entity, mins, maxs) -> false
      true -> World.stuck?(server, entity)
    end
  end

  defp overlap?(server, entity, {x0, y0, z0}, {x1, y1, z1}) do
    {ax0, ay0, az0} = Edicts.vector(server, entity, "absmin")
    {ax1, ay1, az1} = Edicts.vector(server, entity, "absmax")
    not (ax0 >= x1 or ay0 >= y1 or az0 >= z1 or ax1 <= x0 or ay1 <= y0 or az1 <= z0)
  end
end
