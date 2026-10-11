defmodule QuakeServer.Extensions.Polygons do
  @moduledoc """
  FTE's server polygon builtins, for drawing in the world from the server program:
  `R_BeginPolygon(texture, flags, is2d)`, `R_PolygonVertex(origin, texcoords, rgb,
  alpha)` and `R_EndPolygon()`. Each finished polygon becomes the event
  `{:polygon, %{texture:, flags:, flat?:, vertices: [{origin, texcoords, rgb, alpha}]}}`
  (`QuakeServer.Server.emit/2`), and the next starts on the same texture.

  The polygon being built is kept in the host's `ext.polygon`.
  """

  alias QuakeServer.{Args, Server}

  @doc "Run polygon builtin `builtin`."
  @spec call(map(), integer(), non_neg_integer()) :: map()
  def call(s, 306, argc) do
    polygon = %{
      texture: Args.str(s, 0),
      flags: trunc(Args.num(s, 1, argc, 0.0)),
      flat?: Args.num(s, 2, argc, 0.0) != 0,
      vertices: []
    }

    %{s | ext: Map.put(s.ext, :polygon, polygon)}
  end

  def call(s, 307, _argc) do
    vertex = {Args.vec(s, 0), Args.vec(s, 1), Args.vec(s, 2), Args.num(s, 3)}

    case Map.get(s.ext, :polygon) do
      nil ->
        s

      polygon ->
        %{s | ext: Map.put(s.ext, :polygon, %{polygon | vertices: [vertex | polygon.vertices]})}
    end
  end

  def call(s, 308, _argc) do
    case Map.get(s.ext, :polygon) do
      %{vertices: [_, _, _ | _]} = polygon ->
        s = Server.emit(s, {:polygon, %{polygon | vertices: Enum.reverse(polygon.vertices)}})
        %{s | ext: Map.put(s.ext, :polygon, %{polygon | vertices: []})}

      _ ->
        s
    end
  end
end
