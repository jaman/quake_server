defmodule QuakeServer.Extensions.Encoding do
  @moduledoc """
  FTE's builtins that recode text and bytes:

    * `strconv` (224) — case (1 lower, 2 upper) and Quake's red and white character
      sets for letters, digits and punctuation, as FTE's `PF_strconv`
    * `strlennocol` (476), `strdecolorize` (477) — length and text with markup removed
      (`QuakeServer.Markup`, by `com_parseutf8`, `ezcompat_markup`, `dpcompat_console`)
    * `crc16` (494) — Quake's CRC-16 (CCITT, from 0xFFFF) of the arguments joined, case
      folded when the first argument is set
    * `uri_escape` (510), `uri_unescape` (511) — percent encoding of every byte but
      RFC 3986's unreserved ones, and back
    * `argescape` (295) — a string quoted for the console as FTE's `COM_QuotedString`
    * `digest_hex` (639), `digest_ptr` — a hex digest (`MD4`, `MD5`, `SHA1`, `SHA2-224`
      or `SHA224` and the 256, 384 and 512 ones likewise, `CRC16` little end first) of
      the arguments joined or of bytes in memory; null for another name
    * `base64encode`, `base64decode` — bytes in memory to base 64, and base 64 to a new
      block of memory (its length written to the second argument)
    * `ftou`, `utof` — a float to an unsigned integer, and back with an optional shift and
      bit count
  """

  import Bitwise

  alias QuakeServer.{Args, Cvars, Markup}
  alias QuakeServer.Extensions.Memory

  @unreserved Enum.concat([?a..?z, ?A..?Z, ?0..?9, ~c".-_~"])
  @escapes %{
    ?\n => "\\n",
    ?\r => "\\r",
    ?\t => "\\t",
    ?' => "\\'",
    ?" => "\\\"",
    ?\\ => "\\\\",
    ?$ => "\\$"
  }
  @hashes %{
    "MD4" => :md4,
    "MD5" => :md5,
    "SHA1" => :sha,
    "SHA2-224" => :sha224,
    "SHA224" => :sha224,
    "SHA2-256" => :sha256,
    "SHA256" => :sha256,
    "SHA2-384" => :sha384,
    "SHA384" => :sha384,
    "SHA2-512" => :sha512,
    "SHA512" => :sha512
  }

  @doc "Run recoding builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 224, argc) do
    letters = trunc(Args.num(s, 1))
    digits = trunc(Args.num(s, 2))
    case_change = trunc(Args.num(s, 0))
    text = joined(s, 3, argc)

    converted =
      text
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, i} -> convert(byte, i, case_change, letters, digits) end)

    Args.return(s, :binary.list_to_bin(converted))
  end

  def call(s, 476, _argc), do: Args.return(s, byte_size(plain(s, Args.str(s, 0))) / 1)
  def call(s, 477, _argc), do: Args.return(s, plain(s, Args.str(s, 0)))

  def call(s, 494, argc) do
    text = joined(s, 1, argc)
    text = if trunc(Args.num(s, 0)) != 0, do: ascii_lower(text), else: text
    Args.return(s, crc16(text) / 1)
  end

  def call(s, 510, _argc) do
    escaped =
      for <<byte <- Args.str(s, 0)>>, into: "" do
        if byte in @unreserved, do: <<byte>>, else: "%" <> Base.encode16(<<byte>>)
      end

    Args.return(s, escaped)
  end

  def call(s, 511, _argc), do: Args.return(s, unescape(Args.str(s, 0), []))

  def call(s, 295, _argc), do: Args.return(s, quoted(Args.str(s, 0), dp_console?(s)))

  def call(s, 639, argc), do: digest(s, Args.str(s, 0), joined(s, 1, argc))

  def call(s, "digest_ptr", argc) do
    offset = if argc > 3, do: Args.int(s, 3), else: 0
    digest(s, Args.str(s, 0), Memory.bytes(s.qc, Args.int(s, 1) + offset, Args.int(s, 2)))
  end

  def call(s, "base64encode", _argc),
    do: Args.return(s, Base.encode64(Memory.bytes(s.qc, Args.int(s, 0), Args.int(s, 1))))

  def call(s, "base64decode", _argc) do
    text = Args.str(s, 0)
    decoded = base64_decode(text, <<>>)
    {qc, address} = QuakeC.alloc(s.qc, div(byte_size(text) + 3, 4) * 3 + 1)
    qc = Memory.put_bytes(qc, address, decoded <> <<0>>)
    qc = QuakeC.put_slot(qc, 7, byte_size(decoded))
    Args.return(%{s | qc: qc}, address)
  end

  def call(s, "ftou", _argc), do: Args.return(s, unsigned(trunc(Args.num(s, 0))))

  def call(s, "utof", argc) do
    value = band(Args.int(s, 0), 0xFFFFFFFF)

    value =
      if argc > 1 do
        count = trunc(Args.num(s, 2))
        shifted = value >>> trunc(Args.num(s, 1))
        if count != 32, do: band(shifted, (1 <<< count) - 1), else: shifted
      else
        value
      end

    Args.return(s, value / 1)
  end

  @doc "Quake's CRC-16 of `data`: CCITT's polynomial 0x1021, starting from 0xFFFF."
  @spec crc16(binary()) :: non_neg_integer()
  def crc16(data) do
    for <<byte <- data>>, reduce: 0xFFFF do
      crc -> Enum.reduce(0..7, bxor(crc, byte <<< 8), fn _, c -> crc_step(c) end)
    end
  end

  @doc "Text quoted for the console as FTE's `COM_QuotedString`, escaped when it holds a newline or a quote."
  @spec quoted(String.t(), boolean()) :: String.t()
  def quoted(text, dp_console) do
    escaped? =
      String.contains?(text, ["\r", "\n"]) or (not dp_console and String.contains?(text, "\""))

    cond do
      escaped? -> "\\\"" <> escape(text) <> "\""
      dp_console -> "\"" <> String.replace(text, ["\\", "\""], &("\\" <> &1)) <> "\""
      true -> "\"" <> text <> "\""
    end
  end

  defp crc_step(crc) when band(crc, 0x8000) != 0, do: band(bxor(crc <<< 1, 0x1021), 0xFFFF)
  defp crc_step(crc), do: band(crc <<< 1, 0xFFFF)

  defp escape(text), do: for(<<byte <- text>>, into: "", do: Map.get(@escapes, byte, <<byte>>))

  defp digest(s, kind, data) do
    case hash(kind, data) do
      nil -> Args.return(s, 0)
      hash -> Args.return(s, Base.encode16(hash, case: :lower))
    end
  end

  defp hash("CRC16", data), do: <<crc16(data)::little-16>>

  defp hash(kind, data) do
    case Map.fetch(@hashes, kind) do
      {:ok, algorithm} -> :crypto.hash(algorithm, data)
      :error -> nil
    end
  end

  defp convert(byte, _i, _case, _letters, digits) when byte in ?0..?9,
    do: number(byte, ?0, digits)

  defp convert(byte, _i, _case, _letters, digits) when byte in 176..185,
    do: number(byte, ?0 + 128, digits)

  defp convert(byte, _i, _case, _letters, digits) when byte in 146..155,
    do: number(byte, ?0 + 98, digits)

  defp convert(byte, _i, _case, _letters, digits) when byte in 18..27,
    do: number(byte, ?0 - 30, digits)

  defp convert(byte, i, case_change, letters, _digits) when byte in ?a..?z,
    do: alpha(byte, ?a, 0, case_change, letters, i)

  defp convert(byte, i, case_change, letters, _digits) when byte in ?A..?Z,
    do: alpha(byte, ?A, 0, case_change, letters, i)

  defp convert(byte, i, case_change, letters, _digits) when byte in 225..250,
    do: alpha(byte, ?a, 128, case_change, letters, i)

  defp convert(byte, i, case_change, letters, _digits) when byte in 193..218,
    do: alpha(byte, ?A, 128, case_change, letters, i)

  defp convert(byte, _i, _case, letters, _digits) when band(byte, 127) < 16 or letters == 0,
    do: byte

  defp convert(byte, _i, _case, letters, _digits) when byte < 128, do: punct(byte, 0, letters)
  defp convert(byte, _i, _case, letters, _digits), do: punct(byte, 128, letters)

  defp number(byte, base, conversion) do
    target =
      case conversion do
        1 -> ?0
        2 -> ?0 + 128
        3 -> ?0 - 30
        4 -> ?0 + 128 - 30
        _ -> base
      end

    band(byte - base + target, 0xFF)
  end

  defp punct(byte, base, conversion) do
    target =
      case conversion do
        1 -> 0
        2 -> 128
        _ -> base
      end

    band(byte - base + target, 0xFF)
  end

  defp alpha(byte, letter_base, set_base, case_change, conversion, index) do
    set =
      case conversion do
        1 -> 0
        2 -> 128
        n when n in [5, 6] -> if band(index, 1) == n - 5, do: 128, else: 0
        _ -> set_base
      end

    letter =
      case case_change do
        1 -> ?a
        2 -> ?A
        _ -> letter_base
      end

    band(byte - set_base - letter_base + letter + set, 0xFF)
  end

  defp unescape(<<?%, a, b, rest::binary>>, acc) do
    case {hex(a), hex(b)} do
      {nil, _} -> unescape(<<a, b, rest::binary>>, [?% | acc])
      {_, nil} -> unescape(<<a, b, rest::binary>>, [?% | acc])
      {high, low} -> unescape(rest, [high * 16 + low | acc])
    end
  end

  defp unescape(<<byte, rest::binary>>, acc), do: unescape(rest, [byte | acc])
  defp unescape(<<>>, acc), do: acc |> Enum.reverse() |> :binary.list_to_bin()

  defp hex(c) when c in ?0..?9, do: c - ?0
  defp hex(c) when c in ?A..?F, do: c - ?A + 10
  defp hex(c) when c in ?a..?f, do: c - ?a + 10
  defp hex(_c), do: nil

  defp base64_decode(text, acc) do
    case skip_controls(text) do
      <<a, rest::binary>> when a != ?= -> base64_second(rest, base64_value(a) <<< 18, acc)
      _ -> acc
    end
  end

  defp base64_second(text, v, acc) do
    case skip_controls(text) do
      <<b, rest::binary>> ->
        v = bor(v, base64_value(b) <<< 12)
        acc = <<acc::binary, v >>> 16 &&& 0xFF>>
        base64_third(rest, v, acc)

      _ ->
        acc
    end
  end

  defp base64_third(<<c, rest::binary>>, v, acc) when c != ?= do
    v = bor(v, base64_value(c) <<< 6)
    acc = <<acc::binary, v >>> 8 &&& 0xFF>>

    case rest do
      <<d, rest::binary>> when d != ?= ->
        v = bor(v, base64_value(d))
        base64_decode(rest, <<acc::binary, v &&& 0xFF>>)

      _ ->
        acc
    end
  end

  defp base64_third(_text, _v, acc), do: acc

  defp skip_controls(<<c, rest::binary>>) when c > 0 and c < 32, do: skip_controls(rest)
  defp skip_controls(text), do: text

  defp base64_value(c) when c in ?A..?Z, do: c - ?A
  defp base64_value(c) when c in ?a..?z, do: c - ?a + 26
  defp base64_value(c) when c in ?0..?9, do: c - ?0 + 52
  defp base64_value(c) when c in [?+, ?-], do: 62
  defp base64_value(c) when c in [?/, ?_], do: 63
  defp base64_value(_c), do: 0

  defp unsigned(value) when value < 0, do: band(value, 0xFFFFFFFF) - 0x100000000
  defp unsigned(value) when value > 0x7FFFFFFF, do: band(value, 0xFFFFFFFF) - 0x100000000
  defp unsigned(value), do: value

  defp joined(s, first, argc), do: Enum.map_join(first..(argc - 1)//1, &Args.str(s, &1))

  defp ascii_lower(text),
    do: for(<<b <- text>>, into: "", do: <<if(b in ?A..?Z, do: b + 32, else: b)>>)

  defp plain(s, text),
    do:
      Markup.plain(text,
        utf8: cvar_int(s, "com_parseutf8", 1),
        ezquake: cvar_int(s, "ezcompat_markup", 1) != 0,
        dp_console: dp_console?(s)
      )

  defp dp_console?(s), do: cvar_int(s, "dpcompat_console", 0) != 0

  defp cvar_int(%{cvars: %Cvars{} = cvars}, name, default) do
    case Cvars.fetch(cvars, name) do
      nil -> default
      cvar -> cvar.ival
    end
  end

  defp cvar_int(_s, _name, default), do: default
end
