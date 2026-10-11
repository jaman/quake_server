defmodule QuakeServer.World.Area do
  @moduledoc """
  The grid linked entities are filed in: 128 by 128 cells across the world model's
  ground, each at least 128 units wide, and one list for entities too large for it.

  An entity whose box spans more than 16 cells, or reaches the grid's last row or column,
  goes in the large list; any other is filed in every cell its box covers. Each cell
  keeps its entities in the order they were filed. `entities/3` lists those whose cells
  a box covers: the large list first, then the cells column by column, each entity once.

      grid = QuakeServer.World.Area.grid(world_mins, world_maxs)
      cells = QuakeServer.World.Area.cells(grid, absmin, absmax)
      area = QuakeServer.World.Area.file(area, entity, cells)
      QuakeServer.World.Area.entities(area, grid, {mins, maxs})
  """

  alias Cauldron3D.Vec

  @size 128
  @per_entity 16

  @type grid :: %{scale: {float(), float()}, bias: {float(), float()}}
  @type cell :: non_neg_integer() | :large

  @doc "The grid over a world model whose bounds are `mins`..`maxs`."
  @spec grid(Vec.t(), Vec.t()) :: grid()
  def grid({x0, y0, _}, {x1, y1, _}) do
    {scale_x, bias_x} = axis(x0, x1)
    {scale_y, bias_y} = axis(y0, y1)
    %{scale: {scale_x, scale_y}, bias: {bias_x, bias_y}}
  end

  @doc "The cells an entity with box `absmin`..`absmax` is filed in."
  @spec cells(grid(), Vec.t(), Vec.t()) :: [cell()]
  def cells(grid, absmin, absmax) do
    {ming_x, ming_y, maxg_x, maxg_y} = bounds(grid, absmin, absmax)

    if (maxg_x - ming_x) * (maxg_y - ming_y) > @per_entity or ming_x < 0 or ming_y < 0 or
         maxg_x >= @size or maxg_y >= @size,
       do: [:large],
       else:
         for(gx <- ming_x..(maxg_x - 1)//1, gy <- ming_y..(maxg_y - 1)//1, do: gx + gy * @size)
  end

  @doc "`entity` added to the end of each of `cells`."
  @spec file(map(), non_neg_integer(), [cell()]) :: map()
  def file(area, entity, cells),
    do: Enum.reduce(cells, area, &Map.update(&2, &1, [entity], fn filed -> filed ++ [entity] end))

  @doc "`entity` taken out of each of `cells`."
  @spec unfile(map(), non_neg_integer(), [cell()]) :: map()
  def unfile(area, entity, cells), do: Enum.reduce(cells, area, &remove(&2, &1, entity))

  @doc "The entities filed in the large list and in the cells box `{mins, maxs}` covers, in order, each once."
  @spec entities(map(), grid(), {Vec.t(), Vec.t()}) :: [non_neg_integer()]
  def entities(area, grid, {mins, maxs}) do
    {ming_x, ming_y, maxg_x, maxg_y} = bounds(grid, mins, maxs)

    cells =
      for gx <- ming_x..(maxg_x - 1)//1, gy <- ming_y..(maxg_y - 1)//1, do: gx + gy * @size

    {listed, _seen} =
      [:large | cells]
      |> Enum.flat_map(&Map.get(area, &1, []))
      |> Enum.reduce({[], MapSet.new()}, fn entity, {listed, seen} ->
        if MapSet.member?(seen, entity),
          do: {listed, seen},
          else: {[entity | listed], MapSet.put(seen, entity)}
      end)

    Enum.reverse(listed)
  end

  defp axis(low, high) do
    size = (high - low) / @size

    if size < 128,
      do: {128.0, -(low - (128 - size) / 2 * @size)},
      else: {size, -low}
  end

  defp bounds(%{scale: {sx, sy}, bias: {bx, by}}, {x0, y0, _}, {x1, y1, _}) do
    ming_x = (x0 + bx) |> Kernel./(sx) |> floor() |> clamp(0, @size - 1)
    ming_y = (y0 + by) |> Kernel./(sy) |> floor() |> clamp(0, @size - 1)
    maxg_x = (x1 + bx) |> Kernel./(sx) |> floor() |> clamp(ming_x, @size - 1)
    maxg_y = (y1 + by) |> Kernel./(sy) |> floor() |> clamp(ming_y, @size - 1)
    {ming_x, ming_y, maxg_x + 1, maxg_y + 1}
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp remove(area, cell, entity) do
    case Map.get(area, cell) do
      nil -> area
      filed -> put_cell(area, cell, List.delete(filed, entity))
    end
  end

  defp put_cell(area, cell, []), do: Map.delete(area, cell)
  defp put_cell(area, cell, filed), do: Map.put(area, cell, filed)
end
