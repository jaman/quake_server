defmodule QuakeServer.Precaches do
  @moduledoc """
  The server's sound list and particle effect list as FTE gives them to a player's
  client: the first time a player is sent them, the whole sound list as
  `svcfte_soundlistshort` and each effect as `svcfte_precache`, as FTE's signon does;
  after that every sound or effect added since, as `svcfte_precache`, as FTE sends a
  precache made while the level runs. All go into the player's reliable messages
  (`QuakeServer.Outbox`).

      server = QuakeServer.Precaches.send(server, 1)

  The sound list is the server's `sound_names`, index 0 the empty name; the effects are
  the host's `ext.effects` (`%{name => number}`, numbered from 1). What each player has
  been sent is kept in the host's `ext.precaches_sent`.

  The messages are `<<56, 0::little-16, name, 0, name, 0, ..., 0, 0>>` (the names from
  index 1, an empty name, then 0 for no more) and `<<77, code::little-16, name, 0>>`,
  `code` the index with bit 0x8000 set for a sound or bit 0x4000 for an effect.
  """

  import Bitwise

  alias QuakeServer.{Outbox, Server}

  @soundlist_short 56
  @precache 77
  @sound 0x8000
  @particle 0x4000

  @doc "Queue for `player` the sounds and effects it has not been sent."
  @spec send(Server.t(), pos_integer()) :: Server.t()
  def send(%Server{} = server, player) do
    sent = server.ext |> Map.get(:precaches_sent, %{}) |> Map.get(player)
    {messages, now} = messages(server, sent)

    server =
      Enum.reduce(messages, server, fn bytes, acc -> Outbox.reliable(acc, player, bytes) end)

    %{
      server
      | ext: Map.update(server.ext, :precaches_sent, %{player => now}, &Map.put(&1, player, now))
    }
  end

  defp messages(server, nil) do
    sounds = server.sound_names |> Enum.drop(1)
    list = <<@soundlist_short, 0::little-16>> <> Enum.map_join(sounds, &(&1 <> <<0>>)) <> <<0, 0>>
    effects = effects(server)
    effect_messages = Enum.map(effects, &precache(@particle, &1))
    {[list | effect_messages], %{sounds: length(server.sound_names), effects: numbers(effects)}}
  end

  defp messages(server, sent) do
    sounds =
      server.sound_names
      |> Enum.with_index()
      |> Enum.drop(sent.sounds)
      |> Enum.map(fn {name, index} -> precache(@sound, {name, index}) end)

    effects = server |> effects() |> Enum.reject(fn {_, n} -> MapSet.member?(sent.effects, n) end)

    {sounds ++ Enum.map(effects, &precache(@particle, &1)),
     %{
       sounds: length(server.sound_names),
       effects: MapSet.union(sent.effects, numbers(effects))
     }}
  end

  defp effects(server),
    do: server.ext |> Map.get(:effects, %{}) |> Enum.sort_by(&elem(&1, 1))

  defp numbers(effects), do: MapSet.new(effects, &elem(&1, 1))

  defp precache(kind, {name, index}),
    do: <<@precache, bor(index, kind)::little-16>> <> name <> <<0>>
end
