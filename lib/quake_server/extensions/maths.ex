defmodule QuakeServer.Extensions.Maths do
  @moduledoc """
  FTE's arithmetic builtins: trigonometry, powers, logarithms, modulo, clamping, bit
  shifts, angle and vector helpers, and turning the `v_forward`, `v_right`, `v_up` axes.
  """

  import Bitwise, only: [<<<: 2, >>>: 2]

  alias Cauldron3D.Vec
  alias QuakeServer.{Angles, Args}

  @doc "Run arithmetic builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 60, _argc), do: Args.return(s, :math.sin(Args.num(s, 0)))
  def call(s, 61, _argc), do: Args.return(s, :math.cos(Args.num(s, 0)))
  def call(s, 62, _argc), do: Args.return(s, :math.sqrt(max(Args.num(s, 0), 0.0)))
  def call(s, 471, _argc), do: Args.return(s, :math.asin(clamp(Args.num(s, 0))))
  def call(s, 472, _argc), do: Args.return(s, :math.acos(clamp(Args.num(s, 0))))
  def call(s, 473, _argc), do: Args.return(s, :math.atan(Args.num(s, 0)))
  def call(s, 474, _argc), do: Args.return(s, :math.atan2(Args.num(s, 0), Args.num(s, 1)))
  def call(s, 475, _argc), do: Args.return(s, :math.tan(Args.num(s, 0)))
  def call(s, 97, _argc), do: Args.return(s, power(Args.num(s, 0), Args.num(s, 1)))

  def call(s, builtin, argc) when builtin in [532, "logarithm"] do
    value = Args.num(s, 0)
    base = if argc > 1, do: Args.num(s, 1), else: :math.exp(1)

    result =
      if value > 0 and base > 0 and base != 1, do: :math.log(value) / :math.log(base), else: 0.0

    Args.return(s, result)
  end

  def call(s, 94, argc), do: Args.return(s, s |> numbers(argc) |> Enum.min())
  def call(s, 95, argc), do: Args.return(s, s |> numbers(argc) |> Enum.max())

  def call(s, 96, _argc),
    do: Args.return(s, Args.num(s, 1) |> max(Args.num(s, 0)) |> min(Args.num(s, 2)))

  def call(s, builtin, _argc) when builtin in [245, "modulo"] do
    divisor = Args.num(s, 1)
    dividend = Args.num(s, 0)

    result =
      if divisor == 0,
        do: 0.0,
        else: dividend - divisor * trunc(dividend / divisor)

    Args.return(s, result / 1)
  end

  def call(s, 102, _argc) do
    angle = Args.num(s, 0)
    Args.return(s, angle - 360.0 * Float.floor(angle / 360.0))
  end

  def call(s, "anglesub", _argc) do
    difference = Args.num(s, 0) - Args.num(s, 1)
    Args.return(s, difference - 360.0 * Float.floor((difference + 180.0) / 360.0))
  end

  def call(s, 218, _argc) do
    value = trunc(Args.num(s, 0))
    shift = trunc(Args.num(s, 1))
    result = if shift >= 0, do: value <<< shift, else: value >>> -shift
    Args.return(s, result / 1)
  end

  def call(s, "ftoi", _argc), do: Args.return(s, trunc(Args.num(s, 0)))
  def call(s, "itof", _argc), do: Args.return(s, Args.int(s, 0) / 1)

  def call(s, "crossproduct", _argc) do
    {ax, ay, az} = Args.vec(s, 0)
    {bx, by, bz} = Args.vec(s, 1)
    Args.return(s, {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx})
  end

  def call(s, 91, _argc), do: Args.return(s, random_unit())

  def call(s, 432, _argc) do
    forward = Vec.normalize(Args.vec(s, 0))
    {fx, fy, _} = forward
    d = fx * fx + fy * fy

    right =
      if d == 0,
        do: {1.0, 0.0, 0.0},
        else: {-fy / :math.sqrt(d), fx / :math.sqrt(d), 0.0}

    up = cross(right, forward)
    put_axes(s, {forward, right, up})
  end

  def call(s, 235, _argc), do: rotate(s, Angles.vectors(Args.vec(s, 0)))
  def call(s, 236, _argc), do: rotate(s, {Args.vec(s, 0), Args.vec(s, 1), Args.vec(s, 2)})

  defp rotate(s, {forward, right, up}) do
    qc = s.qc

    source =
      {QuakeC.global_vector(qc, "v_forward"), QuakeC.global_vector(qc, "v_right"),
       QuakeC.global_vector(qc, "v_up")}

    {a, b, c} = concat({forward, Vec.scale(right, -1.0), up}, source)
    put_axes(s, {a, Vec.scale(b, -1.0), c})
  end

  defp concat({r0, r1, r2}, {s0, s1, s2}) do
    row = fn {a, b, c} ->
      Vec.add(Vec.add(Vec.scale(s0, a), Vec.scale(s1, b)), Vec.scale(s2, c))
    end

    {row.(r0), row.(r1), row.(r2)}
  end

  defp put_axes(s, {forward, right, up}) do
    qc =
      s.qc
      |> QuakeC.put_global("v_forward", forward)
      |> QuakeC.put_global("v_right", right)
      |> QuakeC.put_global("v_up", up)

    %{s | qc: qc}
  end

  defp cross({ax, ay, az}, {bx, by, bz}),
    do: {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}

  defp numbers(s, argc), do: for(i <- 0..(max(argc, 2) - 1), do: Args.num(s, i))

  defp clamp(value), do: value |> max(-1.0) |> min(1.0)

  defp power(base, exponent) when base < 0 and exponent != trunc(exponent), do: 0.0
  defp power(base, exponent) when base == 0 and exponent < 0, do: 0.0
  defp power(base, exponent), do: :math.pow(base, exponent)

  defp random_unit do
    vector = {:rand.uniform() * 2 - 1, :rand.uniform() * 2 - 1, :rand.uniform() * 2 - 1}
    length = Vec.length(vector)
    if length > 0 and length <= 1, do: vector, else: random_unit()
  end
end
