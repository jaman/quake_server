defmodule QuakeServer.Extensions.Things do
  @moduledoc """
  FTE's entity builtins: finding by float, flags and string into chains, entity numbers,
  copying, freeing at once, box traces and tossed traces, potentially-visible checks,
  touching triggers, turning in pitch, attachments, and reading and writing fields by
  their place in the program's field list.

  A field read as text (`getentityfieldstring`, 499) is written as
  `QuakeServer.Extensions.EntityText.value/4` writes it, or null when FTE leaves it out:
  `drawflags` at 96, `uniquespawnid`, `dimension_solid`, `dimension_hit`,
  `dimension_see` and `dimension_seen` at 255, a value whose first word is 0, and a zero
  vector when the program's first field is a vector.

  `edict_num` (459) gives the entity of a number, the world for one out of range; while
  the program reads a file carried from an earlier level the number is first translated
  through the file's entity table (`QuakeServer.EntityTable.entity/2`).
  """

  import Bitwise

  alias Cauldron3D.Vec
  alias QuakeServer.{Args, Builtins, Edicts, EntityTable, Visibility, World}
  alias QuakeServer.Extensions.EntityText

  @doc "Run entity builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 98, _argc) do
    offset = Args.int(s, 1)
    match = Args.slot(s, 2)
    Args.return(s, find(s, Args.int(s, 0), &(field(s, &1, offset) == match)))
  end

  def call(s, 449, _argc) do
    offset = Args.int(s, 1)
    match = trunc(Args.num(s, 2))
    Args.return(s, find(s, Args.int(s, 0), &((as_int(field(s, &1, offset)) &&& match) != 0)))
  end

  def call(s, 402, argc) do
    offset = Args.int(s, 0)
    match = Args.str(s, 1)
    chain(s, argc, 2, &(QuakeC.string(s.qc, field(s, &1, offset)) == match))
  end

  def call(s, 403, argc) do
    offset = Args.int(s, 0)
    match = Args.slot(s, 1)
    chain(s, argc, 2, &(field(s, &1, offset) == match))
  end

  def call(s, 450, argc) do
    offset = Args.int(s, 0)
    match = trunc(Args.num(s, 1))
    chain(s, argc, 2, &((as_int(field(s, &1, offset)) &&& match) != 0))
  end

  def call(s, 459, _argc) do
    {s, entity} = EntityTable.entity(s, Args.int(s, 0))
    Args.return(s, if(entity >= 0 and entity < s.count, do: entity, else: 0))
  end

  def call(s, 512, _argc), do: Args.return(s, Args.int(s, 0) / 1)
  def call(s, 353, _argc), do: Args.return(s, Edicts.free?(s, Args.int(s, 0)))

  def call(s, 400, argc) do
    from = Args.int(s, 0)
    {s, to} = if argc > 1, do: {s, Args.int(s, 1)}, else: Edicts.alloc(s)

    qc =
      Enum.reduce(
        0..(s.qc.size - 1)//1,
        s.qc,
        &QuakeC.put_field_slot(&2, to, &1, QuakeC.field_slot(s.qc, from, &1))
      )

    %{s | qc: qc} |> World.link(to, false) |> Args.return(to)
  end

  def call(s, "removeinstant", _argc), do: Edicts.free(s, Args.int(s, 0))

  def call(s, 90, _argc),
    do:
      Builtins.trace(
        s,
        Args.vec(s, 0),
        Args.vec(s, 1),
        Args.vec(s, 2),
        Args.vec(s, 3),
        Args.num(s, 4),
        Args.int(s, 5)
      )

  def call(s, 64, _argc), do: tracetoss(s, Args.int(s, 0), Args.int(s, 1))

  def call(s, 240, _argc) do
    leaves = Map.get(s.leaves, Args.int(s, 1))
    Args.return(s, Visibility.in_pvs?(s.bsp, Args.vec(s, 0), leaves))
  end

  def call(s, 279, argc) do
    entity = if argc > 0, do: Args.int(s, 0), else: Args.self(s)
    s = if argc > 1, do: Edicts.put(s, entity, "origin", Args.vec(s, 1)), else: s
    World.link(s, entity, true)
  end

  def call(s, 63, _argc), do: change_pitch(s, Args.self(s))

  def call(s, 443, _argc) do
    entity = Args.int(s, 0)
    tag = Args.int(s, 1)

    s
    |> Edicts.put(entity, "tag_entity", tag)
    |> Edicts.put(entity, "tag_index", 0.0)
  end

  def call(s, 496, _argc), do: Args.return(s, length(fields(s)) / 1)

  def call(s, 497, _argc),
    do: Args.return(s, s |> field_at(Args.int(s, 0)) |> elem(0))

  def call(s, 498, _argc),
    do: Args.return(s, s |> field_at(Args.int(s, 0)) |> elem(1) |> type_number())

  def call(s, 499, _argc) do
    index = Args.int(s, 0)
    entity = Args.int(s, 1)

    if index >= 0 and index < length(fields(s)) do
      {name, type, offset} = field_at(s, index)

      if field_left_out?(s, entity, name, offset),
        do: Args.return(s, 0),
        else: Args.return(s, EntityText.value(s, entity, type, offset))
    else
      Args.return(s, 0)
    end
  end

  def call(s, 500, _argc) do
    {name, _type, _offset} = field_at(s, Args.int(s, 0))
    s = QuakeServer.Spawn.fill(s, Args.int(s, 1), %{name => Args.str(s, 2)})
    Args.return(s, true)
  end

  def call(s, "findentityfield", _argc) do
    name = Args.str(s, 0)
    Args.return(s, Enum.find_index(fields(s), &(elem(&1, 0) == name)) || 0)
  end

  def call(s, "entityfieldref", _argc),
    do: Args.return(s, s |> field_at(Args.int(s, 0)) |> elem(2))

  defp find(s, start, match?),
    do: Enum.find((start + 1)..(s.count - 1)//1, 0, &(not Edicts.free?(s, &1) and match?.(&1)))

  defp chain(s, argc, chain_arg, match?) do
    offset =
      if argc > chain_arg, do: Args.int(s, chain_arg), else: QuakeC.field_offset(s.qc, "chain")

    {first, qc} =
      (s.count - 1)..1//-1
      |> Enum.filter(&(not Edicts.free?(s, &1) and match?.(&1)))
      |> Enum.reduce({0, s.qc}, fn entity, {next, qc} ->
        {entity, QuakeC.put_field_slot(qc, entity, offset, next)}
      end)

    Args.return(%{s | qc: qc}, first)
  end

  defp field(s, entity, offset), do: QuakeC.field_slot(s.qc, entity, offset)

  defp as_int(value) when is_integer(value), do: value
  defp as_int(value) when is_float(value), do: trunc(value)
  defp as_int(_value), do: 0

  defp fields(s) do
    s.qc.progs.field_defs
    |> Enum.map(fn {name, {type, offset}} -> {name, type, offset} end)
    |> Enum.sort_by(fn {name, _type, offset} -> {offset, name} end)
  end

  defp field_at(s, index), do: Enum.at(fields(s), index, {"", :void, 0})

  defp type_number(type),
    do:
      Enum.find_index(
        [:void, :string, :float, :vector, :entity, :field, :function, :pointer, :integer],
        &(&1 == type)
      ) || 0

  defp field_left_out?(s, entity, name, offset) do
    value = field(s, entity, offset)

    cond do
      first_field_vector?(s) and Enum.all?(0..2, &(field(s, entity, offset + &1) in [0, 0.0])) ->
        true

      name == "drawflags" and value == 96.0 ->
        true

      name == "uniquespawnid" ->
        true

      name in ~w(dimension_solid dimension_hit dimension_see dimension_seen) and value == 255.0 ->
        true

      true ->
        first_word_zero?(value)
    end
  end

  defp first_field_vector?(s), do: s |> field_at(0) |> elem(1) == :vector

  defp first_word_zero?(0), do: true
  defp first_word_zero?(value) when is_float(value), do: <<value::float-64>> == <<0.0::float-64>>
  defp first_word_zero?(nil), do: true
  defp first_word_zero?(_value), do: false

  defp change_pitch(s, entity) do
    {pitch, yaw, roll} = Edicts.vector(s, entity, "angles")
    ideal = Edicts.float(s, entity, "idealpitch")
    speed = Edicts.float(s, entity, "pitch_speed")
    move = ideal - pitch
    move = move - 360.0 * Float.floor((move + 180.0) / 360.0)
    move = move |> max(-speed) |> min(speed)
    Edicts.put(s, entity, "angles", {pitch + move, yaw, roll})
  end

  defp tracetoss(s, entity, ignore) do
    origin = Edicts.vector(s, entity, "origin")
    velocity = Edicts.vector(s, entity, "velocity")
    mins = Edicts.vector(s, entity, "mins")
    maxs = Edicts.vector(s, entity, "maxs")
    gravity = Edicts.float(s, entity, "gravity")
    gravity = if gravity == 0, do: 1.0, else: gravity
    pull = QuakeServer.Server.cvar(s, "sv_gravity") * gravity * 0.05
    step = %{origin: origin, velocity: velocity, trace: nil}

    final =
      Enum.reduce_while(1..200, step, fn _, acc ->
        {vx, vy, vz} = acc.velocity
        velocity = {vx, vy, vz - pull}
        to = Vec.add(acc.origin, Vec.scale(velocity, 0.05))
        trace = World.move(s, acc.origin, mins, maxs, to, :normal, ignore)
        next = %{origin: trace.end_pos, velocity: velocity, trace: trace}
        if trace.fraction < 1.0 or trace.start_solid, do: {:halt, next}, else: {:cont, next}
      end)

    case final.trace do
      nil -> Builtins.trace(s, final.origin, mins, maxs, final.origin, 0.0, ignore)
      trace -> Builtins.put_trace(s, trace)
    end
  end
end
