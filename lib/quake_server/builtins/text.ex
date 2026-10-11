defmodule QuakeServer.Builtins.Text do
  @moduledoc """
  Numbers as FTE's `ftos` and `vtos` write them for a QuakeC program.

  `ftos/1` gives a whole number as an integer and anything else as FTE's `Q_ftoa`: the
  32-bit float written with as many decimals as its exponent allows (eight more than the
  negated power of ten of its binary exponent), trailing zeros and a bare point dropped.
  `ftos/2` with `broken: true` (the cvar `pr_brokenfloatconvert`) writes a fraction as
  `%5.1f` instead. `vtos/1` gives the three numbers as `%f` (six decimals) between single
  quotes.

      QuakeServer.Builtins.Text.ftos(3.0)
      #=> "3"

      QuakeServer.Builtins.Text.ftos(0.75)
      #=> "0.75"

      QuakeServer.Builtins.Text.vtos({1.0, -2.5, 0.0})
      #=> "'1.000000 -2.500000 0.000000'"
  """

  @int_range -2_147_483_648..2_147_483_647

  @doc "A float as `ftos` writes it."
  @spec ftos(number(), keyword()) :: String.t()
  def ftos(value, opts \\ []) do
    cond do
      whole?(value) -> Integer.to_string(trunc(value))
      Keyword.get(opts, :broken, false) -> fixed(value, 1) |> String.pad_leading(5)
      true -> ftoa(value)
    end
  end

  @doc "A vector as `vtos` writes it."
  @spec vtos({number(), number(), number()}) :: String.t()
  def vtos({x, y, z}), do: "'#{fixed(x, 6)} #{fixed(y, 6)} #{fixed(z, 6)}'"

  @doc "A float as FTE's `Q_ftoa` writes it."
  @spec ftoa(number()) :: String.t()
  def ftoa(value) do
    <<_sign::1, biased::8, _mantissa::23>> = <<value / 1::float-32>>
    decimals = trunc(-(biased - 127) * 0.30102999957) + 8

    if decimals <= 0,
      do: fixed(value, 0),
      else: value |> fixed(decimals) |> trim()
  end

  defp whole?(value), do: value == trunc(value) and trunc(value) in @int_range

  defp trim(text) do
    {_, last} =
      text
      |> String.to_charlist()
      |> Enum.reduce({0, -1}, fn
        char, {index, _last} when char in ?1..?9 -> {index + 1, index}
        ?., {index, _last} -> {index + 1, index - 1}
        _char, {index, last} -> {index + 1, last}
      end)

    binary_part(text, 0, last + 1)
  end

  defp fixed(value, decimals), do: :erlang.float_to_binary(value / 1, decimals: decimals)
end
