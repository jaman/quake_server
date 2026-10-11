defmodule QuakeServer.Markup do
  @moduledoc """
  Text with FTE's markup reduced to the characters it shows, as FTE's
  `COM_ParseFunString` followed by `COM_DeFunString` with flags ignored: colour and
  style codes are dropped and a link's hidden part with them.

      QuakeServer.Markup.plain("^1red ^[link\\\\info^]", utf8: 1)
      #=> "red link"

  Markup read: `^0`–`^9`, `^&FB`, `^b`, `^d`, `^a`, `^m`, `^h`, `^s`, `^r`, `^xRGB`
  (colours and styles, dropped), `^Uxxxx` and `^{x…}` (a character by number),
  `^[text\\\\info^]` (a link: `text` stays), `` ^`u8:…`= `` (UTF-8 text), `^^` (a caret);
  with `ezquake: true`, `&cRGB`, `&r` and `` =`k8:…`= `` (KOI8 text). Any other `^` stays.
  A first byte of 1 or 2 (or 3 with `dp_console: true`) is dropped.

  Options: `:utf8` is FTE's `com_parseutf8` (default 1): above 0 bytes are read as UTF-8
  until one is not valid and characters are written as UTF-8; below 0 characters are
  written as ISO 8859-1; 0 reads Quake's character set, its high characters as their
  low halves and control characters as U+E000–U+E01F, and writes Quake's characters.
  A character the output cannot hold becomes `?`.
  """

  import Bitwise

  @koi {0x4E, 0x30, 0x31, 0x46, 0x34, 0x35, 0x44, 0x33, 0x45, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D,
        0x3E, 0x3F, 0x4F, 0x40, 0x41, 0x42, 0x43, 0x36, 0x32, 0x4C, 0x4B, 0x37, 0x48, 0x4D, 0x49,
        0x47, 0x4A, 0x2E, 0x10, 0x11, 0x26, 0x14, 0x15, 0x24, 0x13, 0x25, 0x18, 0x19, 0x1A, 0x1B,
        0x1C, 0x1D, 0x1E, 0x1F, 0x2F, 0x20, 0x21, 0x22, 0x23, 0x16, 0x12, 0x2C, 0x2B, 0x17, 0x28,
        0x2D, 0x29, 0x27, 0x2A}

  @koi_high %{
    (?# + 128) => 0x0451,
    (?3 + 128) => 0x0401,
    (?4 + 128) => 0x0404,
    (?$ + 128) => 0x0454,
    (?6 + 128) => 0x0406,
    (?& + 128) => 0x0456,
    (?7 + 128) => 0x0407,
    (?' + 128) => 0x0457,
    (?> + 128) => 0x040E,
    (?. + 128) => 0x045E,
    (?/ + 128) => 0x042A
  }

  @dropped ~c"0123456789bdmahsr"

  @doc "The characters `text` shows, encoded as the `:utf8` option says; see the module documentation."
  @spec plain(String.t(), keyword()) :: binary()
  def plain(text, opts \\ []) do
    utf8 = Keyword.get(opts, :utf8, 1)
    state = %{ez: Keyword.get(opts, :ezquake, true), link: nil}

    text
    |> skip_first(Keyword.get(opts, :dp_console, false))
    |> parse(utf8, state, [])
    |> Enum.reverse()
    |> Enum.map(&encode(&1, utf8))
    |> IO.iodata_to_binary()
  end

  defp skip_first(<<first, rest::binary>>, _dp) when first in [1, 2], do: rest
  defp skip_first(<<3, rest::binary>>, true), do: rest
  defp skip_first(text, _dp), do: text

  defp parse("", _utf8, _state, acc), do: acc

  defp parse(<<byte, _::binary>> = text, utf8, state, acc) when byte >= 0x80 and utf8 > 0 do
    case text do
      <<char::utf8, rest::binary>> -> parse(rest, utf8, state, [min(char, 0x10FFFF) | acc])
      <<_, rest::binary>> when band(utf8, 2) != 0 -> parse(rest, utf8, state, [0xFFFD | acc])
      _ -> parse(text, band(utf8, bnot(1)), state, acc)
    end
  end

  defp parse(<<?^, code, rest::binary>>, utf8, state, acc) when code in @dropped,
    do: parse(rest, utf8, state, acc)

  defp parse(<<?^, ?&, f, b, rest::binary>> = text, utf8, state, acc) do
    if extended?(f) and extended?(b),
      do: parse(rest, utf8, state, acc),
      else: messed_up(text, utf8, state, acc)
  end

  defp parse(<<?^, ?[, rest::binary>>, utf8, %{link: nil} = state, acc),
    do: parse(rest, utf8, %{state | link: length(acc)}, [?[ | acc])

  defp parse(<<?^, ?], rest::binary>>, utf8, %{link: nil} = state, acc),
    do: parse(rest, utf8, state, [?] | acc])

  defp parse(<<?^, ?], rest::binary>>, utf8, %{link: start} = state, acc),
    do: parse(rest, utf8, %{state | link: nil}, close_link(acc, start))

  defp parse(<<?^, ?`, ?u, ?8, ?:, rest::binary>>, utf8, state, acc) do
    {inner, rest} = until_close(rest)
    parse(rest, utf8, state, parse(inner, 2, %{state | link: nil}, []) ++ acc)
  end

  defp parse(<<?^, ?U, digits::binary-size(4), rest::binary>>, utf8, state, acc) do
    char = digits |> :binary.bin_to_list() |> Enum.reduce(0, &((&2 <<< 4) + dehex(&1)))
    parse(rest, utf8, state, [band(char, 0xFFFF) | acc])
  end

  defp parse(<<?^, ?U, _::binary>>, utf8, state, acc), do: parse("", utf8, state, acc)

  defp parse(<<?^, ?{, rest::binary>>, utf8, state, acc) do
    {digits, rest} = hex_run(rest, [])
    rest = with "}" <> after_close <- rest, do: after_close
    char = Enum.reduce(digits, 0, &((&2 <<< 4) + dehex(&1)))
    char = if char > 0x10FFFF, do: 0xFFFD, else: char
    parse(rest, utf8, state, [char | acc])
  end

  defp parse(<<?^, ?x, r, g, b, rest::binary>> = text, utf8, state, acc) do
    if hex?(r) and hex?(g) and hex?(b),
      do: parse(rest, utf8, state, acc),
      else: parse(binary_part(text, 2, byte_size(text) - 2), utf8, state, acc)
  end

  defp parse(<<?^, ?x, rest::binary>>, utf8, state, acc), do: parse(rest, utf8, state, acc)
  defp parse(<<?^, ?^, rest::binary>>, utf8, state, acc), do: parse(rest, utf8, state, [?^ | acc])

  defp parse(<<?&, ?c, r, g, b, rest::binary>> = text, utf8, %{ez: true} = state, acc) do
    if hex?(r) and hex?(g) and hex?(b),
      do: parse(rest, utf8, state, acc),
      else: messed_up(text, utf8, state, acc)
  end

  defp parse(<<?&, ?r, rest::binary>>, utf8, %{ez: true} = state, acc),
    do: parse(rest, utf8, state, acc)

  defp parse(<<?=, ?`, ?k, ?8, ?:, rest::binary>>, utf8, %{ez: true} = state, acc) do
    {inner, rest} = until_close(rest)
    converted = for <<byte <- inner>>, into: <<>>, do: <<koi(byte)::utf8>>
    parse(rest, utf8, state, parse(converted, 2, %{state | link: nil}, []) ++ acc)
  end

  defp parse(text, utf8, state, acc), do: messed_up(text, utf8, state, acc)

  defp messed_up(<<byte, rest::binary>>, utf8, state, acc),
    do: parse(rest, utf8, state, [quake_char(byte, utf8) | acc])

  defp quake_char(byte, utf8) when utf8 != 0, do: byte
  defp quake_char(byte, _utf8) when byte in [?\n, ?\r, ?\t, ?\v, ?\s], do: byte
  defp quake_char(byte, _utf8) when byte >= 32 and byte < 127, do: byte
  defp quake_char(byte, _utf8) when byte >= 0x80 + 32, do: band(byte, 127)
  defp quake_char(byte, _utf8), do: bor(byte, 0xE000)

  defp close_link(acc, start) do
    {inside, before} = Enum.split(acc, length(acc) - start)
    [?[ | text] = Enum.reverse(inside)
    {shown, _info} = Enum.split_while(text, &(&1 != ?\\))
    Enum.reverse(shown, before)
  end

  defp until_close(text) do
    case :binary.match(text, "`=") do
      {at, 2} -> {binary_part(text, 0, at), binary_part(text, at + 2, byte_size(text) - at - 2)}
      :nomatch -> {text, ""}
    end
  end

  defp hex_run(<<c, rest::binary>>, acc) when c in ?0..?9 or c in ?A..?F or c in ?a..?f,
    do: hex_run(rest, [c | acc])

  defp hex_run(rest, acc), do: {Enum.reverse(acc), rest}

  defp hex?(c), do: c in ?0..?9 or c in ?A..?F or c in ?a..?f
  defp extended?(c), do: c in ?0..?9 or c in ?A..?F or c == ?-

  defp dehex(c) when c in ?0..?9, do: c - ?0
  defp dehex(c) when c in ?A..?F, do: c - ?A + 10
  defp dehex(c), do: c - ?a + 10

  defp koi(byte) when byte >= 192, do: elem(@koi, byte - 192) + 0x400
  defp koi(byte), do: Map.get(@koi_high, byte, byte)

  defp encode(char, utf8) when utf8 > 0 and char in 0..0x10FFFF and char not in 0xD800..0xDFFF,
    do: <<char::utf8>>

  defp encode(_char, utf8) when utf8 > 0, do: <<0xFFFD::utf8>>

  defp encode(char, utf8) when utf8 < 0 do
    if char < 256 or (char >= 0xE020 and char < 0xE080), do: <<band(char, 0xFF)>>, else: "?"
  end

  defp encode(char, _utf8) do
    quake? =
      ((char >= 32 or char in [?\n, ?\t, ?\r]) and char < 128) or
        (char >= 0xE000 and char <= 0xE0FF and char not in [0xE00A, 0xE009, 0xE00D, 0xE00B])

    if quake?, do: <<band(char, 0xFF)>>, else: "?"
  end
end
