defmodule QuakeServer.Extensions.Lights do
  @moduledoc """
  FTE's light builtins: `getlight` (the world's light at a point, 0 to 255 a channel,
  as `Cauldron3D.Bsp.Light.at/4` finds it), `lightstyle` with an optional colour,
  `getlightstyle` (the pattern, and the colour through its second argument) and
  `getlightstylergb` (the colour scaled by the pattern's brightness now, `m` being 1.03).

  Colours are kept in the host's `ext.lightstyle_rgb`, style to `{r, g, b}`, white when
  never given.
  """

  alias Cauldron3D.Bsp.Light
  alias QuakeServer.{Args, Builtins}

  @white {1.0, 1.0, 1.0}

  @doc "Run light style builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 35, argc) do
    colour = if argc > 2, do: Args.vec(s, 2), else: @white

    s = %{
      s
      | ext:
          Map.update(
            s.ext,
            :lightstyle_rgb,
            %{Args.int(s, 0) => colour},
            &Map.put(&1, Args.int(s, 0), colour)
          )
    }

    Builtins.call(s, 35, argc)
  end

  def call(s, 92, _argc) do
    case Light.at(s.bsp, Args.vec(s, 0), scales(s)) do
      nil -> Args.return(s, {0.0, 0.0, 0.0})
      {r, g, b} -> Args.return(s, {r / 1, g / 1, b / 1})
    end
  end

  def call(s, "getlightstyle", _argc) do
    style = Args.int(s, 0)
    s = %{s | qc: QuakeC.put_slot_vector(s.qc, 7, colour(s, style))}
    Args.return(s, Map.get(s.lightstyles, style, ""))
  end

  def call(s, "getlightstylergb", _argc) do
    style = Args.int(s, 0)
    {r, g, b} = colour(s, style)
    level = brightness(Map.get(s.lightstyles, style, ""), s.time)
    Args.return(s, {r * level, g * level, b * level})
  end

  @doc "Every light style's scale now, style to scale, 256 normal."
  @spec scales(map()) :: %{non_neg_integer() => float()}
  def scales(s),
    do:
      Map.new(s.lightstyles, fn {style, pattern} -> {style, brightness(pattern, s.time) * 256} end)

  defp colour(s, style), do: s.ext |> Map.get(:lightstyle_rgb, %{}) |> Map.get(style, @white)

  defp brightness("", _time), do: 1.0

  defp brightness(pattern, time) do
    at = rem(trunc(time * 10), byte_size(pattern))
    (:binary.at(pattern, at) - ?a) * 22 / 256
  end
end
