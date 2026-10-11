defmodule QuakeServer.Builtins.Aim do
  @moduledoc """
  The `aim` builtin as FTE runs it (`PF_aim`): the direction a shot from `entity` should
  take, from its origin raised by its `view_ofs` height, given `v_forward`.

  The allowed deviation is the cosine `sv_aim`; at 1 or more aiming is off and
  `v_forward` comes back unchanged. Otherwise a target (`takedamage` 2, not on the
  shooter's `team` while `teamplay` is set and the team is above 0) straight ahead
  within 2048 units keeps `v_forward`; else the target whose centre lies closest to
  straight ahead, at least `sv_aim` by cosine and in clear sight, bends the shot: the
  forward direction scaled to the target's distance along it, with the target's height
  difference as its height, normalized. With no such target `v_forward` comes back.
  """

  alias Cauldron3D.Vec
  alias QuakeServer.{Edicts, Server, World}

  @aim_damage 2

  @doc "The aim direction for shots from `entity`."
  @spec aim(Server.t(), non_neg_integer()) :: Vec.t()
  def aim(%Server{} = server, entity) do
    forward = QuakeC.global_vector(server.qc, "v_forward")

    if Server.cvar(server, "sv_aim") >= 1,
      do: forward,
      else: aimed(server, entity, forward)
  end

  defp aimed(server, entity, forward) do
    {x, y, z} = Edicts.vector(server, entity, "origin")
    {_, _, height} = Edicts.vector(server, entity, "view_ofs")
    start = {x, y, z + height}
    ahead = sight(server, entity, start, Vec.madd(start, forward, 2048))

    if ahead != nil and target?(server, entity, ahead),
      do: forward,
      else: best(server, entity, start, forward)
  end

  defp best(server, entity, start, forward) do
    limit = Server.cvar(server, "sv_aim")

    found =
      Enum.reduce(1..(server.count - 1)//1, {limit, nil}, fn target, {closest, _} = acc ->
        with true <- target != entity and not Edicts.free?(server, target),
             true <- target?(server, entity, target),
             centre = centre(server, target),
             closeness = Vec.dot(Vec.normalize(Vec.sub(centre, start)), forward),
             true <- closeness >= closest,
             ^target <- sight(server, entity, start, centre) do
          {closeness, target}
        else
          _ -> acc
        end
      end)

    case found do
      {_, nil} -> forward
      {_, target} -> bend(server, entity, target, forward)
    end
  end

  defp bend(server, entity, target, forward) do
    to = Vec.sub(Edicts.vector(server, target, "origin"), Edicts.vector(server, entity, "origin"))
    {fx, fy, _} = Vec.scale(forward, Vec.dot(to, forward))
    {_, _, dz} = to
    Vec.normalize({fx, fy, dz})
  end

  defp centre(server, target) do
    Vec.add(
      Edicts.vector(server, target, "origin"),
      Vec.scale(
        Vec.add(Edicts.vector(server, target, "mins"), Edicts.vector(server, target, "maxs")),
        0.5
      )
    )
  end

  defp sight(server, entity, from, to),
    do: World.move(server, from, Vec.zero(), Vec.zero(), to, :normal, entity).hit

  defp target?(server, entity, target) do
    Edicts.float(server, target, "takedamage") == @aim_damage and
      not teammate?(server, entity, target)
  end

  defp teammate?(server, entity, target) do
    Server.cvar(server, "teamplay") != 0 and Edicts.float(server, entity, "team") > 0 and
      Edicts.float(server, entity, "team") == Edicts.float(server, target, "team")
  end
end
