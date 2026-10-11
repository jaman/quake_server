defmodule QuakeServer.TextNumbers do
  @moduledoc """
  Numbers read from text as C's `strtod`, `strtol` and `atof` read them, the readings
  FTE's `stof` builtin and its entity-key parser (`ED_ParseEpair`) use.

      QuakeServer.TextNumbers.strtod(" .3 rest")
      #=> {0.3, " rest"}
      QuakeServer.TextNumbers.atof(".3")
      #=> 0.30000001192092896
      QuakeServer.TextNumbers.strtol("0x1f")
      #=> {31, ""}

  Leading white space (space, tab, newline, vertical tab, form feed, carriage return) is
  skipped and a `+` or `-` sign read. `strtod` reads a decimal number (digits with an
  optional point, at least one digit, an optional exponent `e` or `E`) or a hexadecimal
  one (`0x` or `0X`, hex digits with an optional point, an optional binary exponent `p`
  or `P`); `strtol` reads base 0: `0x` hexadecimal, a leading `0` octal, else decimal.
  Text with no number reads as 0 with the whole text left. Infinities and NaNs, which
  QuakeC memory cannot hold, are not read; a number beyond a double's range reads as the
  largest double of its sign.
  """

  import Bitwise

  @float32_max 3.4028234663852886e38
  @double_max 1.7976931348623157e308
  @spaces ~c" \t\n\v\f\r"
  @exponent_limit 400
  @power_limit 1100

  @doc "The number at the front of `text`, a double, and the text after it."
  @spec strtod(String.t()) :: {float(), String.t()}
  def strtod(text) do
    {sign, rest} = text |> skip_spaces() |> sign()

    case unsigned_double(rest) do
      {value, after_number} -> {sign * value, after_number}
      nil -> {0.0, text}
    end
  end

  @doc "The whole number at the front of `text`, read in base 0, and the text after it."
  @spec strtol(String.t()) :: {integer(), String.t()}
  def strtol(text) do
    {sign, rest} = text |> skip_spaces() |> sign()

    case unsigned_integer(rest) do
      {value, after_number} -> {sign * value, after_number}
      nil -> {0, text}
    end
  end

  @doc "The number at the front of `text` as `atof` reads it into a 32-bit float."
  @spec atof(String.t()) :: float()
  def atof(text), do: text |> strtod() |> elem(0) |> float32()

  @doc "`value` rounded to a 32-bit float, a value beyond its range to its largest of that sign."
  @spec float32(number()) :: float()
  def float32(value) do
    clamped = value |> max(-@float32_max) |> min(@float32_max)
    <<rounded::float-32>> = <<clamped::float-32>>
    rounded
  end

  @doc "`value` wrapped to a signed 32-bit integer."
  @spec int32(integer()) :: integer()
  def int32(value) do
    <<wrapped::signed-32>> = <<value::signed-32>>
    wrapped
  end

  defp skip_spaces(<<c, rest::binary>>) when c in @spaces, do: skip_spaces(rest)
  defp skip_spaces(text), do: text

  defp sign("-" <> rest), do: {-1, rest}
  defp sign("+" <> rest), do: {1, rest}
  defp sign(text), do: {1, text}

  defp unsigned_double(<<?0, x, rest::binary>> = text) when x in [?x, ?X] do
    case hex_mantissa(rest) do
      nil -> decimal(text)
      {mantissa, places, after_mantissa} -> hex_exponent(mantissa, places, after_mantissa)
    end
  end

  defp unsigned_double(text), do: decimal(text)

  defp decimal(text) do
    {whole, rest} = take_digits(text, &decimal_digit?/1)
    {fraction, rest} = point_digits(rest, &decimal_digit?/1)

    if whole == "" and fraction == "" do
      nil
    else
      {exponent, rest} = exponent(rest, {?e, ?E})
      {decimal_value(whole, fraction, exponent), rest}
    end
  end

  defp decimal_value(whole, fraction, exponent) do
    limit = @exponent_limit + byte_size(whole) + byte_size(fraction)
    exponent = exponent |> max(-limit) |> min(limit)

    case Float.parse("#{zero_if_empty(whole)}.#{zero_if_empty(fraction)}e#{exponent}") do
      {value, ""} -> value
      :error -> @double_max
    end
  end

  defp hex_mantissa(text) do
    {whole, rest} = take_digits(text, &hex_digit?/1)
    {fraction, rest} = point_digits(rest, &hex_digit?/1)

    if whole == "" and fraction == "",
      do: nil,
      else: {String.to_integer(whole <> fraction, 16), byte_size(fraction), rest}
  end

  defp hex_exponent(mantissa, places, text) do
    {exponent, rest} = exponent(text, {?p, ?P})
    {scale(mantissa, exponent - 4 * places), rest}
  end

  defp scale(0, _power), do: 0.0
  defp scale(_mantissa, power) when power > @power_limit, do: @double_max
  defp scale(_mantissa, power) when power < -@power_limit, do: 0.0

  defp scale(mantissa, power) when power >= 0 do
    value = mantissa <<< power
    if value > trunc(@double_max), do: @double_max, else: value / 1
  end

  defp scale(mantissa, power), do: mantissa / :math.pow(2, -power)

  defp unsigned_integer(<<?0, x, c, rest::binary>>) when x in [?x, ?X] do
    if hex_digit?(c),
      do: integer_digits(<<c, rest::binary>>, 16, &hex_digit?/1),
      else: {0, <<x, c, rest::binary>>}
  end

  defp unsigned_integer(<<?0, rest::binary>>) do
    case integer_digits(rest, 8, &octal_digit?/1) do
      nil -> {0, rest}
      read -> read
    end
  end

  defp unsigned_integer(text), do: integer_digits(text, 10, &decimal_digit?/1)

  defp integer_digits(text, base, digit?) do
    case take_digits(text, digit?) do
      {"", _rest} -> nil
      {digits, rest} -> {String.to_integer(digits, base), rest}
    end
  end

  defp point_digits("." <> rest, digit?), do: take_digits(rest, digit?)
  defp point_digits(text, _digit?), do: {"", text}

  defp exponent(<<e, rest::binary>> = text, {lower, upper}) when e == lower or e == upper do
    {sign, after_sign} = sign(rest)

    case take_digits(after_sign, &decimal_digit?/1) do
      {"", _} -> {0, text}
      {digits, after_digits} -> {sign * String.to_integer(digits), after_digits}
    end
  end

  defp exponent(text, _letters), do: {0, text}

  defp take_digits(text, digit?) do
    count = count_digits(text, digit?, 0)
    {binary_part(text, 0, count), binary_part(text, count, byte_size(text) - count)}
  end

  defp count_digits(text, digit?, count) when count < byte_size(text) do
    if digit?.(:binary.at(text, count)), do: count_digits(text, digit?, count + 1), else: count
  end

  defp count_digits(_text, _digit?, count), do: count

  defp zero_if_empty(""), do: "0"
  defp zero_if_empty(digits), do: digits

  defp decimal_digit?(c), do: c in ?0..?9
  defp octal_digit?(c), do: c in ?0..?7
  defp hex_digit?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F
end
