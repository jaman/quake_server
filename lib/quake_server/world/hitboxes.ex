defmodule QuakeServer.World.Hitboxes do
  @moduledoc """
  A move against a studio model's hitboxes, posed as FTE's server poses it
  (`HLMDL_Trace`): a hitbox struck gives the trace its group as `surface_id`, its bone
  (from 1) as `bone_id`, its number (from 1) as `brush_id` and its face (from 1, 0 when
  the move started inside it) as `brush_face`.

      pose = %{sequence: 3, time: 0.4, base_sequence: 0, base_bones: 0}
      QuakeServer.World.Hitboxes.trace(studio, pose, axes, from, to, mins, maxs, mask)

  The pose is the entity's `frame` (the sequence, bit 0x8000 ignored), `frame1time`
  (seconds into it), `baseframe` and `basebone` (the first `basebone` bones take
  `baseframe` instead); bone controllers sit at 0 and a sequence's blends are mixed
  evenly. `from` and `to` are relative to the entity's origin; `axes` are its turned
  forward, left and up rows, or `nil` when it is not turned.

  The trace is `{:ok, trace}`, or `:unposed` for a sequence of no frames or one whose
  even mix needs a blend past the second, which `Cauldron3D.Formats.Studio.locals/4`
  does not read.
  """

  import Bitwise

  alias Cauldron3D.Formats.Studio
  alias Cauldron3D.{Skeleton, Vec}
  alias QuakeServer.Contents
  alias QuakeServer.World.Trace

  @type pose :: %{
          sequence: integer(),
          time: float(),
          base_sequence: integer(),
          base_bones: integer()
        }

  @doc "The move from `from` to `to` of a box `mins`..`maxs` against `studio`'s hitboxes in `pose`."
  @spec trace(
          Studio.t(),
          pose(),
          {Vec.t(), Vec.t(), Vec.t()} | nil,
          Vec.t(),
          Vec.t(),
          Vec.t(),
          Vec.t(),
          non_neg_integer()
        ) :: {:ok, Trace.t()} | :unposed
  def trace(%Studio{} = studio, pose, axes, from, to, mins, maxs, mask) do
    if (mask &&& Contents.bit(:body)) == 0,
      do: {:ok, %Trace{}},
      else: posed_trace(studio, pose, axes, {from, to, mins, maxs})
  end

  defp posed_trace(studio, pose, axes, move) do
    case relative_bones(studio, pose) do
      {:ok, relative} ->
        transforms = absolute(studio.parents, relative, axes)
        {:ok, strike(studio.hitboxes, transforms, move)}

      :unposed ->
        :unposed
    end
  end

  defp relative_bones(studio, pose) do
    count = tuple_size(studio.bones)
    base_end = min(max(pose.base_bones, 0), count)

    with {:ok, base} <- group(studio, pose.base_sequence, pose.time, 0, base_end),
         {:ok, rest} <- group(studio, pose.sequence, pose.time, base_end, count) do
      {:ok, base ++ rest}
    end
  end

  defp group(_studio, _sequence, _time, first, last) when first >= last, do: {:ok, []}

  defp group(studio, sequence, time, first, last) do
    with {:ok, bones} <- setup(studio, sequence, time) do
      {:ok,
       bones
       |> Enum.slice(first, last - first)
       |> Enum.map(fn {position, q} -> Skeleton.transform(position, q) end)}
    end
  end

  defp setup(studio, number, time) do
    index = sequence_index(studio, band(number, bnot(0x8000)))
    sequence = elem(studio.sequences, index)
    setup_frames(studio, index, sequence, max(time * sequence.fps, 0.0))
  end

  defp sequence_index(studio, index) when index >= 0 and index < tuple_size(studio.sequences),
    do: index

  defp sequence_index(_studio, _index), do: 0

  defp setup_frames(_studio, _index, %{frames: 0}, _frametime), do: :unposed

  defp setup_frames(studio, index, sequence, frametime) do
    first = trunc(frametime)
    fraction = frametime - first
    frame1 = wrap(first, sequence)
    frame2 = wrap(first + 1, sequence)

    {frame1, frame2, fraction} =
      if frame2 < frame1,
        do: {frame2, frame1, 1 - fraction},
        else: {frame1, frame2, fraction}

    frames = %{index: index, frame1: frame1, frame2: frame2, fraction: fraction}
    opts = controller_opts(studio)

    if sequence.blends > 1,
      do: blended(studio, sequence, frames, opts),
      else: {:ok, single(studio, frames, opts)}
  end

  defp wrap(frame, %{frames: frames, flags: flags}) when frame >= frames,
    do: if(flags != 0, do: rem(frame, frames), else: frames - 1)

  defp wrap(frame, _sequence), do: frame

  defp single(studio, %{frame1: frame, frame2: frame} = frames, opts),
    do: frame_locals(studio, frames.index, frame, 0, opts)

  defp single(studio, frames, opts) do
    first = frame_locals(studio, frames.index, frames.frame1, 0, opts)
    second = frame_locals(studio, frames.index, frames.frame2, 0, opts)

    Enum.zip_with(first, second, fn {p1, q1}, {p2, q2} ->
      {Vec.lerp(p1, p2, frames.fraction), slerp(q1, q2, frames.fraction)}
    end)
  end

  defp blended(studio, sequence, frames, opts) do
    weights = frame_weights(blend_weights(sequence.blends), frames)

    if Enum.all?(weights, fn {_frame, blend, _weight} -> blend <= 1 end),
      do: {:ok, mix(studio, frames.index, weights, opts)},
      else: :unposed
  end

  defp blend_weights(4), do: blend_weights(2, 2)
  defp blend_weights(9), do: blend_weights(3, 3)
  defp blend_weights(blends), do: blend_weights(blends, 1)

  defp blend_weights(across, down) do
    {f1, f2, frac} = split_blend(across)

    if down > 1 do
      {a1, a2, frac2} = split_blend(down)

      [
        {frac2 != 0 and frac != 0, f2 + a2 * across, frac * frac2},
        {frac2 != 0 and 1 - frac != 0, f1 + a2 * across, (1 - frac) * frac2},
        {1 - frac2 != 0 and frac != 0, f2 + a1 * across, frac * (1 - frac2)},
        {1 - frac2 != 0 and 1 - frac != 0, f1 + a1 * across, (1 - frac) * (1 - frac2)}
      ]
    else
      [{frac != 0, f1, frac}, {1 - frac != 0, f2, 1 - frac}]
    end
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(fn {_kept, blend, weight} -> {blend, weight} end)
  end

  defp split_blend(count) do
    frac = (count - 1) * 0.5
    f1 = trunc(bound(0, frac, count - 1))
    f2 = trunc(bound(0, f1 + 1, count - 1))
    {f1, f2, bound(0, frac - f1, 1)}
  end

  defp bound(low, value, high) when value >= low, do: if(value < high, do: value, else: high)
  defp bound(low, _value, _high), do: low

  defp frame_weights(weights, %{frame1: frame, frame2: frame}),
    do: Enum.map(weights, fn {blend, weight} -> {frame, blend, weight} end)

  defp frame_weights(weights, frames) do
    first =
      Enum.map(weights, fn {blend, w} -> {frames.frame1, blend, w * (1 - frames.fraction)} end)

    second = Enum.map(weights, fn {blend, w} -> {frames.frame2, blend, w * frames.fraction} end)
    first ++ second
  end

  defp mix(studio, index, weights, opts) do
    [{first_bones, first_weight} | rest] =
      Enum.map(weights, fn {frame, blend, weight} ->
        {frame_locals(studio, index, frame, blend, opts), weight}
      end)

    start =
      Enum.map(first_bones, fn {position, q} ->
        {Vec.scale(position, first_weight), scale4(q, first_weight)}
      end)

    rest
    |> Enum.reduce(start, fn {bones, weight}, acc ->
      Enum.zip_with(acc, bones, &added_bone(&1, &2, weight))
    end)
    |> Enum.map(fn {t, q} -> {t, unit4(q)} end)
  end

  defp added_bone({t, q1}, {position, q2}, weight) do
    sign = if dot4(q2, q1) < 0, do: -weight, else: weight
    {Vec.madd(t, position, weight), sum4(q1, scale4(q2, sign))}
  end

  defp frame_locals(studio, index, frame, blend, opts),
    do: Studio.locals(studio, index, frame / 1, [{:blend, blend * 255} | opts])

  defp controller_opts(studio) do
    settings =
      for index <- 0..3 do
        case Enum.find(studio.controllers, &(&1.index == index)) do
          nil -> 0
          controller -> setting_at_zero(controller)
        end
      end

    mouth =
      case Enum.find(studio.controllers, &(&1.index == 4)) do
        nil -> 0
        controller -> setting_at_zero(controller)
      end

    [controllers: settings, mouth: mouth]
  end

  defp setting_at_zero(%{start: start, stop: start}), do: 0

  defp setting_at_zero(%{type: type, start: start, stop: stop}) do
    value = if (type &&& 0x8000) != 0, do: 0.0, else: clamped_zero(start, stop)
    (value - start) * 255 / (stop - start)
  end

  defp clamped_zero(start, _stop) when 0.0 < start, do: start
  defp clamped_zero(_start, stop) when 0.0 > stop, do: stop
  defp clamped_zero(_start, _stop), do: 0.0

  defp absolute(parents, relative, axes) do
    relative
    |> Enum.with_index()
    |> Enum.reduce({}, fn {own, bone}, done ->
      world =
        case elem(parents, bone) do
          parent when parent >= 0 -> Skeleton.concat(elem(done, parent), own)
          _ -> root(axes, own)
        end

      Tuple.insert_at(done, tuple_size(done), world)
    end)
  end

  defp root(nil, own), do: own

  defp root({{f0, f1, f2}, {l0, l1, l2}, {u0, u1, u2}}, {r0, r1, r2}) do
    {i00, i01, i02, i03} = r0
    {i10, i11, i12, i13} = r1
    {i20, i21, i22, i23} = r2

    {{f0 * i00 + l0 * i10 + u0 * i20, f0 * i01 + l0 * i11 + u0 * i21,
      f0 * i02 + l1 * i12 + u0 * i22, f0 * i03 + l1 * i13 + u0 * i23},
     {f1 * i00 + l1 * i10 + u1 * i20, f1 * i01 + l1 * i11 + u1 * i21,
      f1 * i02 + l1 * i12 + u1 * i22, f1 * i03 + l1 * i13 + u1 * i23},
     {f2 * i00 + l2 * i10 + u2 * i20, f2 * i01 + l2 * i11 + u2 * i21,
      f2 * i02 + l2 * i12 + u2 * i22, f2 * i03 + l2 * i13 + u2 * i23}}
  end

  defp strike(hitboxes, transforms, {from, to, _mins, _maxs} = move) do
    trace =
      hitboxes
      |> Enum.with_index(1)
      |> Enum.reduce_while(%Trace{}, fn {hitbox, number}, trace ->
        hitbox_move(hitbox, number, elem(transforms, hitbox.bone), move, trace)
      end)

    %{trace | normal: face_normal(trace, transforms), end_pos: Vec.lerp(from, to, trace.fraction)}
  end

  defp hitbox_move(hitbox, number, transform, {from, to, mins, maxs}, trace) do
    inverse = invert(transform)
    local_from = Skeleton.apply(inverse, from)
    local_to = Skeleton.apply(inverse, to)
    clip = %{start_out: false, end_out: false, plane: 0, enter: -1.0, exit: 10.0, distance: 0.0}

    case faces(hitbox, mins, maxs, local_from, local_to, clip) do
      :outside -> {:cont, trace}
      %{start_out: false} = clip -> {:halt, inside(trace, hitbox, number, clip)}
      clip -> {:cont, entered(trace, hitbox, number, clip)}
    end
  end

  defp faces(hitbox, mins, maxs, from, to, clip) do
    Enum.reduce_while(0..5, clip, fn face, clip ->
      {distance, d1, d2} = face_distances(face, hitbox, mins, maxs, from, to)
      clip = %{clip | start_out: clip.start_out or d1 >= 0, end_out: clip.end_out or d2 > 0}

      cond do
        d1 > 0 and d2 >= 0 -> {:halt, :outside}
        d1 < 0 and d2 <= 0 -> {:cont, clip}
        d1 == d2 -> {:cont, clip}
        true -> {:cont, crossing(clip, face, distance, d1, d2)}
      end
    end)
  end

  defp face_distances(face, hitbox, mins, _maxs, from, to) when face < 3 do
    distance = elem(hitbox.maxs, face) - elem(mins, face)
    {distance, elem(from, face) - distance, elem(to, face) - distance}
  end

  defp face_distances(face, hitbox, _mins, maxs, from, to) do
    axis = face - 3
    distance = elem(maxs, axis) - elem(hitbox.mins, axis)
    {distance, -elem(from, axis) - distance, -elem(to, axis) - distance}
  end

  defp crossing(clip, face, distance, d1, d2) do
    f = d1 / (d1 - d2)

    cond do
      d1 > d2 and clip.enter < f -> %{clip | enter: f, plane: face, distance: distance}
      d1 > d2 -> clip
      clip.exit > f -> %{clip | exit: f}
      true -> clip
    end
  end

  defp inside(trace, hitbox, number, clip) do
    %{
      trace
      | start_solid: true,
        all_solid: trace.all_solid or not clip.end_out,
        contents: Contents.bit(:body),
        brush_face: 0,
        bone_id: hitbox.bone + 1,
        brush_id: number,
        surface_id: hitbox.group
    }
  end

  defp entered(trace, hitbox, number, clip) do
    if clip.enter != -1 and clip.enter < clip.exit and clip.enter < trace.fraction,
      do: %{
        trace
        | fraction: clip.enter,
          distance: clip.distance,
          contents: Contents.bit(:body),
          brush_face: clip.plane + 1,
          bone_id: hitbox.bone + 1,
          brush_id: number,
          surface_id: hitbox.group
      },
      else: trace
  end

  defp face_normal(%Trace{brush_face: 0}, _transforms), do: {0.0, 0.0, 0.0}

  defp face_normal(%Trace{brush_face: face, bone_id: bone}, transforms) do
    axis = if face < 4, do: face - 1, else: face - 4
    sign = if face < 4, do: 1.0, else: -1.0
    unit = put_elem({0.0, 0.0, 0.0}, axis, sign)
    Skeleton.rotate(elem(transforms, bone - 1), unit)
  end

  defp invert({{a, b, c, tx}, {d, e, f, ty}, {g, h, i, tz}}) do
    scale = 1.0 / (a * a + b * b + c * c)
    {o0, o1, o2} = {a * scale, d * scale, g * scale}
    {o4, o5, o6} = {b * scale, e * scale, h * scale}
    {o8, o9, o10} = {c * scale, f * scale, i * scale}

    {{o0, o1, o2, -(tx * o0 + ty * o1 + tz * o2)}, {o4, o5, o6, -(tx * o4 + ty * o5 + tz * o6)},
     {o8, o9, o10, -(tx * o8 + ty * o9 + tz * o10)}}
  end

  defp slerp(p, q, t) do
    a = sum4(p, scale4(q, -1.0))
    b = sum4(p, q)
    q = if dot4(a, a) > dot4(b, b), do: scale4(q, -1.0), else: q
    cosom = dot4(p, q)
    slerp_from(p, q, t, cosom)
  end

  defp slerp_from(p, q, t, cosom) when 1.0 + cosom > 0.00000001 do
    {sclp, sclq} =
      if 1.0 - cosom > 0.00000001 do
        omega = :math.acos(cosom)
        sinom = :math.sin(omega)
        {:math.sin((1.0 - t) * omega) / sinom, :math.sin(t * omega) / sinom}
      else
        {1.0 - t, t}
      end

    sum4(scale4(p, sclp), scale4(q, sclq))
  end

  defp slerp_from({px, py, pz, pw} = p, _q, t, _cosom) do
    turned = {-py, px, -pw, pz}
    sclp = :math.sin((1.0 - t) * 0.5 * :math.pi())
    sclq = :math.sin(t * 0.5 * :math.pi())
    sum4(scale4(p, sclp), scale4(turned, sclq))
  end

  defp unit4(q) do
    length = :math.sqrt(dot4(q, q))
    if length != 0 and length != 1, do: scale4(q, 1 / length), else: q
  end

  defp sum4({ax, ay, az, aw}, {bx, by, bz, bw}), do: {ax + bx, ay + by, az + bz, aw + bw}
  defp scale4({x, y, z, w}, s), do: {x * s, y * s, z * s, w * s}
  defp dot4({ax, ay, az, aw}, {bx, by, bz, bw}), do: ax * bx + ay * by + az * bz + aw * bw
end
