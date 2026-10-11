defmodule QuakeServer.Extensions.EntityText do
  @moduledoc """
  FTE's builtins that write entities as text and read them back, as its `PR_SaveEnt`
  and `PR_RestoreEnt`, and that list or protect entities:

    * `generateentitydata` — an entity as `{ "field" "value" … }`, every field that is
      not all zero, by the program's field order, `_x`/`_y`/`_z` parts left out
    * `writetofile` (606) — the same text added to a file open for writing
    * `parseentitydata` (613) — text from a byte offset read into an entity: the offset
      after it, or 0 when there is no `{`
    * `loadfromdata` (529), `loadfromfile` (530) — every `{ … }` of a string, or of a game
      file, made into a new entity: 0, or -1 for an empty string or a missing file
    * `find_list` — the entities whose field holds a value, compared by the given type,
      as a list of entity numbers ending in 0 (in fresh memory); the count goes to the
      fourth argument
    * `entityprotection` — marks an entity read only (1) or not (0) and returns the value
      given; `find_list` of strings passes over read-only entities

  Text is read as QuakeC source is tokenized (`//` and `/* */` comments, quoted strings
  with `\\"`, `\\\\`, `\\n`, `\\r` and `\\t`). A key starting `_` is ignored, `angle` sets
  the yaw of `angles` and `light` sets `light_lev` when there is no `light` field. An
  entity given no keys is freed. Values: a string as written, numbers as C's `strtod`
  and `strtol` read them, a vector as three numbers, a field by name, a function by name
  after any `N:` prefix. Written values: a float or vector whole when it is whole, else
  with six decimals (`%f`) or six significant digits (`%g`); a function as `0:name`; a
  string with `\\n`, `\\"` and `\\\\` escaped.
  """

  import Bitwise

  alias QuakeServer.{Args, Edicts, Events}
  alias QuakeServer.Extensions.{Files, Store}

  @types [:void, :string, :float, :vector, :entity, :field, :function, :pointer, :integer]

  @doc "Run entity text builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, "generateentitydata", _argc), do: Args.return(s, save(s, Args.int(s, 0)))

  def call(s, 606, _argc) do
    {s, _written} = Files.write(s, Args.int(s, 0), save(s, Args.int(s, 1)))
    s
  end

  def call(s, 613, argc) do
    entity = Args.int(s, 0)
    text = Args.str(s, 1)
    offset = if argc >= 3, do: trunc(Args.num(s, 2)), else: 0
    offset = offset |> max(0) |> min(byte_size(text))
    rest = binary_part(text, offset, byte_size(text) - offset)

    case if(rest == "", do: nil, else: restore(s, rest, entity)) do
      nil ->
        s =
          if argc < 3 and rest != "",
            do: warn(s, "parseentitydata: missing opening data\n"),
            else: s

        Args.return(s, 0.0)

      {s, _entity, used} ->
        s =
          if argc < 3 and trailing?(rest, used),
            do: warn(s, "parseentitydata: too much data\n"),
            else: s

        Args.return(s, (offset + used) / 1)
    end
  end

  def call(s, 529, _argc) do
    case Args.str(s, 0) do
      "" -> Args.return(s, -1.0)
      text -> s |> restore_all(text) |> Args.return(0.0)
    end
  end

  def call(s, 530, _argc) do
    case Store.read(s, Args.str(s, 0)) do
      nil -> Args.return(s, -1.0)
      text -> s |> restore_all(text) |> Args.return(0.0)
    end
  end

  def call(s, "find_list", _argc) do
    offset = Args.int(s, 0)
    type = Args.int(s, 2)
    width = if type in [3], do: 3, else: if(type in 10..12, do: 2, else: 1)

    if type < 0 or type > 12 or offset < 0 or offset + width > s.qc.size do
      s |> put_count(0) |> Args.return(0)
    else
      found = Enum.filter(1..(s.count - 1)//1, &listed?(s, &1, offset, type))
      {qc, address} = QuakeC.alloc(s.qc, (length(found) + 1) * 4)

      qc =
        (found ++ [0])
        |> Enum.with_index()
        |> Enum.reduce(qc, fn {entity, i}, qc -> QuakeC.store(qc, address + 4 * i, entity) end)

      %{s | qc: qc} |> put_count(length(found)) |> Args.return(address)
    end
  end

  def call(s, "entityprotection", _argc) do
    entity = Args.int(s, 0)
    protection = trunc(Args.num(s, 1))

    if Edicts.free?(s, entity),
      do: raise(QuakeC.Exec.Error, "PF_entityprotection: entity is free")

    s =
      case protection do
        1 ->
          %{s | ext: Map.update(s.ext, :readonly, MapSet.new([entity]), &MapSet.put(&1, entity))}

        0 ->
          %{s | ext: Map.update(s.ext, :readonly, MapSet.new(), &MapSet.delete(&1, entity))}

        _ ->
          s
      end

    Args.return(s, protection / 1)
  end

  @doc """
  Field `offset` of `entity`, of type `type`, as text the way FTE's `PR_UglyValueString`
  writes a value: functions as `0:name`, whole floats and vectors without decimals,
  strings with newlines, quotes and backslashes escaped.
  """
  @spec value(map(), non_neg_integer(), atom(), non_neg_integer()) :: String.t()
  def value(s, entity, type, offset), do: value_text(s, entity, type, offset)

  @doc "Entity `entity` as FTE's `PR_SaveEnt` writes it."
  @spec save(map(), non_neg_integer()) :: String.t()
  def save(s, entity) do
    classname = classname(s, entity)

    lines =
      for {name, type, offset} <- fields(s),
          saved?(name),
          type in @types,
          not zero?(s, entity, type, offset),
          name = saved_name(s, name, offset, classname),
          name != nil,
          do: "\"#{name}\" \"#{value_text(s, entity, type, offset)}\"\n"

    "{\n" <> Enum.join(lines) <> "}\n"
  end

  @doc """
  Read one `{ … }` from `text` into `entity` (a new one when `nil`), as FTE's
  `PR_RestoreEnt`: `{host, entity, bytes_used}`, or `nil` when the text holds no entity.
  """
  @spec restore(map(), String.t(), non_neg_integer() | nil) ::
          {map(), non_neg_integer(), non_neg_integer()} | nil
  def restore(s, text, entity) do
    case token(text) do
      {"{", rest} ->
        {s, entity} = target(s, entity)
        {s, rest} = pairs(s, entity, rest, 1, false)
        {s, entity, byte_size(text) - byte_size(rest)}

      {"", _rest} ->
        nil

      {_token, _rest} ->
        Events.print(s, :notify, "PR_RestoreEnt: with no opening brace")
        nil

      :eof ->
        nil
    end
  end

  defp restore_all(s, text) do
    case restore(s, text, nil) do
      nil -> s
      {s, _entity, used} -> restore_all(s, binary_part(text, used, byte_size(text) - used))
    end
  end

  defp target(s, nil), do: Edicts.alloc(s)

  defp target(s, entity) do
    if Edicts.free?(s, entity), do: {Edicts.clear(s, entity), entity}, else: {s, entity}
  end

  defp pairs(s, entity, text, nest, init) do
    case token(text) do
      :eof ->
        {warn(s, "ED_ParseEntity: EOF without closing brace\n"), ""}

      {"}" <> _, rest} when nest == 1 ->
        {finish(s, entity, init), rest}

      {"}" <> _, rest} ->
        pairs(s, entity, rest, nest - 1, init)

      {"{", rest} ->
        pairs(s, entity, rest, nest + 1, init)

      {_key, rest} when nest > 1 ->
        pairs(s, entity, rest, nest, init)

      {key, rest} ->
        value(s, entity, String.trim_trailing(key, " "), rest, nest)
    end
  end

  defp value(s, entity, key, text, nest) do
    case token(text) do
      :eof ->
        {warn(s, "ED_ParseEntity: EOF without closing brace\n"), ""}

      {"}" <> _, rest} ->
        {warn(s, "ED_ParseEntity: closing brace without data\n"), rest}

      {value, rest} ->
        pairs(put_pair(s, entity, key, value), entity, rest, nest, true)
    end
  end

  defp finish(s, _entity, true), do: s
  defp finish(s, entity, false), do: Edicts.free(s, entity)

  defp put_pair(s, _entity, "_" <> _, _value), do: s

  defp put_pair(s, entity, "angle", value) do
    case field(s, "angles") do
      nil -> put_named(s, entity, "angle", value)
      def -> put_value(s, entity, def, "0 #{format_f(strtod(value) |> elem(0))} 0")
    end
  end

  defp put_pair(s, entity, key, value), do: put_named(s, entity, key, value)

  defp put_named(s, entity, key, value) do
    case field(s, key) || (key == "light" && field(s, "light_lev")) do
      nil -> s
      false -> s
      def -> put_value(s, entity, def, value)
    end
  end

  defp put_value(s, entity, {:string, offset}, value), do: put_slot(s, entity, offset, value)

  defp put_value(s, entity, {:float, offset}, value),
    do: put_slot(s, entity, offset, value |> strtod() |> elem(0))

  defp put_value(s, entity, {type, offset}, value) when type in [:integer, :entity],
    do: put_slot(s, entity, offset, strtol(value))

  defp put_value(s, entity, {:vector, offset}, value) do
    {x, rest} = strtod(value)
    {y, rest} = strtod(rest)
    {z, _rest} = strtod(rest)

    s
    |> put_slot(entity, offset, x)
    |> put_slot(entity, offset + 1, y)
    |> put_slot(entity, offset + 2, z)
  end

  defp put_value(s, entity, {:field, offset}, value) do
    case field(s, value) do
      {_type, at} -> put_slot(s, entity, offset, at)
      nil -> Events.print(s, :notify, "Can't find field #{value}\n")
    end
  end

  defp put_value(s, entity, {:function, offset}, <<_, ?:>>), do: put_slot(s, entity, offset, 0)

  defp put_value(s, entity, {:function, offset}, value) do
    case QuakeC.Progs.find_function(s.qc.progs, value) do
      nil -> Events.print(s, :notify, "Can't find function #{value}\n")
      index -> put_slot(s, entity, offset, index)
    end
  end

  defp put_value(s, _entity, _def, _value), do: s

  defp put_slot(s, entity, offset, value),
    do: %{s | qc: QuakeC.put_field_slot(s.qc, entity, offset, value)}

  defp field(s, name), do: Map.get(s.qc.progs.field_defs, name)

  defp fields(s) do
    s.qc.progs.field_defs
    |> Enum.map(fn {name, {type, offset}} -> {name, type, offset} end)
    |> Enum.sort_by(fn {name, _type, offset} -> {offset, name} end)
  end

  defp saved?(name) do
    size = byte_size(name)
    not (size > 2 and binary_part(name, size - 2, 2) in ["_x", "_y", "_z"])
  end

  defp saved_name(s, name, offset, classname) do
    cond do
      not String.contains?(name, "::") -> name
      not String.starts_with?(name, ":") -> nil
      true -> class_field(s, offset, classname) || name
    end
  end

  defp class_field(s, offset, classname) do
    Enum.find_value(fields(s), fn {other, _type, at} ->
      if at == offset and String.starts_with?(other, classname <> ":"), do: other
    end)
  end

  defp classname(s, entity) do
    case field(s, "classname") do
      {_type, offset} -> QuakeC.string(s.qc, QuakeC.field_slot(s.qc, entity, offset))
      nil -> ""
    end
  end

  defp zero?(s, entity, :vector, offset),
    do: Enum.all?(0..2, &zero_value?(QuakeC.field_slot(s.qc, entity, offset + &1)))

  defp zero?(s, entity, _type, offset), do: zero_value?(QuakeC.field_slot(s.qc, entity, offset))

  defp zero_value?(value) when is_number(value), do: value == 0
  defp zero_value?(_value), do: false

  defp value_text(s, entity, :string, offset) do
    s.qc
    |> QuakeC.string(QuakeC.field_slot(s.qc, entity, offset))
    |> String.replace(["\n", "\"", "\\"], fn
      "\n" -> "\\n"
      other -> "\\" <> other
    end)
  end

  defp value_text(s, entity, :entity, offset),
    do: integer_text(QuakeC.field_slot(s.qc, entity, offset))

  defp value_text(s, entity, :integer, offset),
    do: integer_text(QuakeC.field_slot(s.qc, entity, offset))

  defp value_text(s, entity, :function, offset) do
    index = trunc(QuakeC.float(QuakeC.field_slot(s.qc, entity, offset)))

    if index >= 0 and index < tuple_size(s.qc.progs.functions),
      do: "0:" <> elem(s.qc.progs.functions, index).name,
      else: "0:CORRUPT FUNCTION POINTER"
  end

  defp value_text(s, entity, :field, offset) do
    at = trunc(QuakeC.float(QuakeC.field_slot(s.qc, entity, offset)))

    case Enum.find(fields(s), fn {_name, _type, o} -> o == at end) do
      {name, _type, _o} -> name
      nil -> "bad field 5"
    end
  end

  defp value_text(_s, _entity, :void, _offset), do: "void"

  defp value_text(s, entity, :float, offset),
    do: s.qc |> QuakeC.field_slot(entity, offset) |> QuakeC.float() |> float_text()

  defp value_text(s, entity, :vector, offset) do
    parts = Enum.map(0..2, &QuakeC.float(QuakeC.field_slot(s.qc, entity, offset + &1)))

    if Enum.all?(parts, &whole?/1),
      do: Enum.map_join(parts, " ", &Integer.to_string(trunc(&1))),
      else: Enum.map_join(parts, " ", &format_g/1)
  end

  defp value_text(s, entity, :pointer, offset) do
    case trunc(QuakeC.float(QuakeC.field_slot(s.qc, entity, offset))) do
      0 -> "0"
      address -> "0x" <> String.downcase(Integer.to_string(band(address, 0xFFFFFFFF), 16))
    end
  end

  defp integer_text(value), do: Integer.to_string(trunc(QuakeC.float(value)))

  defp float_text(value) do
    if whole?(value), do: Integer.to_string(trunc(value)), else: format_f(value)
  end

  defp whole?(value), do: abs(value) < 2.147_483_648e9 and value == trunc(value)

  defp format_f(value), do: :erlang.float_to_binary(value / 1, decimals: 6)

  defp format_g(value) when value == 0, do: "0"

  defp format_g(value) do
    exponent = value |> abs() |> :math.log10() |> floor()

    if exponent < -4 or exponent >= 6 do
      mantissa = value / :math.pow(10, exponent)
      digits = mantissa |> :erlang.float_to_binary(decimals: 5) |> strip_zeros()
      sign = if exponent < 0, do: "-", else: "+"
      digits <> "e" <> sign <> String.pad_leading(Integer.to_string(abs(exponent)), 2, "0")
    else
      value |> :erlang.float_to_binary(decimals: max(5 - exponent, 0)) |> strip_zeros()
    end
  end

  defp strip_zeros(text) do
    if String.contains?(text, "."),
      do: text |> String.trim_trailing("0") |> String.trim_trailing("."),
      else: text
  end

  defp strtod(text) do
    trimmed = String.trim_leading(text, " ")

    case Regex.run(~r/^[\t\n\v\f\r ]*([+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?)/, trimmed) do
      [whole, number | _] ->
        rest = binary_part(trimmed, byte_size(whole), byte_size(trimmed) - byte_size(whole))
        {parse_float(number), rest}

      nil ->
        {0.0, text}
    end
  end

  defp parse_float(number) do
    normalized =
      number
      |> String.replace(~r/^([+-]?)\./, "\\g{1}0.")
      |> String.replace(~r/\.(?=[eE]|$)/, ".0")
      |> String.replace(~r/^([+-]?\d+)([eE])/, "\\g{1}.0\\g{2}")

    normalized = if String.contains?(normalized, "."), do: normalized, else: normalized <> ".0"
    String.to_float(normalized)
  end

  defp strtol(text) do
    trimmed = String.trim_leading(text)

    {sign, digits} =
      case trimmed do
        "-" <> rest -> {-1, rest}
        "+" <> rest -> {1, rest}
        rest -> {1, rest}
      end

    value =
      cond do
        String.starts_with?(digits, ["0x", "0X"]) -> leading(String.slice(digits, 2..-1//1), 16)
        String.starts_with?(digits, "0") -> leading(digits, 8)
        true -> leading(digits, 10)
      end

    sign * value
  end

  defp leading(text, base) do
    case Integer.parse(text, base) do
      {value, _rest} -> value
      :error -> 0
    end
  end

  defp listed?(s, entity, offset, type) do
    cond do
      Edicts.free?(s, entity) -> false
      type == 1 -> not readonly?(s, entity) and string_match?(s, entity, offset)
      type == 3 -> Enum.all?(0..2, &(number(s, entity, offset + &1) == elem(Args.vec(s, 1), &1)))
      type == 2 -> number(s, entity, offset) == Args.num(s, 1)
      type in 10..12 -> pair(s, entity, offset) == {QuakeC.slot(s.qc, 7), QuakeC.slot(s.qc, 8)}
      true -> QuakeC.field_slot(s.qc, entity, offset) == Args.slot(s, 1)
    end
  end

  defp number(s, entity, offset), do: QuakeC.float(QuakeC.field_slot(s.qc, entity, offset))

  defp pair(s, entity, offset),
    do: {QuakeC.field_slot(s.qc, entity, offset), QuakeC.field_slot(s.qc, entity, offset + 1)}

  defp string_match?(s, entity, offset) do
    case QuakeC.field_slot(s.qc, entity, offset) do
      0 -> false
      value -> QuakeC.string(s.qc, value) == Args.str(s, 1)
    end
  end

  defp readonly?(s, entity),
    do: s.ext |> Map.get(:readonly, MapSet.new()) |> MapSet.member?(entity)

  defp put_count(s, count), do: %{s | qc: QuakeC.put_slot(s.qc, 13, count)}

  defp trailing?(text, used),
    do: text |> binary_part(used, byte_size(text) - used) |> skip_controls() != ""

  defp skip_controls(<<c, rest::binary>>) when c < 32, do: skip_controls(rest)
  defp skip_controls(text), do: text

  defp warn(s, text), do: Events.print(s, :notify, text)

  @doc "The next token of `text` as QuakeC's `QCC_COM_Parse` reads it and the text after it, or `:eof`."
  @spec token(String.t()) :: {String.t(), String.t()} | :eof
  def token(text) do
    case skip(text) do
      "" -> :eof
      <<?", rest::binary>> -> quoted(rest, [])
      <<c, rest::binary>> when c in ~c"{})(':," -> {<<c>>, rest}
      rest -> word(rest, [])
    end
  end

  defp skip(<<c, rest::binary>>) when c in [?\s, ?\r, ?\n, ?\t, ?\v], do: skip(rest)
  defp skip(<<"//", rest::binary>>), do: rest |> drop_line() |> skip()
  defp skip(<<"/*", rest::binary>>), do: rest |> drop_block() |> skip()
  defp skip(text), do: text

  defp drop_line(text) do
    case :binary.match(text, "\n") do
      {at, _} -> binary_part(text, at, byte_size(text) - at)
      :nomatch -> ""
    end
  end

  defp drop_block(text) do
    case :binary.match(text, "*/") do
      {at, _} -> binary_part(text, at + 2, byte_size(text) - at - 2)
      :nomatch -> ""
    end
  end

  defp quoted(<<?\\, ?", rest::binary>>, acc), do: quoted(rest, [?" | acc])
  defp quoted(<<?\\, ?\\, rest::binary>>, acc), do: quoted(rest, [?\\ | acc])
  defp quoted(<<?\\, ?n, rest::binary>>, acc), do: quoted(rest, [?\n | acc])
  defp quoted(<<?\\, ?r, rest::binary>>, acc), do: quoted(rest, [?\r | acc])
  defp quoted(<<?\\, ?t, rest::binary>>, acc), do: quoted(rest, [?\t | acc])
  defp quoted(<<?", rest::binary>>, acc), do: {done(acc), rest}
  defp quoted(<<>>, acc), do: {done(acc), ""}

  defp quoted(<<c, rest::binary>>, [?" | _] = acc) when c in [?\n, ?\r], do: {done(acc), rest}
  defp quoted(<<c, rest::binary>>, acc), do: quoted(rest, [c | acc])

  defp word(<<c, _::binary>> = rest, acc) when c in ~c"{})(':\",", do: {done(acc), rest}

  defp word(<<c, _::binary>> = rest, acc) when c in [?\s, ?\r, ?\n, ?\t, ?\v],
    do: {done(acc), rest}

  defp word(<<c, rest::binary>>, acc), do: word(rest, [c | acc])
  defp word(<<>>, acc), do: {done(acc), ""}

  defp done(acc), do: acc |> Enum.reverse() |> :binary.list_to_bin()
end
