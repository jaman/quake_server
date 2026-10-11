defmodule QuakeServer.World.Hulls do
  @moduledoc """
  Boxes moved through a brush model's collision hulls, stopped by the contents a mask of
  `QuakeServer.Contents` bits names.

  `choose/4` picks the hull a box of `mins`..`maxs` moves through and the offset from the
  box to that hull; `trace/8` moves the box through it, in the model's own space, turned
  by `axes` when the model is turned; `check/5` moves a point through one hull.

      {hull, offset} = QuakeServer.World.Hulls.choose(model.hulls, 0, mins, maxs)
      trace = QuakeServer.World.Hulls.trace(model.hulls, 0, nil, from, to, mins, maxs, mask)

  `hulls` is a brush model's list, hull 0 first. A hull is there to use when the list
  holds it and, past hull 0, its first clipnode is one of its clipnodes.
  """

  import Bitwise

  alias Cauldron3D.{Hull, Vec}
  alias QuakeServer.Contents
  alias QuakeServer.World.Trace

  @epsilon 0.03125
  @max_hulls 8

  @type axes :: {Vec.t(), Vec.t(), Vec.t()} | nil

  @doc """
  The hull a box of `mins`..`maxs` moves through, and what to take from a point of the
  box's to place it in that hull. `force`, from 1, names a hull to use when it is there;
  otherwise the box's width and height choose: under 3 wide the point hull, up to 32.1
  wide hull 3 when under 54.1 high or else hull 1, wider hull 2, each falling back to a
  smaller hull that is there.
  """
  @spec choose([Hull.t()], integer(), Vec.t(), Vec.t()) :: {Hull.t(), Vec.t()}
  def choose(hulls, force, mins, maxs) do
    hull = pick(hulls, force, Vec.sub(maxs, mins))
    {hull, Vec.sub(hull.mins, mins)}
  end

  @doc "Whether hull `index` of `hulls` is there to use."
  @spec available?([Hull.t()], non_neg_integer()) :: boolean()
  def available?(hulls, 0), do: Enum.at(hulls, 0) != nil

  def available?(hulls, index) do
    case Enum.at(hulls, index) do
      %Hull{head: head, clipnodes: clipnodes} -> head <= tuple_size(clipnodes) - 1
      nil -> false
    end
  end

  @doc """
  A box of `mins`..`maxs` moved from `start` to `stop` through a brush model's `hulls`,
  both points in the model's space before it is turned by `axes` (rows forward, left,
  up). `force` is as `choose/4` takes it. The end and normal come back in that same
  unturned space.
  """
  @spec trace(
          [Hull.t()],
          integer(),
          axes(),
          Vec.t(),
          Vec.t(),
          Vec.t(),
          Vec.t(),
          non_neg_integer()
        ) ::
          Trace.t()
  def trace(hulls, force, axes, start, stop, mins, maxs, mask) do
    {hull, offset} = choose(hulls, force, mins, maxs)
    blank = %Trace{fraction: 1.0, all_solid: true}
    placed(hull, offset, axes, start, stop, mask, blank)
  end

  @doc """
  A point moved from `from` to `to` through `hull`, stopped by leaves whose contents
  bits meet `mask`, carrying on from `trace` (`Q1BSP_RecursiveHullCheck`).
  """
  @spec check(Hull.t(), Vec.t(), Vec.t(), non_neg_integer(), Trace.t()) :: Trace.t()
  def check(%Hull{} = hull, from, to, mask, trace) when from == to do
    bits = Contents.of_leaf(Hull.contents(hull, from))
    point(%{trace | contents: bits}, bits, mask)
  end

  def check(%Hull{} = hull, from, to, mask, trace) do
    line = %{hull: hull, start: from, stop: to, mask: mask}
    {_result, trace} = recurse(line, hull.head, 0.0, 1.0, from, to, trace)
    trace
  end

  defp pick(hulls, force, size) when force >= 1 and force <= @max_hulls do
    if available?(hulls, force - 1),
      do: Enum.at(hulls, force - 1),
      else: by_size(hulls, size)
  end

  defp pick(hulls, _force, size), do: by_size(hulls, size)

  defp by_size(hulls, {width, _, height}) do
    cond do
      width < 3 or not available?(hulls, 1) -> Enum.at(hulls, 0)
      width <= 32.1 or not available?(hulls, 2) -> standing(hulls, height)
      true -> Enum.at(hulls, 2)
    end
  end

  defp standing(hulls, height) do
    cond do
      height < 54.1 and available?(hulls, 3) -> Enum.at(hulls, 3)
      available?(hulls, 1) -> Enum.at(hulls, 1)
      true -> Enum.at(hulls, 0)
    end
  end

  defp placed(hull, offset, nil, start, stop, mask, blank) do
    trace = check(hull, Vec.sub(start, offset), Vec.sub(stop, offset), mask, blank)

    if trace.fraction == 1,
      do: %{trace | end_pos: stop},
      else: %{trace | end_pos: Vec.add(trace.end_pos, offset)}
  end

  defp placed(hull, offset, axes, start, stop, mask, blank) do
    from = start |> Vec.sub(offset) |> into(axes)
    to = stop |> Vec.sub(offset) |> into(axes)
    trace = check(hull, from, to, mask, blank)

    if trace.fraction == 1,
      do: %{trace | end_pos: stop},
      else: %{
        trace
        | normal: out_of(trace.normal, axes),
          end_pos: Vec.lerp(start, stop, trace.fraction)
      }
  end

  defp into(point, {a0, a1, a2}), do: {Vec.dot(point, a0), Vec.dot(point, a1), Vec.dot(point, a2)}

  defp out_of({nx, ny, nz}, {a0, _a1, _a2} = axes) do
    scale = 1.0 / Vec.dot(a0, a0)
    {{x0, y0, z0}, {x1, y1, z1}, {x2, y2, z2}} = axes

    {(nx * x0 + ny * x1 + nz * x2) * scale, (nx * y0 + ny * y1 + nz * y2) * scale,
     (nx * z0 + ny * z1 + nz * z2) * scale}
  end

  defp point(trace, bits, mask) when (bits &&& mask) != 0, do: %{trace | start_solid: true}

  defp point(trace, bits, _mask) do
    if Contents.fluid?(bits),
      do: %{trace | all_solid: false, in_water: true},
      else: %{trace | all_solid: false, in_open: true}
  end

  defp recurse(line, num, _p1f, _p2f, _p1, _p2, trace) when num < 0 do
    bits = Contents.of_leaf(num)
    leaf(trace, bits, line.mask)
  end

  defp recurse(line, num, p1f, p2f, p1, p2, trace) do
    {plane, front, back} = elem(line.hull.clipnodes, num)
    {normal, distance} = elem(line.hull.planes, plane)
    t1 = Vec.dot(normal, p1) - distance
    t2 = Vec.dot(normal, p2) - distance

    cond do
      t1 >= 0 and t2 >= 0 -> recurse(line, front, p1f, p2f, p1, p2, trace)
      t1 < 0 and t2 < 0 -> recurse(line, back, p1f, p2f, p1, p2, trace)
      true -> cross(line, {normal, distance, front, back}, {p1f, p2f, p1, p2}, trace)
    end
  end

  defp leaf(trace, bits, mask) when (bits &&& mask) != 0 do
    {:solid, %{trace | contents: bits, start_solid: trace.start_solid or trace.all_solid}}
  end

  defp leaf(trace, bits, _mask) do
    if Contents.fluid?(bits),
      do: {:empty, %{trace | all_solid: false, in_water: true}},
      else: {:empty, %{trace | all_solid: false, in_open: true}}
  end

  defp cross(line, {normal, distance, front, back}, {p1f, p2f, p1, p2}, trace) do
    t1 = Vec.dot(normal, line.start) - distance
    t2 = Vec.dot(normal, line.stop) - distance
    side = t1 < 0
    midf = split(t1, t2, p1f, p2f)
    mid = Vec.lerp(line.start, line.stop, midf)
    {near, far} = if side, do: {back, front}, else: {front, back}

    case recurse(line, near, p1f, midf, p1, mid, trace) do
      {result, trace} when result != :empty and not trace.all_solid ->
        {result, trace}

      {_result, trace} ->
        line
        |> recurse(far, midf, p2f, mid, p2, trace)
        |> beyond(line, {normal, distance}, side)
    end
  end

  defp beyond({:solid, trace}, line, plane, side), do: {:impact, impact(trace, line, plane, side)}
  defp beyond(result, _line, _plane, _side), do: result

  defp impact(trace, line, {normal, distance}, true),
    do: impact_on(trace, line, Vec.scale(normal, -1.0), -distance)

  defp impact(trace, line, {normal, distance}, false),
    do: impact_on(trace, line, normal, distance)

  defp impact_on(trace, line, normal, distance) do
    t1 = Vec.dot(normal, line.start) - distance
    t2 = Vec.dot(normal, line.stop) - distance
    fraction = backed_off(t1, t2)

    %{
      trace
      | normal: normal,
        distance: distance,
        fraction: fraction,
        end_pos: Vec.lerp(line.start, line.stop, fraction)
    }
  end

  defp split(t1, t2, low, high) when t1 == t2, do: if(t1 > 0, do: high, else: low)
  defp split(t1, t2, low, high), do: (t1 / (t1 - t2)) |> max(low) |> min(high)

  defp backed_off(t1, t2) when t1 == t2, do: if(t1 - @epsilon > 0, do: 1.0, else: 0.0)
  defp backed_off(t1, t2), do: ((t1 - @epsilon) / (t1 - t2)) |> min(1.0) |> max(0.0)
end
