defmodule QuakeServer.EntityTable do
  @moduledoc """
  The entity references in a file the program carries from one level to the next,
  translated by Half-Life's level transition rule (GoldSrc's engine and the HLSDK's
  `CSaveRestoreBuffer`: a saved reference is an index into the save's entity table,
  restored as the entity that table entry was restored into, and as null when the entry
  was not carried into the level). The rule is Half-Life's (GoldSrc and the HLSDK), not
  FreeHL's under FTE, where a number read back is the entity of that number in the new
  level whatever it now is.

  A file the program writes is read as entity text: blocks of lines between a `{` line
  and a `}` line. A block's entry in the file's entity table is the first entity other
  than the world the program runs as (`self`) while writing a line of the block, or none.
  The table is kept with the written file when the program closes it
  (`ext.entity_tables`, by the file's name under `data/`), moves with `frename`, is
  dropped with the file (`fremove`), and goes to the next level with the program's
  written files (`carry/1`, the server option `:entity_tables`).

  While the program reads a carried file, from `fopen` until `fgets` reaches its end,
  `fclose` closes it or `fremove` removes it, the entity the program runs as during a
  block's lines, other than the world and the entity reading the file, is the entity the
  block was restored into, and `edict_num` translates the number it is given
  (`entity/2`):

    * the world and the player slots are kept: a player keeps its slot from level to
      level
    * an entity with a block becomes the entity the block was restored into; the world
      when the block was read without being restored into an entity or that entity has
      been freed
    * an entity with a block not yet read becomes an entity set aside for the block;
      when the reading ends every entity field holding it is set to the entity the block
      was restored into, or the world, and the set-aside entity is freed
    * any other number becomes the world: an entity of the level left that was not
      carried restores as null

  A program reading a carried file, in QuakeC:

      fh = fopen("trans.dat", FILE_READ);
      while ((line = fgets(fh))) { ... e.owner = edict_num(stof(value)); ... }
  """

  alias QuakeServer.{Args, Edicts}

  @typedoc "A written file's entity table: each block's entity, in order, and whether it came from an earlier level."
  @type t :: %{entities: [non_neg_integer() | nil], carried: boolean()}

  @doc """
  Note on write file `file` (Store's file map, `mode: :write`) the blocks of `text`, written
  as entity `writer`.
  """
  @spec record(map(), String.t(), non_neg_integer()) :: map()
  def record(%{mode: :write} = file, text, writer) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(file, &record_line(&2, String.trim(&1), writer))
  end

  def record(file, _text, _writer), do: file

  @doc "Keep the entity table of write file `file`, closed by the program, under its name."
  @spec keep(map(), map()) :: map()
  def keep(s, %{mode: :write, name: name} = file) do
    case Map.get(file, :blocks, []) do
      [] ->
        forget(s, name)

      blocks ->
        put_tables(s, Map.put(tables(s), name, %{entities: Enum.reverse(blocks), carried: false}))
    end
  end

  def keep(s, _file), do: s

  @doc "Drop the entity table of written file `name`, ending a reading of it."
  @spec forget(map(), String.t()) :: map()
  def forget(s, name) do
    s = put_tables(s, Map.delete(tables(s), name))

    case s.ext do
      %{entity_table_reading: %{name: ^name, handle: handle}} -> finish(s, handle)
      _ -> s
    end
  end

  @doc "Move the entity table of written file `from` to `to`."
  @spec rename(map(), String.t(), String.t()) :: map()
  def rename(s, from, to) do
    case Map.pop(tables(s), from) do
      {nil, _tables} -> s
      {table, tables} -> put_tables(s, Map.put(tables, to, table))
    end
  end

  @doc "The entity tables `tables` (a level's `ext.entity_tables`) as the next level takes them."
  @spec carry(%{String.t() => t()}) :: %{String.t() => t()}
  def carry(tables), do: Map.new(tables, fn {name, table} -> {name, %{table | carried: true}} end)

  @doc """
  Begin translating entity numbers if file `handle`, opened for reading from written
  file `name`, has a carried entity table.
  """
  @spec open(map(), pos_integer(), String.t()) :: map()
  def open(s, handle, name) do
    case Map.get(tables(s), name) do
      %{carried: true, entities: entities} ->
        reading = %{
          handle: handle,
          name: name,
          index: index(entities),
          restored: %{},
          set_aside: %{},
          block: nil,
          blocks: 0,
          reader: 0
        }

        s |> finish_reading() |> put_reading(reading)

      _ ->
        s
    end
  end

  @doc "Follow the line `line` the program read from file `handle`."
  @spec read(map(), pos_integer(), String.t()) :: map()
  def read(%{ext: %{entity_table_reading: %{handle: handle} = reading}} = s, handle, line),
    do: put_reading(s, read_line(%{reading | reader: Args.self(s)}, String.trim(line)))

  def read(s, _handle, _line), do: s

  @doc "Note the entity the program runs as, while it reads a block of a carried file."
  @spec observe(map()) :: map()
  def observe(%{ext: %{entity_table_reading: %{block: block, restored: restored} = reading}} = s)
      when is_integer(block) and not is_map_key(restored, block) do
    case Args.self(s) do
      entity when entity == 0 or entity == reading.reader -> s
      entity -> put_reading(s, %{reading | restored: Map.put(restored, block, entity)})
    end
  end

  def observe(s), do: s

  @doc """
  The entity `number` stands for: translated through the entity table while the program
  reads a carried file, `number` itself otherwise.
  """
  @spec entity(map(), integer()) :: {map(), integer()}
  def entity(%{ext: %{entity_table_reading: reading}} = s, number) do
    cond do
      number <= Map.get(s, :slots, 0) -> {s, number}
      Map.has_key?(reading.index, number) -> block_entity(s, reading, reading.index[number])
      true -> {s, 0}
    end
  end

  def entity(s, number), do: {s, number}

  @doc "End the translation begun for file `handle`, settling the entities set aside."
  @spec finish(map(), pos_integer()) :: map()
  def finish(%{ext: %{entity_table_reading: %{handle: handle}}} = s, handle),
    do: finish_reading(s)

  def finish(s, _handle), do: s

  defp record_line(file, "{", _writer),
    do: file |> Map.put(:blocks, [nil | Map.get(file, :blocks, [])]) |> Map.put(:in_block, true)

  defp record_line(file, "}", _writer), do: Map.put(file, :in_block, false)

  defp record_line(%{in_block: true, blocks: [nil | blocks]} = file, _line, writer)
       when writer != 0,
       do: %{file | blocks: [writer | blocks]}

  defp record_line(file, _line, _writer), do: file

  defp index(entities) do
    entities
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {nil, _block}, index -> index
      {entity, block}, index -> Map.put_new(index, entity, block)
    end)
  end

  defp read_line(reading, "{"), do: %{reading | block: reading.blocks, blocks: reading.blocks + 1}
  defp read_line(reading, "}"), do: %{reading | block: nil}
  defp read_line(reading, _line), do: reading

  defp block_entity(s, reading, block) do
    case Map.fetch(reading.restored, block) do
      {:ok, entity} -> {s, live_or_world(s, entity)}
      :error -> unrestored(s, reading, block)
    end
  end

  defp unrestored(s, reading, block) do
    cond do
      Map.has_key?(reading.set_aside, block) -> {s, reading.set_aside[block]}
      block < reading.blocks and block != reading.block -> {s, 0}
      true -> set_aside(s, reading, block)
    end
  end

  defp set_aside(s, reading, block) do
    {s, entity} = Edicts.alloc(s)
    {put_reading(s, %{reading | set_aside: Map.put(reading.set_aside, block, entity)}), entity}
  end

  defp finish_reading(%{ext: %{entity_table_reading: reading}} = s) do
    s = %{s | ext: Map.delete(s.ext, :entity_table_reading)}

    Enum.reduce(reading.set_aside, s, fn {block, held}, s ->
      restored = live_or_world(s, Map.get(reading.restored, block, 0))
      s |> redirect(held, restored) |> Edicts.free(held)
    end)
  end

  defp finish_reading(s), do: s

  defp redirect(s, from, to) do
    offsets = for {_name, {:entity, offset}} <- s.qc.progs.field_defs, do: offset

    qc =
      for entity <- Edicts.live(s), offset <- offsets, reduce: s.qc do
        qc ->
          if entity_number(QuakeC.field_slot(qc, entity, offset)) == from,
            do: QuakeC.put_field_slot(qc, entity, offset, to),
            else: qc
      end

    %{s | qc: qc}
  end

  defp entity_number(value) when is_integer(value), do: value
  defp entity_number(value) when is_float(value), do: trunc(value)
  defp entity_number(_value), do: 0

  defp live_or_world(_s, 0), do: 0
  defp live_or_world(s, entity), do: if(Edicts.free?(s, entity), do: 0, else: entity)

  defp tables(s), do: Map.get(s.ext, :entity_tables, %{})

  defp put_tables(s, tables), do: %{s | ext: Map.put(s.ext, :entity_tables, tables)}

  defp put_reading(s, reading), do: %{s | ext: Map.put(s.ext, :entity_table_reading, reading)}
end
