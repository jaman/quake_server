defmodule QuakeServer.Multicast do
  @moduledoc """
  FTE's `multicast` (`SV_MulticastProtExt`): the message a program built with
  `MSG_MULTICAST` goes to the players `to` names, each choosing as the player is when it
  is sent, into the player's reliable messages or datagram (`QuakeServer.Outbox`).

      server = QuakeServer.Multicast.send(server, origin, 1, bytes)

  `to` is 0 every player (`MULTICAST_ALL`), 1 those that may hear `origin`
  (`MULTICAST_PHS`), 2 those that may see it (`MULTICAST_PVS`), 3 to 5 the same sent
  reliably, 6 and 9 the player `msg_entity` names (`MULTICAST_ONE`), 7 and 10 the same
  sent reliably, and 8 every player reliably (`MULTICAST_INIT`). Another `to` is printed
  and the message dropped.

  A player hears `origin` when within 1024 units of it, or when the leaf of its eye
  (origin plus `view_ofs`) is in the PHS of `origin`'s leaf; with no PHS built
  (`phs?/1`) every player hears it. A player sees `origin` when its eye's leaf is in the
  PVS of `origin`'s leaf. A player whose eye is in leaf 0, or with `origin` in leaf 0,
  gets the message. Except for `msg_entity`'s player, a player whose `dimension_see`
  shares no bit with the program's `dimension_send` is left out.
  """

  import Bitwise

  alias Cauldron3D.{Bsp, Vec}
  alias QuakeServer.{Edicts, Events, Outbox, Server, Visibility}

  @earshot 1024

  @doc """
  Send `bytes` from `origin` to the players `to` names, those left out by dimension
  tested against `dimension` (the program's `dimension_send` when `nil`).
  """
  @spec send(Server.t(), Vec.t(), integer(), binary(), integer() | nil) :: Server.t()
  def send(server, origin, to, bytes, dimension \\ nil)

  def send(%Server{} = server, _origin, _to, <<>>, _dimension), do: server

  def send(%Server{} = server, origin, to, bytes, dimension) do
    mask = dimension || send_mask(server)

    case route(server, origin, to) do
      nil ->
        Events.print(server, :notify, "SV_Multicast: bad to:#{to}\n")

      {reliable?, reach} ->
        server
        |> Outbox.players()
        |> Enum.filter(&reaches?(server, &1, origin, reach, mask))
        |> Enum.reduce(server, &deliver(&2, &1, reliable?, bytes))
    end
  end

  @doc "Whether the server built a PHS for its map, as FTE decides under `sv_calcphs`."
  @spec phs?(Server.t()) :: boolean()
  def phs?(%Server{} = server) do
    single_player? = Server.cvar(server, "deathmatch") == 0 and Server.cvar(server, "coop") == 0
    Visibility.phs_built?(server.bsp, Server.cvar(server, "sv_calcphs"), single_player?)
  end

  defp route(_server, _origin, to) when to in [0, 3], do: {to == 3, :everyone}
  defp route(_server, _origin, 8), do: {true, :everyone}
  defp route(server, origin, to) when to in [1, 4], do: {to == 4, hearing(server, origin)}

  defp route(server, origin, to) when to in [2, 5],
    do: {to == 5, {:sight, Visibility.pvs(server.bsp, origin)}}

  defp route(server, _origin, to) when to in [6, 7, 9, 10],
    do: {to in [7, 10], {:one, trunc(QuakeC.float(QuakeC.global(server.qc, "msg_entity")))}}

  defp route(_server, _origin, _to), do: nil

  defp hearing(server, origin) do
    if phs?(server), do: {:hearing, Visibility.heard(server.bsp, origin)}, else: :everyone
  end

  defp reaches?(_server, player, _origin, {:one, one}, _mask), do: player == one

  defp reaches?(server, player, origin, reach, mask) do
    eye =
      Vec.add(Edicts.vector(server, player, "origin"), Edicts.vector(server, player, "view_ofs"))

    sees_dimension?(server, player, mask) and in_reach?(server, eye, origin, reach)
  end

  defp in_reach?(_server, _eye, _origin, :everyone), do: true
  defp in_reach?(_server, _eye, _origin, {_kind, :all}), do: true

  defp in_reach?(server, eye, origin, {:hearing, sight}),
    do: Vec.length(Vec.sub(origin, eye)) <= @earshot or in_leaf?(server, sight, eye)

  defp in_reach?(server, eye, _origin, {:sight, sight}), do: in_leaf?(server, sight, eye)

  defp in_leaf?(server, sight, eye) do
    case Bsp.leaf_at(server.bsp, eye) do
      0 -> true
      leaf -> (sight >>> leaf &&& 1) == 1
    end
  end

  defp send_mask(server) do
    if QuakeC.global?(server.qc, "dimension_send"),
      do: trunc(QuakeC.float(QuakeC.global(server.qc, "dimension_send"))),
      else: 255
  end

  defp sees_dimension?(server, player, send_mask) do
    see =
      if QuakeC.field_offset(server.qc, "dimension_see") == nil,
        do: 255,
        else: Edicts.int(server, player, "dimension_see")

    (see &&& send_mask) != 0
  end

  defp deliver(server, player, true, bytes), do: Outbox.reliable(server, player, bytes)
  defp deliver(server, player, false, bytes), do: Outbox.unreliable(server, player, bytes)
end
