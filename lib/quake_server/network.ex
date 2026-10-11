defmodule QuakeServer.Network do
  @moduledoc """
  FTE's delivery of the entities a program sends itself (`SendEntity`) to the client
  programs of the players watching (`sv_ents.c`).

      server = QuakeServer.Network.watch(server, 1)
      {%{1 => updates}, server} = QuakeServer.Network.frame(server, [1])
      updates #=> [{:update, 37, <<...>>}, {:remove, 40}]

  `frame/2` runs once a server frame (`SV_SendClientMessages`). First every watching
  player keeps the bits of each live entity's `SendFlags` (`SV_ProcessSendFlags`). Then
  each player being sent a packet is first given the sounds and particle effects it lacks
  (`QuakeServer.Precaches`), then its updates (`SV_EmitCSQCUpdate`): for each
  entity with a `SendEntity` the player may see, in order, that function runs with `self`
  the entity and as parameters the player and the kept bits in three 24-bit pieces (an
  entity the player does not have gets every bit), and what it writes to `MSG_ENTITY` is
  the update when it returns true. An entity the player has is removed when its function
  returns false, or when it is no longer among those the player may see, either unless
  its `pvsflags` has bit 128 (`PVSF_NOREMOVE`); one the player has whose bits are
  unchanged is passed over. Last `SendFlags` is cleared (`SV_CleanupEnts`) up to the
  highest entity that had some, and an entity whose `Version` differs from the count the
  server keeps for it (`QuakeServer.Edicts.free/2` counts it up) gets `SendFlags` -1.
  Nothing is kept until a player watches.

  The player may see an entity (`SV_Snapshot_BuildQ1`) when it is live, its
  `customizeentityforclient` (run with `self` it and `other` the player) returns true
  where it has one, and:

    * it is the player or the player's `view2`, or its `viewmodelforclient` is the
      player; otherwise, with no `viewmodelforclient`, its effects have `EF_NODEPTHTEST`
      (8192), its `pvsflags` low bits are 3 (`PVSF_IGNOREPVS`), or 2 (`PVSF_USEPHS`)
      except on a Quake map with a PHS built (`QuakeServer.Multicast.phs?/1`), where its
      origin must be where the player's origin can be heard
      (`QuakeServer.Visibility.heard/2`); or else it touches a leaf of
      the player's fat PVS (`QuakeServer.Visibility.fat/2` at the player's eye and at
      its `view2`), the entity at the end of its `tag_entity` chain (up to ten long)
      standing in for it, which passes as the player and fails as another player's
      `viewmodelforclient`;
    * its `nodrawtoclient` is not the player, and its `drawonlytoclient` is none or the
      player;
    * the player's `dimension_see` shares a bit with its `dimension_seen` or
      `dimension_ghost`, unless it is the player or the player's `view2`. Undeclared,
      `dimension_see` and `dimension_seen` read as 255.
  """

  import Bitwise

  alias Cauldron3D.Vec
  alias QuakeC.Exec
  alias QuakeServer.{Edicts, Multicast, Precaches, Server, Visibility}

  @present 1
  @shift 2
  @every bnot(3)
  @piece 0xFFFFFF
  @no_remove 128
  @no_depth_test 8192
  @use_phs 2
  @ignore_pvs 3
  @tag_depth 10

  @typedoc "An entity sent to a player, or taken away."
  @type update :: {:update, pos_integer(), binary()} | {:remove, pos_integer()}

  @doc "Start keeping entity bits for player `viewer`."
  @spec watch(Server.t(), non_neg_integer()) :: Server.t()
  def watch(%Server{} = server, viewer),
    do: put_viewers(server, Map.put_new(viewers(server), viewer, %{}))

  @doc "The entities player `viewer` has been sent and still has, in order."
  @spec held(Server.t(), non_neg_integer()) :: [pos_integer()]
  def held(%Server{} = server, viewer) do
    server
    |> viewers()
    |> Map.get(viewer, %{})
    |> Enum.filter(fn {_entity, bits} -> (bits &&& @present) != 0 end)
    |> Enum.map(fn {entity, _bits} -> entity end)
    |> Enum.sort()
  end

  @doc """
  Run a server frame's delivery: keep the bits for every watching player, give the
  updates for each watching player in `sending`, and clear `SendFlags`.
  """
  @spec frame(Server.t(), [non_neg_integer()]) ::
          {%{non_neg_integer() => [update()]}, Server.t()}
  def frame(%Server{} = server, sending) do
    flags_offset = QuakeC.field_offset(server.qc, "SendFlags")

    if viewers(server) == %{} do
      {%{}, server}
    else
      flagged = flagged(server, flags_offset)
      server = bank(server, flagged)

      {updates, server} =
        sending
        |> Enum.filter(&Map.has_key?(viewers(server), &1))
        |> Enum.map_reduce(server, fn viewer, acc ->
          {updates, acc} = acc |> Precaches.send(viewer) |> emit(viewer)
          {{viewer, updates}, acc}
        end)

      {Map.new(updates), clean(server, flags_offset, flagged)}
    end
  end

  defp viewers(server), do: Map.get(server.ext, :network, %{})
  defp put_viewers(server, viewers), do: %{server | ext: Map.put(server.ext, :network, viewers)}

  defp flagged(_server, nil), do: []

  defp flagged(server, offset) do
    for entity <- 1..(server.count - 1)//1,
        not Edicts.free?(server, entity),
        flags = whole(QuakeC.field_slot(server.qc, entity, offset)),
        flags != 0,
        do: {entity, flags <<< @shift}
  end

  defp bank(server, []), do: server

  defp bank(server, flagged) do
    viewers =
      Map.new(viewers(server), fn {viewer, bits} ->
        {viewer,
         Enum.reduce(flagged, bits, fn {entity, flags}, acc ->
           Map.update(acc, entity, flags, &(&1 ||| flags))
         end)}
      end)

    put_viewers(server, viewers)
  end

  defp clean(server, _offset, []), do: server

  defp clean(server, offset, flagged) do
    {highest, _} = List.last(flagged)
    version_offset = QuakeC.field_offset(server.qc, "Version")

    Enum.reduce(1..highest, server, fn entity, acc ->
      acc = %{acc | qc: QuakeC.put_field_slot(acc.qc, entity, offset, 0.0)}
      check_version(acc, entity, offset, version_offset)
    end)
  end

  defp check_version(server, _entity, _offset, nil), do: server

  defp check_version(server, entity, offset, version_offset) do
    version = whole(QuakeC.field_slot(server.qc, entity, version_offset))

    if version == Map.get(server.versions, entity, 1) do
      server
    else
      %{
        server
        | qc: QuakeC.put_field_slot(server.qc, entity, offset, -1.0),
          versions: Map.put(server.versions, entity, version)
      }
    end
  end

  defp emit(server, viewer) do
    case QuakeC.field_offset(server.qc, "SendEntity") do
      nil ->
        {[], server}

      send_offset ->
        {server, visible} = visible(server, viewer, send_offset)

        delivery = %{
          server: server,
          bits: Map.fetch!(viewers(server), viewer),
          updates: [],
          next: 0,
          viewer: viewer,
          send_offset: send_offset
        }

        delivery =
          visible
          |> Enum.reduce(delivery, &(&2 |> removes(&1) |> send_entity(&1)))
          |> removes(delivery.server.count)

        server =
          put_viewers(delivery.server, Map.put(viewers(delivery.server), viewer, delivery.bits))

        {Enum.reverse(delivery.updates), server}
    end
  end

  defp removes(delivery, upto) do
    delivery =
      Enum.reduce(delivery.next..(upto - 1)//1, delivery, fn entity, acc ->
        if present?(acc.bits, entity) and not no_remove?(acc.server, entity),
          do: remove(acc, entity),
          else: acc
      end)

    %{delivery | next: upto + 1}
  end

  defp remove(delivery, entity),
    do: %{
      delivery
      | bits: Map.delete(delivery.bits, entity),
        updates: [{:remove, entity} | delivery.updates]
    }

  defp send_entity(delivery, entity) do
    case Map.get(delivery.bits, entity, 0) do
      @present -> delivery
      bits -> run_send(delivery, entity, if((bits &&& @present) == 0, do: @every, else: bits))
    end
  end

  defp run_send(delivery, entity, bits) do
    {server, bytes, sent?} = call_send(delivery, entity, bits)
    delivery = %{delivery | server: server, bits: Map.delete(delivery.bits, entity)}

    cond do
      sent? ->
        %{
          delivery
          | bits: Map.put(delivery.bits, entity, @present),
            updates: [{:update, entity, bytes} | delivery.updates]
        }

      (bits &&& @present) != 0 and not no_remove?(server, entity) ->
        %{delivery | updates: [{:remove, entity} | delivery.updates]}

      true ->
        delivery
    end
  end

  defp call_send(%{server: server, viewer: viewer} = delivery, entity, bits) do
    function = whole(QuakeC.field_slot(server.qc, entity, delivery.send_offset))
    [low, middle, high] = for shift <- [0, 24, 48], do: (bits >>> (@shift + shift) &&& @piece) / 1

    qc =
      server.qc
      |> QuakeC.put_slot(4, viewer)
      |> QuakeC.put_slot(7, low)
      |> QuakeC.put_slot(8, middle)
      |> QuakeC.put_slot(9, high)
      |> QuakeC.put_global("self", entity)

    server = %{server | qc: qc, ext: Map.put(server.ext, :entity, <<>>)}
    server = Exec.call(server, function, server.builtins, Server.exec_opts(server))
    {bytes, ext} = Map.pop(server.ext, :entity, <<>>)
    {%{server | ext: ext}, bytes, returned_true?(QuakeC.slot(server.qc, 1))}
  end

  defp visible(server, viewer, send_offset) do
    view = %{
      viewer: viewer,
      cameras: cameras(server, viewer),
      sight: sight(server, viewer),
      heard: heard(server, viewer)
    }

    {server, entities} =
      Enum.reduce(1..(server.count - 1)//1, {server, []}, fn entity, {acc, entities} ->
        considered(acc, entities, entity, view, send_offset)
      end)

    {server, Enum.reverse(entities)}
  end

  defp considered(server, entities, entity, view, send_offset) do
    with false <- Edicts.free?(server, entity),
         {true, server} <- customized(server, entity, view.viewer) do
      {server, sent(server, entities, entity, view, send_offset)}
    else
      true -> {server, entities}
      {false, server} -> {server, entities}
    end
  end

  defp sent(server, entities, entity, view, send_offset) do
    if shown?(server, entity, view) and
         whole(QuakeC.field_slot(server.qc, entity, send_offset)) != 0,
       do: [entity | entities],
       else: entities
  end

  defp customized(server, entity, viewer) do
    case Edicts.int(server, entity, "customizeentityforclient") do
      0 ->
        {true, server}

      function ->
        qc = server.qc |> QuakeC.put_global("self", entity) |> QuakeC.put_global("other", viewer)
        server = %{server | qc: qc}
        server = Exec.call(server, function, server.builtins, Server.exec_opts(server))
        {QuakeC.float(QuakeC.slot(server.qc, 1)) != 0, server}
    end
  end

  defp shown?(server, entity, view) do
    camera? = entity in view.cameras

    culled_in?(server, entity, view, camera?) and drawn_for?(server, entity, view.viewer) and
      (camera? or dimension_shared?(server, entity, view.viewer))
  end

  defp culled_in?(_server, _entity, _view, true), do: true

  defp culled_in?(server, entity, view, false) do
    case Edicts.int(server, entity, "viewmodelforclient") do
      0 -> in_view?(server, entity, view)
      owner -> owner == view.viewer
    end
  end

  defp in_view?(server, entity, view) do
    mode = Edicts.int(server, entity, "pvsflags") &&& 3

    cond do
      (Edicts.int(server, entity, "effects") &&& @no_depth_test) != 0 -> true
      mode < @use_phs -> in_sight?(server, entity, view)
      mode == @use_phs and server.bsp.game == :quake -> heard?(server, entity, view)
      mode == @use_phs -> true
      mode == @ignore_pvs -> true
    end
  end

  defp in_sight?(server, entity, view) do
    if Edicts.int(server, entity, "tag_entity") == 0,
      do: leaves_seen?(server, entity, view),
      else: root_seen?(server, root(server, entity, @tag_depth), view)
  end

  defp root_seen?(_server, root, %{viewer: root}), do: true

  defp root_seen?(server, root, view) do
    case Edicts.int(server, root, "viewmodelforclient") do
      0 -> leaves_seen?(server, root, view)
      owner -> owner == view.viewer
    end
  end

  defp root(_server, entity, 0), do: entity

  defp root(server, entity, depth) do
    case Edicts.int(server, entity, "tag_entity") do
      0 -> entity
      parent -> root(server, parent, depth - 1)
    end
  end

  defp leaves_seen?(server, entity, view),
    do: Visibility.seen?(view.sight, Map.get(server.leaves, entity, []))

  defp heard?(server, entity, view),
    do: Visibility.point_seen?(server.bsp, view.heard, Edicts.vector(server, entity, "origin"))

  defp drawn_for?(server, entity, viewer) do
    hidden_from = Edicts.int(server, entity, "nodrawtoclient")
    only_for = Edicts.int(server, entity, "drawonlytoclient")
    hidden_from != viewer and (only_for == 0 or only_for == viewer)
  end

  defp dimension_shared?(server, entity, viewer) do
    see = dimension(server, viewer, "dimension_see", 255)
    seen = dimension(server, entity, "dimension_seen", 255)
    ghost = dimension(server, entity, "dimension_ghost", 0)
    (see &&& (seen ||| ghost)) != 0
  end

  defp dimension(server, entity, name, undeclared) do
    if QuakeC.field_offset(server.qc, name) == nil,
      do: undeclared,
      else: Edicts.int(server, entity, name)
  end

  defp cameras(server, viewer) do
    case Edicts.int(server, viewer, "view2") do
      0 -> [viewer]
      other -> [viewer, other]
    end
  end

  defp sight(server, viewer) do
    eye =
      Vec.add(Edicts.vector(server, viewer, "origin"), Edicts.vector(server, viewer, "view_ofs"))

    own = Visibility.fat(server.bsp, eye)

    case Edicts.int(server, viewer, "view2") do
      0 -> own
      other -> merge(own, Visibility.fat(server.bsp, Edicts.vector(server, other, "origin")))
    end
  end

  defp merge(:all, _other), do: :all
  defp merge(_own, :all), do: :all
  defp merge(own, other), do: own ||| other

  defp heard(%Server{bsp: %{game: :quake}} = server, viewer) do
    if Multicast.phs?(server),
      do: Visibility.heard(server.bsp, Edicts.vector(server, viewer, "origin")),
      else: :all
  end

  defp heard(_server, _viewer), do: :all

  defp present?(bits, entity), do: (Map.get(bits, entity, 0) &&& @present) != 0

  defp no_remove?(server, entity),
    do: (Edicts.int(server, entity, "pvsflags") &&& @no_remove) != 0

  defp returned_true?(value) when is_integer(value), do: value != 0

  defp returned_true?(value) when is_float(value),
    do: <<value::float-64>> != <<0.0::float-64>>

  defp returned_true?(_value), do: true

  defp whole(value) when is_integer(value), do: value
  defp whole(value) when is_float(value), do: trunc(value)
  defp whole(_value), do: 0
end
