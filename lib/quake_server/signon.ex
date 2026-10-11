defmodule QuakeServer.Signon do
  @moduledoc """
  The messages FTE sends a client after the level's model and sound lists and before the
  client begins (`SV_SendClientPrespawnInfo`, `SVQW_Spawn_f`): the static entities
  (`makestatic`), oldest first, then the static sounds (`ambientsound`), then each player
  slot's info keys.

      [message | _] = QuakeServer.Signon.messages(server)

  Each is a binary holding one server message:

    * a static entity: `svc_spawnstatic` (20), the index of its model in the server's
      model list in 16 bits, its frame, colormap (0) and skin as bytes, then for each axis
      its origin's coordinate and its angle
    * a static sound: `svc_spawnstaticsound` (29), its origin's three coordinates, the
      index of its sound in the server's sound list as a byte, the volume × 255 and the
      attenuation × 64 as bytes; a sound past index 255 is `svcfte_spawnstaticsound2`
      (94) with a flags byte of 1 and the index in 16 bits after the coordinates. A sound
      not in the sound list is left out, as FTE's `ambientsound` leaves it.
    * a player slot's info: `svc_updateuserinfo` (40), the slot (the entity less one), the
      user id (the entity) in 32 bits, and the info string, `\\key\\value` for each key in
      order, with `name` as `QuakeServer.Server.player_name/2` gives it

  Coordinates and angles are written as the server's `coords` sets
  (`QuakeServer.Builtins.Write`): 32-bit floats and 65536ths of a turn in 16 bits, or
  eighths of a unit in 16 bits and 256ths of a turn in a byte.
  """

  import Bitwise

  alias QuakeServer.{Models, Server}

  @svc_spawnstatic 20
  @svc_spawnstaticsound 29
  @svc_updateuserinfo 40
  @svcfte_spawnstaticsound2 94

  @doc "The server's static entities, static sounds and player info, as messages in that order."
  @spec messages(Server.t()) :: [binary()]
  def messages(%Server{} = server) do
    statics = server.statics |> Enum.reverse() |> Enum.flat_map(&static(server, &1))
    sounds = server.ambients |> Enum.reverse() |> Enum.flat_map(&static_sound(server, &1))
    statics ++ sounds ++ Enum.map(1..server.slots//1, &player_info(server, &1))
  end

  defp static(server, static) do
    case Models.index(server, static.model) do
      index when is_integer(index) and index > 0 ->
        [
          <<@svc_spawnstatic, index::little-16, band(static.frame, 0xFF), 0,
            band(static.skin, 0xFF)>> <> placement(server, static.origin, static.angles)
        ]

      _ ->
        []
    end
  end

  defp placement(server, {x, y, z}, {pitch, yaw, roll}) do
    coord(server, x) <>
      angle(server, pitch) <>
      coord(server, y) <> angle(server, yaw) <> coord(server, z) <> angle(server, roll)
  end

  defp static_sound(server, ambient) do
    case Enum.find_index(server.sound_names, &(&1 == ambient.name)) do
      nil -> []
      0 -> []
      index -> [sound_message(server, ambient, index)]
    end
  end

  defp sound_message(server, ambient, index) when index > 255 do
    <<@svcfte_spawnstaticsound2, 1>> <>
      origin(server, ambient.origin) <> <<index::little-16>> <> levels(ambient)
  end

  defp sound_message(server, ambient, index),
    do:
      <<@svc_spawnstaticsound>> <> origin(server, ambient.origin) <> <<index>> <> levels(ambient)

  defp levels(ambient),
    do: <<byte(ambient.volume * 255), byte(ambient.attenuation * 64)>>

  defp byte(value), do: value |> trunc() |> max(0) |> min(255)

  defp origin(server, {x, y, z}), do: coord(server, x) <> coord(server, y) <> coord(server, z)

  defp player_info(server, player) do
    info =
      server.ext
      |> Map.get(:userinfo, %{})
      |> Map.get(player, %{})
      |> Map.put_new("name", Server.player_name(server, player))
      |> Enum.reject(fn {_key, value} -> value == "" end)
      |> Enum.sort()
      |> Enum.map_join(fn {key, value} -> "\\" <> key <> "\\" <> value end)

    <<@svc_updateuserinfo, player - 1, player::little-32>> <> info <> <<0>>
  end

  defp coord(%Server{coords: :float}, value), do: <<value / 1::little-float-32>>
  defp coord(_server, value), do: <<round(value * 8)::little-signed-16>>

  defp angle(%Server{coords: :float}, value),
    do: <<band(round(value * 65_536 / 360), 0xFFFF)::little-16>>

  defp angle(_server, value), do: <<band(round(value * 256 / 360), 0xFF)>>
end
