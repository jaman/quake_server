defmodule QuakeServer.Visibility do
  @moduledoc """
  What a map's visibility lets a viewer potentially see, as FTE's server works it out for
  Quake and Half-Life maps (`q1bsp.c`): the leaves an entity's box touches, recorded when
  it is linked, and the leaves seen from every leaf within 8 units of a viewer's eye (the
  fat PVS), and the leaves that may hear a point (its PHS).

      leaves = QuakeServer.Visibility.touched(bsp, absmin, absmax)
      sight = QuakeServer.Visibility.fat(bsp, eye)
      QuakeServer.Visibility.seen?(sight, leaves)

  Touched leaves leave out solid ones; more than 32 are `:all`, seen by every viewer. A
  sight is an integer whose bit `i` is set when leaf `i` may be seen, or `:all` on a map
  without visibility or from a leaf that keeps none.
  """

  import Bitwise

  alias Cauldron3D.{Bsp, Vec}

  @most_leaves 32
  @fat 8

  @typedoc "The leaves an entity is in."
  @type leaves :: [non_neg_integer()] | :all

  @typedoc "The leaves a viewer may see."
  @type sight :: non_neg_integer() | :all

  @doc "The non-solid world leaves the box `mins`..`maxs` touches."
  @spec touched(Bsp.t() | nil, Vec.t(), Vec.t()) :: leaves()
  def touched(nil, _mins, _maxs), do: :all

  def touched(%Bsp{} = bsp, mins, maxs) do
    leaves =
      bsp
      |> Bsp.leaves_touching(mins, maxs)
      |> Enum.reverse()
      |> Enum.reject(&(elem(bsp.leaves, &1).contents == Bsp.solid()))

    if length(leaves) > @most_leaves, do: :all, else: leaves
  end

  @doc "The leaves seen from every non-solid leaf within 8 units of `point`."
  @spec fat(Bsp.t() | nil, Vec.t()) :: sight()
  def fat(nil, _point), do: :all
  def fat(%Bsp{visibility: nil}, _point), do: :all

  def fat(%Bsp{} = bsp, point) do
    %{heads: [head | _]} = elem(bsp.models, 0)
    gather(bsp, head, point, 0)
  end

  @doc """
  The leaves that may hear `point` (its PHS): those seen from any leaf its leaf sees.
  `:all` from leaf 0 or a leaf that keeps no visibility.
  """
  @spec heard(Bsp.t() | nil, Vec.t()) :: sight()
  def heard(nil, _point), do: :all
  def heard(%Bsp{visibility: nil}, _point), do: :all

  def heard(%Bsp{} = bsp, point) do
    case Bsp.leaf_at(bsp, point) do
      0 -> :all
      leaf -> hearing(bsp, elem(bsp.visibility, leaf))
    end
  end

  @doc """
  The leaves the leaf `point` is in can see (its PVS); `:all` from leaf 0 or a leaf that
  keeps none. A point on a node's plane is taken to its back side.
  """
  @spec pvs(Bsp.t() | nil, Vec.t()) :: sight()
  def pvs(nil, _point), do: :all
  def pvs(%Bsp{visibility: nil}, _point), do: :all

  def pvs(%Bsp{} = bsp, point) do
    case point_leaf(bsp, point) do
      0 -> :all
      leaf -> row(elem(bsp.visibility, leaf))
    end
  end

  @doc """
  Whether an entity in `leaves`, the leaves recorded when it was last linked (`nil` for
  one never linked), is in the PVS of `point` (`pvs/2`), as FTE's `checkpvs` decides:
  never without a map or for an entity in no leaves, always for one in more than 32,
  otherwise when one of its leaves is in that PVS.
  """
  @spec in_pvs?(Bsp.t() | nil, Vec.t(), leaves() | nil) :: boolean()
  def in_pvs?(nil, _point, _leaves), do: false
  def in_pvs?(_bsp, _point, nil), do: false
  def in_pvs?(_bsp, _point, []), do: false
  def in_pvs?(_bsp, _point, :all), do: true
  def in_pvs?(%Bsp{} = bsp, point, leaves), do: seen?(pvs(bsp, point), leaves)

  @doc """
  Whether FTE builds the map's PHS under the cvar `sv_calcphs` `setting`: never at 0,
  always at 1, and at 2 unless the game is single player or the table would take a
  megabyte or more (a row of whole 32-bit words a world leaf, for each world leaf).
  """
  @spec phs_built?(Bsp.t() | nil, number(), boolean()) :: boolean()
  def phs_built?(nil, _setting, _single_player?), do: false
  def phs_built?(%Bsp{visibility: nil}, _setting, _single_player?), do: false
  def phs_built?(_bsp, setting, _single_player?) when setting == 0, do: false
  def phs_built?(_bsp, setting, _single_player?) when setting == 1, do: true

  def phs_built?(%Bsp{} = bsp, _setting, single_player?) do
    leaves = bsp.world_leaves || tuple_size(bsp.leaves) - 1
    row_bytes = Bitwise.band(Bitwise.bsr(leaves + 31, 3), Bitwise.bnot(3))
    not single_player? and row_bytes * leaves < 0x100000
  end

  @doc "Whether the leaf `point` is in is in `sight`; always for leaf 0."
  @spec point_seen?(Bsp.t() | nil, sight(), Vec.t()) :: boolean()
  def point_seen?(_bsp, :all, _point), do: true
  def point_seen?(nil, _sight, _point), do: true

  def point_seen?(%Bsp{} = bsp, sight, point) do
    case Bsp.leaf_at(bsp, point) do
      0 -> true
      leaf -> (sight >>> leaf &&& 1) == 1
    end
  end

  @doc "Whether any of `leaves` is in `sight`."
  @spec seen?(sight(), leaves()) :: boolean()
  def seen?(:all, _leaves), do: true
  def seen?(_sight, :all), do: true
  def seen?(sight, leaves), do: Enum.any?(leaves, &((sight >>> &1 &&& 1) == 1))

  defp point_leaf(bsp, point) do
    %{heads: [head | _]} = elem(bsp.models, 0)
    descend(bsp, head, point)
  end

  defp descend(_bsp, child, _point) when child < 0, do: -child - 1

  defp descend(bsp, node_index, point) do
    node = elem(bsp.nodes, node_index)
    {normal, distance} = elem(bsp.planes, node.plane)

    if Vec.dot(point, normal) - distance > 0,
      do: descend(bsp, node.front, point),
      else: descend(bsp, node.back, point)
  end

  defp row(nil), do: :all
  defp row(bits), do: :binary.decode_unsigned(bits, :little)

  defp hearing(_bsp, nil), do: :all

  defp hearing(bsp, row) do
    seen = :binary.decode_unsigned(row, :little)

    Enum.reduce_while(0..(tuple_size(bsp.visibility) - 1)//1, 0, fn leaf, heard ->
      cond do
        (seen >>> leaf &&& 1) == 0 -> {:cont, heard}
        elem(bsp.visibility, leaf) == nil -> {:halt, :all}
        true -> {:cont, heard ||| :binary.decode_unsigned(elem(bsp.visibility, leaf), :little)}
      end
    end)
  end

  defp gather(_bsp, _child, _point, :all), do: :all

  defp gather(bsp, child, _point, sight) when child < 0 do
    leaf = -child - 1

    cond do
      elem(bsp.leaves, leaf).contents == Bsp.solid() -> sight
      elem(bsp.visibility, leaf) == nil -> :all
      true -> sight ||| :binary.decode_unsigned(elem(bsp.visibility, leaf), :little)
    end
  end

  defp gather(bsp, node_index, point, sight) do
    node = elem(bsp.nodes, node_index)
    {normal, distance} = elem(bsp.planes, node.plane)
    d = Vec.dot(point, normal) - distance

    cond do
      d > @fat -> gather(bsp, node.front, point, sight)
      d < -@fat -> gather(bsp, node.back, point, sight)
      true -> gather(bsp, node.back, point, gather(bsp, node.front, point, sight))
    end
  end
end
