defmodule QuakeServer.Extensions.Json do
  @moduledoc """
  FTE's JSON builtins: `json_parse` lays the parsed tree out in the program's memory and
  returns its root node's address (null when the text is not JSON); the others read a
  node: `json_get_value_type` (0 string, 1 number, 2 object, 3 array, 4 true, 5 false,
  6 null), `json_get_name`, `json_get_integer`, `json_get_float`, `json_get_string`,
  `json_get_length`, `json_get_child_at_index` and `json_find_object_child` (null when
  absent). `json_free` gives the tree's memory back. A null node reads as JSON null.
  `js_run_script` returns null, as FTE does outside its web build.

  A node is four words: its type, its name (a string, or 0), and either a number, a
  string, or the address of its first child and its child count; an object's or array's
  children are laid out one after another.
  """

  alias QuakeServer.Args
  alias QuakeServer.Extensions.Strings

  @string 0
  @number 1
  @object 2
  @array 3
  @true_value 4
  @false_value 5
  @null 6
  @node 16

  @doc "Run JSON builtin `builtin`."
  @spec call(map(), String.t(), non_neg_integer()) :: map()
  def call(s, "json_parse", _argc) do
    case JSON.decode(Args.str(s, 0), nil, object_finish: &ordered/2) do
      {value, nil, ""} ->
        {qc, root} = QuakeC.alloc(s.qc, @node * count(value))
        {qc, _next} = lay_out(qc, root, root + @node, 0, value)
        Args.return(%{s | qc: qc}, root)

      _failed ->
        Args.return(s, 0)
    end
  end

  def call(s, "json_free", _argc), do: %{s | qc: QuakeC.free(s.qc, Args.int(s, 0))}

  def call(s, "json_get_value_type", _argc), do: Args.return(s, type(s, Args.int(s, 0)))
  def call(s, "json_get_name", _argc), do: Args.return(s, word(s, Args.int(s, 0), 1))

  def call(s, "json_get_integer", _argc) do
    node = Args.int(s, 0)

    case type(s, node) do
      t when t in [@number, @true_value, @false_value] -> Args.return(s, trunc(number(s, node)))
      @string -> Args.return(s, leading_integer(QuakeC.string(s.qc, word(s, node, 2))))
      _ -> Args.return(s, 0)
    end
  end

  def call(s, "json_get_float", _argc) do
    node = Args.int(s, 0)

    case type(s, node) do
      t when t in [@number, @true_value, @false_value] ->
        Args.return(s, number(s, node))

      @string ->
        Args.return(
          s,
          Strings.number(QuakeC.string(s.qc, word(s, node, 2)))
        )

      _ ->
        Args.return(s, 0.0)
    end
  end

  def call(s, "json_get_string", _argc) do
    node = Args.int(s, 0)
    if type(s, node) == @string, do: Args.return(s, word(s, node, 2)), else: Args.return(s, 0)
  end

  def call(s, "json_get_length", _argc) do
    node = Args.int(s, 0)

    if type(s, node) in [@object, @array],
      do: Args.return(s, word(s, node, 3)),
      else: Args.return(s, 0)
  end

  def call(s, "json_get_child_at_index", _argc) do
    node = Args.int(s, 0)
    index = Args.int(s, 1)

    if type(s, node) in [@object, @array] and index >= 0 and index < word(s, node, 3),
      do: Args.return(s, word(s, node, 2) + index * @node),
      else: Args.return(s, 0)
  end

  def call(s, "json_find_object_child", _argc) do
    node = Args.int(s, 0)
    name = Args.str(s, 1)

    found = if type(s, node) in [@object, @array], do: child_named(s, node, name), else: 0
    Args.return(s, found)
  end

  def call(s, "js_run_script", _argc), do: Args.return(s, 0)

  defp child_named(s, node, name) do
    first = word(s, node, 2)
    Enum.find_value(0..(word(s, node, 3) - 1)//1, 0, &named(s, first + &1 * @node, name))
  end

  defp named(s, child, name),
    do: if(QuakeC.string(s.qc, word(s, child, 1)) == name, do: child)

  defp ordered(pairs, outer), do: {{:object, Enum.reverse(pairs)}, outer}

  defp count({:object, pairs}), do: 1 + Enum.sum(Enum.map(pairs, fn {_k, v} -> count(v) end))
  defp count(value) when is_list(value), do: 1 + Enum.sum(Enum.map(value, &count/1))
  defp count(_value), do: 1

  defp lay_out(qc, at, next, name, {:object, pairs}),
    do: lay_out_children(qc, at, next, name, @object, pairs)

  defp lay_out(qc, at, next, name, value) when is_list(value),
    do: lay_out_children(qc, at, next, name, @array, Enum.map(value, &{0, &1}))

  defp lay_out(qc, at, next, name, value) do
    {type, payload} =
      case value do
        text when is_binary(text) -> {@string, text}
        true -> {@true_value, 1.0}
        false -> {@false_value, 0.0}
        nil -> {@null, 0.0}
        number -> {@number, number / 1}
      end

    {put_node(qc, at, type, name, payload, 0), next}
  end

  defp lay_out_children(qc, at, first, name, type, children) do
    qc = put_node(qc, at, type, name, first, length(children))
    after_children = first + @node * length(children)

    {qc, next} =
      children
      |> Enum.with_index()
      |> Enum.reduce({qc, after_children}, fn {{key, child}, i}, {qc, next} ->
        lay_out(qc, first + i * @node, next, key, child)
      end)

    {qc, next}
  end

  defp put_node(qc, at, type, name, payload, count) do
    qc
    |> QuakeC.store(at, type)
    |> QuakeC.store(at + 4, name)
    |> QuakeC.store(at + 8, payload)
    |> QuakeC.store(at + 12, count)
  end

  defp type(_s, 0), do: @null

  defp type(s, node) do
    case QuakeC.load(s.qc, node) do
      value when is_integer(value) -> value
      _ -> @null
    end
  end

  defp word(_s, 0, _index), do: 0
  defp word(s, node, index), do: QuakeC.load(s.qc, node + 4 * index)

  defp number(s, node), do: QuakeC.float(word(s, node, 2))

  defp leading_integer(text) do
    case Integer.parse(String.trim_leading(text)) do
      {value, _rest} -> value
      :error -> 0
    end
  end
end
