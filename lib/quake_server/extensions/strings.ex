defmodule QuakeServer.Extensions.Strings do
  @moduledoc """
  FTE's string builtins: length, joining, cutting, searching, comparing, case, number
  conversion, `sprintf`, and the tokenizers whose tokens `argv` reads back.

  The tokens live in the host's `ext.tokens` as `{text, start, stop}`.
  """

  import Bitwise

  alias QuakeServer.{Args, TextNumbers}
  defguardp is_single(char, singles) when singles == :quake and char in ~c"{})(':"

  alias QuakeServer.Extensions.Format

  @doc "Run string builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 114, _argc), do: Args.return(s, byte_size(Args.str(s, 0)) / 1)

  def call(s, 115, argc),
    do: Args.return(s, Enum.map_join(0..(max(argc, 1) - 1), &Args.str(s, &1)))

  def call(s, 116, _argc),
    do: Args.return(s, substring(Args.str(s, 0), Args.int(s, 1), Args.int(s, 2)))

  def call(s, 117, _argc), do: Args.return(s, stov(Args.str(s, 0)))
  def call(s, 118, argc), do: call(s, 115, argc)
  def call(s, 119, _argc), do: s
  def call(s, 81, _argc), do: Args.return(s, number(Args.str(s, 0)))

  def call(s, 221, argc) do
    text = Args.str(s, 0)
    start = trunc(Args.num(s, 2, argc, 0.0)) |> max(0) |> min(byte_size(text))

    case :binary.match(text, Args.str(s, 1), scope: {start, byte_size(text) - start}) do
      {at, _} -> Args.return(s, at / 1)
      :nomatch -> Args.return(s, -1.0)
    end
  end

  def call(s, 222, _argc) do
    text = Args.str(s, 0)
    index = Args.int(s, 1)
    index = if index < 0, do: byte_size(text) + index, else: index
    char = if index >= 0 and index < byte_size(text), do: :binary.at(text, index), else: 0
    Args.return(s, char / 1)
  end

  def call(s, 223, argc),
    do:
      Args.return(
        s,
        for(i <- 0..(max(argc, 1) - 1), into: <<>>, do: <<band(Args.int(s, i), 0xFF)>>)
      )

  def call(s, 228, argc) do
    a = Args.str(s, 0) |> offset(Args.num(s, 3, argc, 0.0))
    b = Args.str(s, 1) |> offset(Args.num(s, 4, argc, 0.0))
    length = if argc > 2, do: Args.int(s, 2), else: max(byte_size(a), byte_size(b))
    Args.return(s, compare(prefix(a, length), prefix(b, length)))
  end

  def call(s, 229, _argc),
    do: Args.return(s, compare(String.downcase(Args.str(s, 0)), String.downcase(Args.str(s, 1))))

  def call(s, 230, argc) do
    a = Args.str(s, 0) |> offset(Args.num(s, 3, argc, 0.0)) |> String.downcase()
    b = Args.str(s, 1) |> offset(Args.num(s, 4, argc, 0.0)) |> String.downcase()
    length = Args.int(s, 2)
    Args.return(s, compare(prefix(a, length), prefix(b, length)))
  end

  def call(s, 259, _argc), do: Args.return(s, stoi(String.trim(Args.str(s, 0))))
  def call(s, 260, _argc), do: Args.return(s, Integer.to_string(Args.int(s, 0)))
  def call(s, 261, _argc), do: Args.return(s, stoh(String.trim(Args.str(s, 0))))

  def call(s, 262, _argc) do
    value = band(Args.int(s, 0), 0xFFFFFFFF)
    Args.return(s, value |> Integer.to_string(16) |> String.pad_leading(8, "0"))
  end

  def call(s, 441, _argc), do: tokenized(s, tokenize(Args.str(s, 0)))
  def call(s, 514, _argc), do: tokenized(s, tokenize_console(Args.str(s, 0)))

  def call(s, 479, argc) do
    separators = for i <- 1..(max(argc, 2) - 1), text = Args.str(s, i), text != "", do: text
    tokenized(s, split(Args.str(s, 0), separators))
  end

  def call(s, 442, _argc), do: Args.return(s, token(s, Args.int(s, 0), &elem(&1, 0), ""))
  def call(s, 515, _argc), do: Args.return(s, token(s, Args.int(s, 0), &(elem(&1, 1) / 1), -1.0))
  def call(s, 516, _argc), do: Args.return(s, token(s, Args.int(s, 0), &(elem(&1, 2) / 1), -1.0))
  def call(s, 480, _argc), do: Args.return(s, ascii_case(Args.str(s, 0), &String.downcase/1))
  def call(s, 481, _argc), do: Args.return(s, ascii_case(Args.str(s, 0), &String.upcase/1))

  def call(s, 484, _argc),
    do: Args.return(s, replace(Args.str(s, 2), Args.str(s, 0), Args.str(s, 1)))

  def call(s, 485, _argc) do
    search = Args.str(s, 0)

    result =
      if search == "",
        do: Args.str(s, 2),
        else:
          Regex.replace(~r/#{Regex.escape(search)}/i, Args.str(s, 2), fn _ -> Args.str(s, 1) end)

    Args.return(s, result)
  end

  def call(s, 225, argc) do
    width = Args.int(s, 0)
    text = Enum.map_join(1..(max(argc, 2) - 1), &Args.str(s, &1))

    padded =
      if width < 0,
        do: String.pad_trailing(text, -width),
        else: String.pad_leading(text, width)

    Args.return(s, padded)
  end

  def call(s, 627, argc), do: Args.return(s, Format.sprintf(s, Args.str(s, 0), 1, argc))
  def call(s, "strtrim", _argc), do: Args.return(s, String.trim(Args.str(s, 0)))

  def call(s, 226, _argc) do
    info = Args.str(s, 0)
    key = Args.str(s, 1)
    value = Args.str(s, 2)
    pairs = info |> info_pairs() |> List.keydelete(key, 0)
    pairs = if value == "", do: pairs, else: pairs ++ [{key, value}]
    Args.return(s, Enum.map_join(pairs, fn {k, v} -> "\\#{k}\\#{v}" end))
  end

  def call(s, 227, _argc),
    do:
      Args.return(
        s,
        s |> Args.str(0) |> info_pairs() |> List.keyfind(Args.str(s, 1), 0, {"", ""}) |> elem(1)
      )

  @doc "The `{key, value}` pairs of an info string such as `\\\\name\\\\player\\\\team\\\\red`."
  @spec info_pairs(String.t()) :: [{String.t(), String.t()}]
  def info_pairs(info) do
    info
    |> String.trim_leading("\\")
    |> String.split("\\")
    |> Enum.chunk_every(2, 2, [""])
    |> Enum.reject(&(&1 == [""]))
    |> Enum.map(fn [key, value] -> {key, value} end)
  end

  @doc "A number read from the front of `text` as `atof` reads it into a 32-bit float, 0.0 when there is none (`QuakeServer.TextNumbers.atof/1`)."
  @spec number(String.t()) :: float()
  def number(text), do: TextNumbers.atof(text)

  @doc "Tokens of `text` as Quake's parser reads them: quoted strings whole, `{ } ( ) ' :` alone."
  @spec tokenize(String.t()) :: [{String.t(), non_neg_integer(), non_neg_integer()}]
  def tokenize(text), do: parse(text, 0, [], :quake)

  @doc "Tokens of `text` as the console reads a command: quoted strings whole, words split at spaces."
  @spec tokenize_console(String.t()) :: [{String.t(), non_neg_integer(), non_neg_integer()}]
  def tokenize_console(text), do: parse(text, 0, [], :console)

  defp tokenized(s, tokens),
    do: %{s | ext: Map.put(s.ext, :tokens, tokens)} |> Args.return(length(tokens) / 1)

  defp token(s, index, pick, default) do
    tokens = Map.get(s.ext, :tokens, [])
    index = if index < 0, do: length(tokens) + index, else: index

    case Enum.at(tokens, index) do
      nil -> default
      token -> pick.(token)
    end
  end

  defp parse(text, at, acc, singles) do
    case skip(text, at) do
      at when at >= byte_size(text) -> Enum.reverse(acc)
      at -> read_token(text, at, acc, singles)
    end
  end

  defp read_token(text, at, acc, singles) do
    char = :binary.at(text, at)

    cond do
      char == ?" ->
        stop = quote_end(text, at + 1)
        token = binary_part(text, at + 1, stop - at - 1)
        parse(text, min(stop + 1, byte_size(text)), [{token, at, stop + 1} | acc], singles)

      is_single(char, singles) ->
        parse(text, at + 1, [{<<char>>, at, at + 1} | acc], singles)

      true ->
        stop = word_end(text, at, singles)
        parse(text, stop, [{binary_part(text, at, stop - at), at, stop} | acc], singles)
    end
  end

  defp skip(text, at) when at < byte_size(text) do
    case binary_part(text, at, byte_size(text) - at) do
      <<"//", _::binary>> -> skip(text, line_end(text, at))
      <<c, _::binary>> when c <= 32 -> skip(text, at + 1)
      _ -> at
    end
  end

  defp skip(_text, at), do: at

  defp line_end(text, at) do
    case :binary.match(text, "\n", scope: {at, byte_size(text) - at}) do
      {stop, _} -> stop + 1
      :nomatch -> byte_size(text)
    end
  end

  defp quote_end(text, at) do
    case :binary.match(text, "\"", scope: {at, byte_size(text) - at}) do
      {stop, _} -> stop
      :nomatch -> byte_size(text)
    end
  end

  defp word_end(text, at, singles) do
    case text do
      <<_::binary-size(^at), char, _::binary>>
      when char > 32 and char != ?" and not is_single(char, singles) ->
        word_end(text, at + 1, singles)

      _ ->
        min(at, byte_size(text))
    end
  end

  defp split("", _separators), do: []
  defp split(text, []), do: [{text, 0, byte_size(text)}]

  defp split(text, separators), do: split(text, separators, 0, 0, [])

  defp split(text, _separators, start, at, acc) when at >= byte_size(text),
    do:
      Enum.reverse([
        {binary_part(text, start, byte_size(text) - start), start, byte_size(text)} | acc
      ])

  defp split(text, separators, start, at, acc) do
    rest = binary_part(text, at, byte_size(text) - at)

    case Enum.find(separators, &String.starts_with?(rest, &1)) do
      nil ->
        split(text, separators, start, at + 1, acc)

      separator ->
        token = {binary_part(text, start, at - start), start, at}
        next = at + byte_size(separator)
        split(text, separators, next, next, [token | acc])
    end
  end

  defp substring(text, start, length) do
    size = byte_size(text)
    start = if start < 0, do: max(size + start, 0), else: min(start, size)
    length = if length < 0, do: size - start + length + 1, else: length
    binary_part(text, start, length |> max(0) |> min(size - start))
  end

  defp stov("'" <> text), do: stov_components(text, [])
  defp stov(text), do: stov_components(text, [])

  defp stov_components(_text, [_, _, _] = numbers), do: stov_vector(numbers)

  defp stov_components(text, numbers) do
    text = skip_blanks(text)
    value = number(text)

    if value == 0 and not number_start?(text),
      do: stov_vector(numbers),
      else: stov_next(skip_word(text), [value | numbers])
  end

  defp stov_next("'" <> _, numbers), do: stov_vector(numbers)
  defp stov_next(rest, numbers), do: stov_components(rest, numbers)

  defp stov_vector(numbers) do
    [x, y, z | _] = Enum.reverse(numbers) ++ [0.0, 0.0, 0.0]
    {x, y, z}
  end

  defp skip_blanks(<<c, rest::binary>>) when c in ~c" \t", do: skip_blanks(rest)
  defp skip_blanks(text), do: text

  defp skip_word(<<c, rest::binary>>) when c not in ~c" \t'", do: skip_word(rest)
  defp skip_word(text), do: text

  defp number_start?(<<c, _::binary>>), do: c in ~c"-+0123456789"
  defp number_start?(_text), do: false

  defp stoi("0x" <> hex), do: stoh(hex)
  defp stoi("0X" <> hex), do: stoh(hex)

  defp stoi("0" <> octal) when octal != "" do
    case Integer.parse(octal, 8) do
      {value, _} -> value
      :error -> 0
    end
  end

  defp stoi(text) do
    case Integer.parse(text) do
      {value, _} -> value
      :error -> 0
    end
  end

  defp stoh(text) do
    text = text |> String.trim_leading("0x") |> String.trim_leading("0X")

    case Integer.parse(text, 16) do
      {value, _} -> value
      :error -> 0
    end
  end

  defp offset(text, at) do
    at = trunc(at) |> max(0) |> min(byte_size(text))
    binary_part(text, at, byte_size(text) - at)
  end

  defp prefix(text, length), do: binary_part(text, 0, length |> max(0) |> min(byte_size(text)))

  defp compare(a, b) when a < b, do: -1.0
  defp compare(a, b) when a > b, do: 1.0
  defp compare(_a, _b), do: 0.0

  defp ascii_case(text, change) do
    for <<c <- text>>, into: <<>> do
      if c < 128, do: change.(<<c>>), else: <<c>>
    end
  end

  defp replace(subject, "", _replacement), do: subject
  defp replace(subject, search, replacement), do: String.replace(subject, search, replacement)
end
