defmodule QuakeServer.Angles do
  @moduledoc """
  Angles as FTE's server reads them: `{pitch, yaw, roll}` in degrees, pitch above zero
  looking down.

      QuakeServer.Angles.vectors({0.0, 90.0, 0.0})
      #=> {forward, right, up}
  """

  @doc "The forward, right and up directions of `angles`, as FTE's `AngleVectors` gives them."
  @spec vectors({number(), number(), number()}) :: {tuple(), tuple(), tuple()}
  def vectors({pitch, yaw, roll}) do
    {sy, cy} = sin_cos(yaw)
    {sp, cp} = sin_cos(pitch)
    {sr, cr} = sin_cos(roll)
    forward = {cp * cy, cp * sy, -sp}
    right = {-1 * sr * sp * cy + -1 * cr * -sy, -1 * sr * sp * sy + -1 * cr * cy, -1 * sr * cp}
    up = {cr * sp * cy + -sr * -sy, cr * sp * sy + -sr * cy, cr * cp}
    {forward, right, up}
  end

  @doc "An angle brought into 0 up to 360 degrees."
  @spec mod(number()) :: float()
  def mod(angle), do: :math.fmod(:math.fmod(angle / 1, 360.0) + 360.0, 360.0)

  @doc "The yaw of direction `{x, y, _}` in whole degrees (the fraction cut off), 0 up to 360, as FTE's `vectoyaw` and Half-Life's `VEC_TO_YAW` give it."
  @spec yaw({number(), number(), number()}) :: float()
  def yaw({x, y, _}) when x == 0 and y == 0, do: 0.0

  def yaw({x, y, _}) do
    yaw = trunc(:math.atan2(y, x) * 180 / :math.pi())
    if yaw < 0, do: yaw + 360.0, else: yaw / 1
  end

  @doc """
  The `{pitch, yaw, roll}` of direction `forward`, as FTE's `vectoangles` gives them
  (`VectorAngles`): fractions of a degree kept, each angle 0 up to 360. The roll comes
  from `up` when one is given, else it is 0; with no horizontal part the yaw comes from
  `up`, or is 0. Pitch is scaled by `mesh_pitch` and roll by `mesh_roll` (the values
  of `r_meshpitch` and `r_meshroll`, 1 or -1).

      QuakeServer.Angles.vectoangles({1.0, 0.36, 0.0}, nil, {-1.0, 1.0})
      #=> {0.0, 19.798876354524932, 0.0}
  """
  @spec vectoangles({number(), number(), number()}, {number(), number(), number()} | nil, {
          number(),
          number()
        }) :: {float(), float(), float()}
  def vectoangles({x, y, z}, up, {mesh_pitch, mesh_roll}) do
    {pitch, yaw, roll} = radians({x, y, z}, up)

    {wrap(degrees(pitch) * mesh_pitch), wrap(degrees(yaw)), wrap(degrees(roll) * mesh_roll)}
  end

  @doc "The `{pitch, yaw, 0}` of direction `vector` in whole degrees, pitch above zero looking up."
  @spec of({number(), number(), number()}) :: {float(), float(), float()}
  def of({x, y, z}) when x == 0 and y == 0, do: {if(z > 0, do: 90.0, else: 270.0), 0.0, 0.0}

  def of({x, y, z} = vector) do
    forward = :math.sqrt(x * x + y * y)
    pitch = trunc(:math.atan2(z, forward) * 180 / :math.pi())
    {if(pitch < 0, do: pitch + 360.0, else: pitch / 1), yaw(vector), 0.0}
  end

  defp radians({x, y, z}, up) when x == 0 and y == 0 do
    pitch = if z > 0, do: -:math.pi() / 2, else: :math.pi() / 2
    {pitch, flat_yaw(up, z > 0), 0.0}
  end

  defp radians({x, y, z}, nil),
    do: {-:math.atan2(z, :math.sqrt(x * x + y * y)), :math.atan2(y, x), 0.0}

  defp radians({x, y, z}, {ux, uy, uz}) do
    pitch = -:math.atan2(z, :math.sqrt(x * x + y * y))
    yaw = :math.atan2(y, x)
    {sp, cp} = {:math.sin(pitch), :math.cos(pitch)}
    {sy, cy} = {:math.sin(yaw), :math.cos(yaw)}
    left = ux * -sy + uy * cy
    above = ux * sp * cy + uy * sp * sy + uz * cp
    {pitch, yaw, -:math.atan2(left, above)}
  end

  defp flat_yaw(nil, _upward), do: 0.0
  defp flat_yaw({ux, uy, _}, true), do: :math.atan2(-uy, -ux)
  defp flat_yaw({ux, uy, _}, false), do: :math.atan2(uy, ux)

  defp degrees(radians), do: radians * 180 / :math.pi()

  defp wrap(angle) when angle < 0, do: angle + 360.0
  defp wrap(angle), do: angle / 1

  defp sin_cos(degrees) do
    radians = degrees * :math.pi() / 180
    {:math.sin(radians), :math.cos(radians)}
  end
end
