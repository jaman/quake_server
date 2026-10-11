defmodule QuakeServer.Builtins.Write do
  @moduledoc """
  The message-writing builtins (`WriteByte` to `WriteEntity`, numbers 52 to 59, and
  FTE's `WriteFloat`, `WriteInt` and `WriteUnterminatedString`), which append bytes to a
  message in FTE's encodings.

  The first argument names the destination: 4 (`MSG_MULTICAST`) builds the message the
  next `multicast` sends, 5 (`MSG_ENTITY`) the entity update `SendEntity` is writing;
  every other destination reaches the one player through the server's message stream,
  which `QuakeServer.Messages` reads back.

  Coordinates are eighths of a unit in 16 bits and angles 256ths of a turn in a byte, or,
  on a server started with `coords: :float`, 32-bit floats and 65536ths of a turn in 16
  bits; eighths and turns are rounded half away from zero, as FTE's `MSG_ToCoord` and
  `MSG_WriteAngle` round them.
  """

  alias QuakeServer.Server

  @doc "Append `value` written by builtin `number` to the destination the call names."
  @spec write(Server.t(), 52..59 | integer() | String.t(), QuakeC.value()) :: Server.t()
  def write(%Server{} = server, number, value) do
    bytes = encode(number, server, value)
    destination = trunc(QuakeC.float(QuakeC.slot(server.qc, 4)))
    append(server, destination, bytes)
  end

  @doc "Append `bytes` to destination `destination`."
  @spec append(Server.t(), integer(), binary()) :: Server.t()
  def append(server, 4, bytes),
    do: %{server | ext: Map.update(server.ext, :multicast, bytes, &(&1 <> bytes))}

  def append(server, 5, bytes),
    do: %{server | ext: Map.update(server.ext, :entity, bytes, &(&1 <> bytes))}

  def append(server, _destination, bytes), do: %{server | messages: [bytes | server.messages]}

  @doc "A coordinate as `WriteCoord` writes it on `server`."
  @spec coord(Server.t(), number()) :: binary()
  def coord(%Server{} = server, value), do: encode(56, server, value / 1)

  @doc "Three coordinates as three `WriteCoord`s write them on `server`."
  @spec coords(Server.t(), {number(), number(), number()}) :: binary()
  def coords(%Server{} = server, {x, y, z}),
    do: coord(server, x) <> coord(server, y) <> coord(server, z)

  defp encode(52, _s, value), do: <<Bitwise.band(trunc(QuakeC.float(value)), 0xFF)>>
  defp encode(53, _s, value), do: <<Bitwise.band(trunc(QuakeC.float(value)), 0xFF)>>
  defp encode(54, _s, value), do: <<Bitwise.band(trunc(QuakeC.float(value)), 0xFFFF)::little-16>>

  defp encode(55, _s, value),
    do: <<Bitwise.band(trunc(QuakeC.float(value)), 0xFFFFFFFF)::little-32>>

  defp encode(56, %{coords: :float}, value), do: <<QuakeC.float(value)::little-float-32>>
  defp encode(56, _s, value), do: <<round(QuakeC.float(value) * 8)::little-signed-16>>

  defp encode(57, %{coords: :float}, value),
    do: <<Bitwise.band(round(QuakeC.float(value) * 65_536 / 360), 0xFFFF)::little-16>>

  defp encode(57, _s, value), do: <<Bitwise.band(round(QuakeC.float(value) * 256 / 360), 0xFF)>>
  defp encode(58, s, value), do: QuakeC.string(s.qc, value) <> <<0>>
  defp encode(59, _s, value), do: <<trunc(QuakeC.float(value))::little-16>>
  defp encode(280, _s, value), do: <<QuakeC.float(value)::little-float-32>>
  defp encode("WriteInt", _s, value), do: <<Bitwise.band(as_int(value), 0xFFFFFFFF)::little-32>>
  defp encode(456, s, value), do: QuakeC.string(s.qc, value)

  defp as_int(value) when is_integer(value), do: value
  defp as_int(value) when is_float(value), do: trunc(value)
  defp as_int(_value), do: 0
end
