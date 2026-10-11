defmodule QuakeServer.Spawn do
  @moduledoc """
  A map's entities brought to life: the first is the world itself, every later one a
  fresh entity; each has its keys written into its fields and then its spawn function
  run with it as `self`.

      server = QuakeServer.Spawn.entities(server, entity_text)

  A program that defines `CheckSpawn` decides for itself: it is called for every entity,
  the world included, with the entity's spawn function (`spawnfunc_<classname>`, else
  `<classname>`, else none) as its argument and the entity's text in the global
  `__fullspawndata`. Otherwise the function named by `classname` is run, and entities
  whose spawn flags the server's `inhibit` rule rejects, or with no classname or no
  function, are not made.

  Keys become fields by the program's field definitions: `angle` is the yaw of
  `angles`, `light` is `light_lev`, and keys beginning `_` are ignored. A function key
  is a function's name, optionally after a program number and `:` (`0:name`); a number
  and `:` alone is no function, and a name the program lacks is printed and the field left
  as it is, as FTE's `ED_ParseEpair` reads them. Numbers are read as C's `strtod` (a
  float, or each of a vector's three words, as a 32-bit float) and `strtol` in base 0
  (an integer or entity field), `QuakeServer.TextNumbers`.
  """

  alias Cauldron3D.Formats.Entities
  alias QuakeC.Progs
  alias QuakeServer.{Edicts, Events, Server, TextNumbers}

  @doc "Spawn every entity of `text` into `server`."
  @spec entities(Server.t(), String.t()) :: Server.t()
  def entities(%Server{} = server, text) do
    check = Progs.function(server.qc.progs, "CheckSpawn")

    text
    |> Entities.blocks()
    |> Enum.with_index()
    |> Enum.reduce(server, fn {{block, keys}, index}, acc ->
      if check,
        do: check_spawn(acc, check, block, keys, index == 0),
        else: spawn_one(acc, keys, index == 0)
    end)
  end

  defp check_spawn(server, check, block, keys, world?) do
    {server, entity} = if world?, do: {server, 0}, else: Edicts.alloc(server)
    server = fill(server, entity, keys)
    classname = Map.get(keys, "classname", "")
    progs = server.qc.progs

    spawnfunc =
      Progs.function(progs, "spawnfunc_" <> classname) || Progs.function(progs, classname) || 0

    qc =
      server.qc
      |> QuakeC.put_declared("__fullspawndata", block)
      |> QuakeC.put_slot(4, spawnfunc)

    Server.run(%{server | qc: qc}, check, entity, 0)
  end

  @doc "Write `keys` into `entity`'s fields."
  @spec fill(Server.t(), non_neg_integer(), map()) :: Server.t()
  def fill(%Server{} = server, entity, keys) do
    Enum.reduce(keys, server, fn {key, value}, acc -> put_key(acc, entity, key, value) end)
  end

  defp spawn_one(server, keys, world?) do
    {server, entity} = if world?, do: {server, 0}, else: Edicts.alloc(server)
    server = fill(server, entity, keys)
    spawnflags = Edicts.float(server, entity, "spawnflags")
    classname = Map.get(keys, "classname")

    cond do
      not world? and server.inhibit.(spawnflags, clamp_skill(server.skill)) ->
        Edicts.free(server, entity)

      classname == nil ->
        Edicts.free(server, entity)

      true ->
        case Progs.function(server.qc.progs, classname) do
          nil ->
            server
            |> Events.print(:notify, "no spawn function for #{classname}")
            |> Edicts.free(entity)

          function ->
            Server.run(server, function, entity, 0)
        end
    end
  end

  defp clamp_skill(skill), do: skill |> round() |> max(0) |> min(3)

  defp put_key(server, entity, "angle", value),
    do: put_key(server, entity, "angles", "0 #{value} 0")

  defp put_key(server, entity, "light", value), do: put_key(server, entity, "light_lev", value)
  defp put_key(server, _entity, "_" <> _, _value), do: server

  defp put_key(server, entity, key, value) do
    case QuakeC.field_type(server.qc, key) do
      nil -> server
      :function -> put_function(server, entity, key, value)
      type -> Edicts.put(server, entity, key, parse(server, type, value))
    end
  end

  defp put_function(server, entity, key, <<_, ?:>>), do: Edicts.put(server, entity, key, 0)

  defp put_function(server, entity, key, value) do
    case Progs.find_function(server.qc.progs, value) do
      nil -> Events.print(server, :notify, "Can't find function #{value}\n")
      function -> Edicts.put(server, entity, key, function)
    end
  end

  defp parse(_server, :string, value), do: unescape(value)

  defp parse(_server, :float, value),
    do: value |> TextNumbers.strtod() |> elem(0) |> TextNumbers.float32()

  defp parse(_server, :vector, value), do: vector(value)

  defp parse(_server, :entity, value),
    do: value |> TextNumbers.strtol() |> elem(0) |> TextNumbers.int32()

  defp parse(_server, :integer, value),
    do: value |> TextNumbers.strtol() |> elem(0) |> TextNumbers.int32()

  defp parse(server, :field, value), do: QuakeC.field_offset(server.qc, value) || 0
  defp parse(_server, _type, value), do: value

  defp unescape(value), do: String.replace(value, "\\n", "\n")

  defp vector(value) do
    {x, rest} = TextNumbers.strtod(value)
    {y, rest} = TextNumbers.strtod(rest)
    {z, _rest} = TextNumbers.strtod(rest)
    {TextNumbers.float32(x), TextNumbers.float32(y), TextNumbers.float32(z)}
  end
end
