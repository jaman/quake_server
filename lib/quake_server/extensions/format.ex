defmodule QuakeServer.Extensions.Format do
  @moduledoc """
  QuakeC's `sprintf`: C's conversions over the builtin's arguments.

      QuakeServer.Extensions.Format.sprintf(host, "%s has %d health", 1, argc)

  Conversions: `d` and `i` whole numbers, `u` unsigned, `x` and `X` hexadecimal, `o`
  octal, `c` a character code, `e`, `E`, `f`, `F`, `g` and `G` floats, `s` text, `S` text
  in quotes, `v` a vector, `p` a pointer, `%%` a percent sign. Flags `-`, `0`, `+`, space
  and `#`, a width and a precision (either may be `*`, taken from the next argument) and
  the size prefixes `l`, `h` and `ll` are accepted; the size prefixes change nothing, as
  every argument is read for what it holds.
  """

  import Bitwise

  alias QuakeServer.Args

  @doc "Format `format` with the arguments from number `first` up to `argc`."
  @spec sprintf(map(), String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def sprintf(host, format, first, argc),
    do: format |> run(host, first, argc, []) |> IO.iodata_to_binary()

  defp run(<<>>, _host, _next, _argc, acc), do: Enum.reverse(acc)

  defp run(<<"%%", rest::binary>>, host, next, argc, acc),
    do: run(rest, host, next, argc, ["%" | acc])

  defp run(<<"%", rest::binary>>, host, next, argc, acc) do
    {flags, rest} = flags(rest, [])
    {width, rest, next} = amount(rest, host, next)
    {precision, rest, next} = precision(rest, host, next)
    rest = sizes(rest)

    case rest do
      <<conversion, rest::binary>> ->
        text = convert(conversion, host, next, argc, precision, flags)
        run(rest, host, next + 1, argc, [pad(text, width, flags, conversion) | acc])

      <<>> ->
        Enum.reverse(acc)
    end
  end

  defp run(<<c, rest::binary>>, host, next, argc, acc),
    do: run(rest, host, next, argc, [<<c>> | acc])

  defp flags(<<c, rest::binary>>, acc) when c in ~c"-0+ #", do: flags(rest, [c | acc])
  defp flags(rest, acc), do: {acc, rest}

  defp amount(<<"*", rest::binary>>, host, next), do: {Args.int(host, next), rest, next + 1}

  defp amount(rest, _host, next) do
    case Integer.parse(rest) do
      {value, rest} -> {value, rest, next}
      :error -> {nil, rest, next}
    end
  end

  defp precision(<<".", rest::binary>>, host, next) do
    case amount(rest, host, next) do
      {nil, rest, next} -> {0, rest, next}
      found -> found
    end
  end

  defp precision(rest, _host, next), do: {nil, rest, next}

  defp sizes(<<c, rest::binary>>) when c in ~c"lh", do: sizes(rest)
  defp sizes(rest), do: rest

  defp convert(c, host, at, argc, precision, flags) when c in ~c"di",
    do: if(at < argc, do: host |> whole(at) |> signed(flags), else: "0") |> digits(precision)

  defp convert(?u, host, at, _argc, precision, _flags),
    do: host |> whole(at) |> band(0xFFFFFFFF) |> Integer.to_string() |> digits(precision)

  defp convert(?x, host, at, _argc, precision, flags),
    do: radix(host, at, 16, flags, "0x") |> String.downcase() |> digits(precision)

  defp convert(?X, host, at, _argc, precision, flags),
    do: radix(host, at, 16, flags, "0X") |> digits(precision)

  defp convert(?o, host, at, _argc, precision, flags),
    do: radix(host, at, 8, flags, "0") |> digits(precision)

  defp convert(?c, host, at, _argc, _precision, _flags), do: <<band(whole(host, at), 0xFF)>>

  defp convert(c, host, at, _argc, precision, flags) when c in ~c"eEfFgG",
    do: host |> Args.num(at) |> float(c, precision || 6, flags)

  defp convert(?s, host, at, _argc, precision, _flags), do: host |> Args.str(at) |> cut(precision)

  defp convert(?S, host, at, _argc, precision, _flags),
    do: "\"" <> (host |> Args.str(at) |> cut(precision)) <> "\""

  defp convert(?v, host, at, _argc, precision, flags) do
    {x, y, z} = Args.vec(host, at)
    Enum.map_join([x, y, z], " ", &float(&1, ?g, precision || 6, flags))
  end

  defp convert(?p, host, at, _argc, _precision, _flags),
    do:
      "0x" <>
        (host |> whole(at) |> band(0xFFFFFFFF) |> Integer.to_string(16) |> String.downcase())

  defp convert(c, _host, _at, _argc, _precision, _flags), do: <<"%", c>>

  defp whole(host, at) do
    case Args.slot(host, at) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _ -> 0
    end
  end

  defp signed(value, flags) do
    cond do
      value < 0 -> Integer.to_string(value)
      ?+ in flags -> "+" <> Integer.to_string(value)
      ?\s in flags -> " " <> Integer.to_string(value)
      true -> Integer.to_string(value)
    end
  end

  defp radix(host, at, base, flags, prefix) do
    text = host |> whole(at) |> band(0xFFFFFFFF) |> Integer.to_string(base)
    if ?# in flags and text != "0", do: prefix <> text, else: text
  end

  defp digits(text, nil), do: text

  defp digits("-" <> text, precision), do: "-" <> String.pad_leading(text, precision, "0")
  defp digits(text, precision), do: String.pad_leading(text, precision, "0")

  defp cut(text, nil), do: text
  defp cut(text, precision), do: binary_part(text, 0, min(precision, byte_size(text)))

  @doc "A float as C's `%f`, `%e` or `%g` writes it, `precision` places."
  @spec float(number(), char(), non_neg_integer(), [char()]) :: String.t()
  def float(value, conversion, precision, flags \\ [])

  def float(value, c, precision, flags) when c in ~c"fF",
    do: sign(value, flags) <> :erlang.float_to_binary(abs(value) / 1, decimals: precision)

  def float(value, c, precision, flags) when c in ~c"eE" do
    text = exponent(abs(value) / 1, precision)
    sign(value, flags) <> if(c == ?E, do: String.upcase(text), else: text)
  end

  def float(value, c, precision, flags) when c in ~c"gG" do
    precision = max(precision, 1)
    power = if value == 0, do: 0, else: floor(:math.log10(abs(value)))

    text =
      if power < -4 or power >= precision,
        do: exponent(abs(value) / 1, precision - 1) |> trim_mantissa(flags),
        else:
          :erlang.float_to_binary(abs(value) / 1, decimals: max(precision - 1 - power, 0))
          |> trim(flags)

    sign(value, flags) <> if(c == ?G, do: String.upcase(text), else: text)
  end

  defp sign(value, flags) do
    cond do
      value < 0 -> "-"
      ?+ in flags -> "+"
      ?\s in flags -> " "
      true -> ""
    end
  end

  defp exponent(value, precision) do
    {mantissa, power} = scientific(value)
    mantissa = :erlang.float_to_binary(mantissa, decimals: precision)

    {mantissa, power} =
      if String.starts_with?(mantissa, "10"),
        do: {:erlang.float_to_binary(1.0, decimals: precision), power + 1},
        else: {mantissa, power}

    power_text = power |> abs() |> Integer.to_string() |> String.pad_leading(2, "0")
    mantissa <> "e" <> if(power < 0, do: "-", else: "+") <> power_text
  end

  defp scientific(+0.0), do: {0.0, 0}

  defp scientific(value) do
    power = floor(:math.log10(value))
    {value / :math.pow(10, power), power}
  end

  defp trim(text, flags) do
    if ?# in flags or not String.contains?(text, "."),
      do: text,
      else: text |> String.trim_trailing("0") |> String.trim_trailing(".")
  end

  defp trim_mantissa(text, flags) do
    [mantissa, power] = String.split(text, "e")
    trim(mantissa, flags) <> "e" <> power
  end

  defp pad(text, nil, _flags, _conversion), do: text

  defp pad(text, width, flags, conversion) do
    cond do
      ?- in flags -> String.pad_trailing(text, width)
      ?0 in flags and conversion not in ~c"sScv" -> zero_pad(text, width)
      true -> String.pad_leading(text, width)
    end
  end

  defp zero_pad(<<sign, rest::binary>>, width) when sign in ~c"-+ ",
    do: <<sign>> <> String.pad_leading(rest, width - 1, "0")

  defp zero_pad(text, width), do: String.pad_leading(text, width, "0")
end
