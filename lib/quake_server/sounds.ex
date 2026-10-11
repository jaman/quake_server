defmodule QuakeServer.Sounds do
  @moduledoc """
  A sound started on the server, as FTE starts one (`SVQ1_StartSound`, `SV_StartSound`):
  it goes to the players as a sound message (`QuakeServer.Multicast`) and to the server's
  events as `{:sound, %{entity:, channel:, name:, volume:, attenuation:, origin:,
  pitch:}}`.

      server = QuakeServer.Sounds.start(server, entity, 1, "weapons/rocket1i.wav", 1.0, 1.0)

  Without `:origin`, a brush entity's sound (solid 4 or 22) comes from the middle of its
  box and is sent reliably; another entity's comes from its origin under a QuakeWorld
  program and from the middle of its box otherwise. A reliable sound, or one with
  attenuation 0, goes to every player; others to the players that may hear `origin`. Flag
  1 (`CF_SV_RELIABLE`) sends reliably, flag 256 (`CF_SV_UNICAST`) to `msg_entity`'s
  player only. A sound not precached is sent reliably after a printed warning. Volume
  below 0 or above 1, or a channel outside 0 to 255, is printed and dropped; an empty
  name is dropped.

  The message is `<<6, flags::little-16, entity::little-signed-32, channel::little-16,
  volume, attenuation::little-float-32, pitch::little-float-32,
  timeofs::little-float-32, x, y, z (little-float-32), name, 0>>`, `pitch` a playback
  rate with 0 meaning 1.
  """

  alias Cauldron3D.Vec
  alias QuakeServer.{Edicts, Events, Models, Multicast, Q, Server}

  @svc_sound 6
  @reliable 1
  @unicast 256

  @doc """
  Start `name` from `entity` on `channel` at `volume` (0.0 to 1.0) with `attenuation`.
  Options: `:pitch` (a rate, 0 meaning 1), `:flags`, `:timeofs` (seconds into the
  sound), `:origin` (a fixed place).
  """
  @spec start(Server.t(), integer(), integer(), String.t() | nil, number(), number(), keyword()) ::
          Server.t()
  def start(%Server{} = server, entity, channel, name, volume, attenuation, opts \\ []) do
    {origin, flags} =
      place(server, entity, Keyword.get(opts, :origin), Keyword.get(opts, :flags, 0))

    volume = round(volume * 255)

    cond do
      volume < 0 or volume > 255 ->
        Events.print(server, :notify, "SV_StartSound: volume = #{volume}")

      channel < 0 or channel > 255 ->
        Events.print(server, :notify, "SV_StartSound: channel = #{channel}")

      name == "" ->
        server

      true ->
        sound = %{
          entity: entity,
          channel: channel,
          name: name,
          volume: volume,
          attenuation: attenuation,
          origin: origin,
          flags: flags
        }

        send_sound(server, sound, opts)
    end
  end

  defp place(server, entity, nil, flags) do
    solid = Edicts.int(server, entity, "solid")
    origin = Edicts.vector(server, entity, "origin")

    middle =
      Vec.add(
        origin,
        Vec.scale(
          Vec.add(Edicts.vector(server, entity, "mins"), Edicts.vector(server, entity, "maxs")),
          0.5
        )
      )

    cond do
      solid in [Q.solid(:bsp), 22] -> {middle, Bitwise.bor(flags, @reliable)}
      server.qc.progs.crc == 54_730 -> {origin, flags}
      true -> {middle, flags}
    end
  end

  defp place(_server, _entity, origin, flags), do: {origin, flags}

  defp send_sound(server, sound, opts) do
    %{entity: entity, channel: channel, name: name, volume: volume} = sound
    %{attenuation: attenuation, origin: origin} = sound
    {server, flags} = precached(server, name, sound.flags)
    reliable? = Bitwise.band(flags, @reliable) != 0
    pitch = Keyword.get(opts, :pitch, 0.0) / 1
    timeofs = Keyword.get(opts, :timeofs, 0.0) / 1
    {x, y, z} = origin

    bytes =
      <<@svc_sound, Bitwise.band(flags, 0xFFFF)::little-16, entity::little-signed-32,
        channel::little-16, volume, attenuation / 1::little-float-32, pitch::little-float-32,
        timeofs::little-float-32, x / 1::little-float-32, y / 1::little-float-32,
        z / 1::little-float-32>> <> (name || "") <> <<0>>

    server
    |> Multicast.send(origin, to(flags, reliable?, attenuation), bytes, dimension(server, entity))
    |> Server.emit(
      {:sound,
       %{
         entity: entity,
         channel: channel,
         name: name,
         volume: volume / 255,
         attenuation: attenuation / 1,
         origin: origin,
         pitch: pitch
       }}
    )
  end

  defp to(flags, reliable?, attenuation) do
    cond do
      Bitwise.band(flags, @unicast) != 0 -> if reliable?, do: 7, else: 6
      reliable? or attenuation == 0 -> if reliable?, do: 3, else: 0
      true -> 1
    end
  end

  defp precached(server, nil, flags), do: {server, flags}

  defp precached(server, name, flags) do
    if name in server.sound_names,
      do: {server, flags},
      else:
        {server
         |> Events.print(:notify, "WARNING: SV_StartSound: sound #{name} not precached\n")
         |> Models.precache_sound(name), Bitwise.bor(flags, @reliable)}
  end

  defp dimension(server, entity) do
    if QuakeC.field_offset(server.qc, "dimension_seen") == nil,
      do: 255,
      else: Edicts.int(server, entity, "dimension_seen")
  end
end
