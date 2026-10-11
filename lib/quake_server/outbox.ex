defmodule QuakeServer.Outbox do
  @moduledoc """
  What the server holds for each player until the player's next packet, as FTE keeps it
  for a client: the reliable messages (`MSG_ONE`, reliable multicasts, prints), the
  datagram (unreliable multicasts), and the last centerprint, which goes out with the
  next packet after the reliable messages queued before it.

      server = QuakeServer.Outbox.print(server, 1, 2, "You got the shotgun\\n")
      {%{reliable: [_], datagram: []}, server} = QuakeServer.Outbox.take(server, 1)

  Each message is a binary of whole server messages, opening with its `svc` byte. The
  players are the entities 1 to the server's `slots` once a player has connected.
  """

  alias QuakeServer.Server

  @svc_print 8
  @svc_centerprint 26

  @typedoc "A player's messages, oldest first."
  @type packet :: %{reliable: [binary()], datagram: [binary()]}

  @doc "The connected players."
  @spec players(Server.t()) :: [pos_integer()]
  def players(%Server{parms: nil}), do: []
  def players(%Server{slots: slots}), do: Enum.to_list(1..slots//1)

  @doc "Queue `bytes` reliably for `player`."
  @spec reliable(Server.t(), pos_integer(), binary()) :: Server.t()
  def reliable(%Server{} = server, player, bytes),
    do: update(server, player, &%{&1 | reliable: [bytes | &1.reliable]})

  @doc "Add `bytes` to `player`'s datagram."
  @spec unreliable(Server.t(), pos_integer(), binary()) :: Server.t()
  def unreliable(%Server{} = server, player, bytes),
    do: update(server, player, &%{&1 | datagram: [bytes | &1.datagram]})

  @doc "Queue `text` reliably for `player` as a print of `level` (`svc_print`)."
  @spec print(Server.t(), pos_integer(), integer(), String.t()) :: Server.t()
  def print(%Server{} = server, player, level, text),
    do: reliable(server, player, <<@svc_print, Bitwise.band(level, 0xFF)>> <> text <> <<0>>)

  @doc "Make `text` the centerprint `player` gets with the next packet, replacing one waiting."
  @spec centerprint(Server.t(), pos_integer(), String.t()) :: Server.t()
  def centerprint(%Server{} = server, player, text),
    do: update(server, player, &%{&1 | centerprint: text})

  @doc "Take `player`'s packet: the reliable messages, then the waiting centerprint, and the datagram."
  @spec take(Server.t(), pos_integer()) :: {packet(), Server.t()}
  def take(%Server{} = server, player) do
    box = box(server, player)

    centerprint =
      if box.centerprint, do: [<<@svc_centerprint>> <> box.centerprint <> <<0>>], else: []

    packet = %{
      reliable: Enum.reverse(box.reliable, centerprint),
      datagram: Enum.reverse(box.datagram)
    }

    {packet, put_box(server, player, empty())}
  end

  defp update(server, player, change), do: put_box(server, player, change.(box(server, player)))

  defp box(server, player), do: server.ext |> Map.get(:outbox, %{}) |> Map.get(player, empty())

  defp put_box(server, player, box),
    do: %{
      server
      | ext: Map.update(server.ext, :outbox, %{player => box}, &Map.put(&1, player, box))
    }

  defp empty, do: %{reliable: [], datagram: [], centerprint: nil}
end
