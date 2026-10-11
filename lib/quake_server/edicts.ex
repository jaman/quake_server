defmodule QuakeServer.Edicts do
  @moduledoc """
  Entities of a running level: making and freeing them, and their fields by name.

      {server, entity} = QuakeServer.Edicts.alloc(server)
      QuakeServer.Edicts.vector(server, entity, "origin")

  A freed entity is reused once half a second has passed, or at once if it was freed in
  the first two seconds of the level.
  """

  alias QuakeServer.{Events, Q, Server, World}

  @first 2

  @doc "A fresh entity, its fields all zero, and the server holding it."
  @spec alloc(Server.t()) :: {Server.t(), non_neg_integer()}
  def alloc(%Server{} = server) do
    reusable =
      Enum.find(@first..(server.count - 1)//1, fn index ->
        case Map.get(server.edicts, index) do
          %{free: true, freetime: freed} -> freed < 2 or server.time - freed > 0.5
          _ -> false
        end
      end)

    case reusable do
      nil -> {clear(%{server | count: server.count + 1}, server.count), server.count}
      index -> {clear(server, index), index}
    end
  end

  @doc """
  `entity` in use with every field zero except those FTE sets on a new entity
  (`ED_Spawned`): `dimension_see`, `dimension_seen`, `dimension_solid` and
  `dimension_hit` at `dimension_default` (255 when the program has none), `Version` and
  `uniquespawnid` at the entity's version count, `drawflags` 96.
  """
  @spec clear(Server.t(), non_neg_integer()) :: Server.t()
  def clear(%Server{} = server, entity) do
    version = Map.get(server.versions, entity, 1) / 1
    seen = dimension_default(server.qc)

    qc =
      Enum.reduce(
        [
          {"dimension_see", seen},
          {"dimension_seen", seen},
          {"dimension_solid", seen},
          {"dimension_hit", seen},
          {"Version", version},
          {"drawflags", 96.0},
          {"uniquespawnid", version}
        ],
        QuakeC.clear_entity(server.qc, entity),
        fn {name, value}, qc -> QuakeC.put_field(qc, entity, name, value) end
      )

    %{
      server
      | qc: qc,
        edicts: Map.put(server.edicts, entity, %{free: false, freetime: 0.0})
    }
  end

  @doc """
  Free `entity`: unlinked, its model, solidity, thinking, `pvsflags` and `SendEntity`
  cleared (and `classname` for a QuakeWorld program), and its version counted up so a
  client program is sent it whole when it is used again. The world, the players and an
  entity already free are not freed; the attempt is printed.
  """
  @spec free(Server.t(), non_neg_integer()) :: Server.t()
  def free(%Server{} = server, entity) do
    cond do
      free?(server, entity) ->
        Events.print(server, :notify, "Tried to free free entity\n")

      entity <= server.slots ->
        Events.print(server, :notify, "cannot free world or player entities\n")

      true ->
        release(server, entity)
    end
  end

  defp release(server, entity) do
    server = World.unlink(server, entity)

    qc =
      Enum.reduce(
        [
          {"pvsflags", 0.0},
          {"SendEntity", 0},
          {"model", 0},
          {"takedamage", 0.0},
          {"modelindex", 0.0},
          {"colormap", 0.0},
          {"skin", 0.0},
          {"frame", 0.0},
          {"origin", {0.0, 0.0, 0.0}},
          {"angles", {0.0, 0.0, 0.0}},
          {"nextthink", -1.0},
          {"solid", 0.0}
        ],
        server.qc,
        fn {name, value}, qc -> QuakeC.put_field(qc, entity, name, value) end
      )

    qc = if quakeworld?(qc), do: QuakeC.put_field(qc, entity, "classname", 0), else: qc

    %{
      server
      | qc: qc,
        edicts: Map.put(server.edicts, entity, %{free: true, freetime: server.time}),
        versions: Map.update(server.versions, entity, 2, &(&1 + 1))
    }
  end

  @doc "Whether `entity` is free (or was never made)."
  @spec free?(Server.t(), non_neg_integer()) :: boolean()
  def free?(%Server{edicts: edicts}, entity) do
    case Map.get(edicts, entity) do
      %{free: free} -> free
      nil -> true
    end
  end

  @doc "The entities in use, world and player included, in order."
  @spec live(Server.t()) :: [non_neg_integer()]
  def live(%Server{} = server),
    do: for(index <- 0..(server.count - 1)//1, not free?(server, index), do: index)

  @doc "Field `name` of `entity`."
  @spec get(Server.t(), non_neg_integer(), String.t()) :: QuakeC.value()
  def get(%Server{qc: qc}, entity, name), do: QuakeC.field(qc, entity, name)

  @doc "Field `name` of `entity` as a float."
  @spec float(Server.t(), non_neg_integer(), String.t()) :: float()
  def float(%Server{qc: qc}, entity, name), do: QuakeC.float(QuakeC.field(qc, entity, name))

  @doc "Field `name` of `entity` as an integer (an entity number or function index)."
  @spec int(Server.t(), non_neg_integer(), String.t()) :: integer()
  def int(%Server{qc: qc}, entity, name), do: trunc(QuakeC.float(QuakeC.field(qc, entity, name)))

  @doc "Vector field `name` of `entity`."
  @spec vector(Server.t(), non_neg_integer(), String.t()) :: QuakeC.vector()
  def vector(%Server{qc: qc}, entity, name), do: QuakeC.field_vector(qc, entity, name)

  @doc "String field `name` of `entity` as text."
  @spec string(Server.t(), non_neg_integer(), String.t()) :: String.t()
  def string(%Server{qc: qc}, entity, name), do: QuakeC.string(qc, QuakeC.field(qc, entity, name))

  @doc "Set field `name` of `entity`."
  @spec put(Server.t(), non_neg_integer(), String.t(), QuakeC.value() | QuakeC.vector()) ::
          Server.t()
  def put(%Server{} = server, entity, name, value),
    do: %{server | qc: QuakeC.put_field(server.qc, entity, name, value)}

  @doc "Whether `entity` has flag `flag` set."
  @spec flag?(Server.t(), non_neg_integer(), atom()) :: boolean()
  def flag?(server, entity, flag), do: Q.flag?(float(server, entity, "flags"), flag)

  @doc "Set flag `flag` on `entity`."
  @spec set_flag(Server.t(), non_neg_integer(), atom()) :: Server.t()
  def set_flag(server, entity, flag),
    do: put(server, entity, "flags", Q.set_flag(float(server, entity, "flags"), flag))

  @doc "Clear flag `flag` on `entity`."
  @spec clear_flag(Server.t(), non_neg_integer(), atom()) :: Server.t()
  def clear_flag(server, entity, flag),
    do: put(server, entity, "flags", Q.clear_flag(float(server, entity, "flags"), flag))

  defp quakeworld?(qc), do: qc.progs.crc == 54_730

  defp dimension_default(qc) do
    if QuakeC.global?(qc, "dimension_default"),
      do: QuakeC.float(QuakeC.global(qc, "dimension_default")),
      else: 255.0
  end
end
