defmodule QuakeServer.Messages do
  @moduledoc """
  The bytes a QuakeC program writes with `WriteByte` and the rest, read back into
  events for the client.

      QuakeServer.Messages.decode(bytes)
      #=> [{:temp, :explosion, %{origin: {...}}}, :intermission, ...]

  Coordinates are written as eighths of a unit in 16 bits and angles as 256ths of a
  turn in a byte, as Quake writes them. Reading stops at a message it does not know.
  """

  @temps %{
    0 => :spike,
    1 => :superspike,
    2 => :gunshot,
    3 => :explosion,
    4 => :tarexplosion,
    5 => :lightning1,
    6 => :lightning2,
    7 => :wizspike,
    8 => :knightspike,
    9 => :lightning3,
    10 => :lavasplash,
    11 => :teleport,
    12 => :explosion2,
    13 => :beam
  }

  @doc "The events in `bytes`, in order."
  @spec decode(binary()) :: [term()]
  def decode(bytes), do: decode(bytes, [])

  defp decode(<<>>, acc), do: Enum.reverse(acc)

  defp decode(<<23, type, rest::binary>>, acc) do
    case temp(Map.get(@temps, type), rest) do
      {event, rest} -> decode(rest, [event | acc])
      :error -> Enum.reverse(acc)
    end
  end

  defp decode(<<30, rest::binary>>, acc), do: decode(rest, [:intermission | acc])
  defp decode(<<33, rest::binary>>, acc), do: decode(rest, [:sellscreen | acc])
  defp decode(<<27, rest::binary>>, acc), do: decode(rest, [:killed_monster | acc])
  defp decode(<<28, rest::binary>>, acc), do: decode(rest, [:found_secret | acc])

  defp decode(<<32, track, loop, rest::binary>>, acc),
    do: decode(rest, [{:cd_track, track, loop} | acc])

  defp decode(<<3, stat, value::little-signed-32, rest::binary>>, acc),
    do: decode(rest, [{:stat, stat, value} | acc])

  defp decode(<<command, rest::binary>>, acc) when command in [8, 9, 26, 31] do
    {text, rest} = string(rest)
    decode(rest, [text_event(command, text) | acc])
  end

  defp decode(<<10, rest::binary>>, acc) do
    case angles(rest) do
      {angles, rest} -> decode(rest, [{:set_angles, angles} | acc])
      :error -> Enum.reverse(acc)
    end
  end

  defp decode(_unknown, acc), do: Enum.reverse(acc)

  defp text_event(8, text), do: {:print, :notify, text}
  defp text_event(9, text), do: {:stuff, text}
  defp text_event(26, text), do: {:print, :center, text}
  defp text_event(31, text), do: {:finale, text}

  defp temp(type, rest) when type in [:lightning1, :lightning2, :lightning3, :beam] do
    with <<entity::little-16, rest::binary>> <- rest,
         {from, rest} <- coords(rest),
         {to, rest} <- coords(rest) do
      {{:temp, type, %{entity: entity, from: from, to: to}}, rest}
    else
      _ -> :error
    end
  end

  defp temp(:explosion2, rest) do
    with {origin, rest} <- coords(rest),
         <<start, length, rest::binary>> <- rest do
      {{:temp, :explosion2, %{origin: origin, colour: start, length: length}}, rest}
    else
      _ -> :error
    end
  end

  defp temp(nil, _rest), do: :error

  defp temp(type, rest) do
    case coords(rest) do
      {origin, rest} -> {{:temp, type, %{origin: origin}}, rest}
      :error -> :error
    end
  end

  defp coords(<<x::little-signed-16, y::little-signed-16, z::little-signed-16, rest::binary>>),
    do: {{x / 8, y / 8, z / 8}, rest}

  defp coords(_rest), do: :error

  defp angles(<<a, b, c, rest::binary>>),
    do: {{a * 360 / 256, b * 360 / 256, c * 360 / 256}, rest}

  defp angles(_rest), do: :error

  defp string(bytes) do
    case :binary.split(bytes, <<0>>) do
      [text, rest] -> {text, rest}
      [text] -> {text, <<>>}
    end
  end
end
