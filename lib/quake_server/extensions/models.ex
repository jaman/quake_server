defmodule QuakeServer.Extensions.Models do
  @moduledoc """
  FTE's model builtins: model numbers by name and names by number; a studio model's
  sequences ("frames") by name and action, their length and their events; skeleton
  objects; tags (a studio model's bones, then its attachments, numbered from 1) and where
  a tag lies on an entity in the world; and the surfaces of a brush model, with their
  corners' position, texture axes, normal, texture and lightmap places and light.

  An entity's pose is its `frame` (the sequence), `frame1time` (seconds into it),
  `bonecontrol1` to `bonecontrol5` and `subblendfrac` with `subblend2frac`. `processmodelevents` runs its
  callback for each event from the base time up to but not including the target time, a
  looping sequence's events coming round every `(frames - 1) / fps` seconds; nothing runs
  when the two times are equal. Skeleton objects live in the host's
  `ext.skeletons`.
  """

  import Bitwise

  alias Cauldron3D.{Bsp, Skeleton, Vec}
  alias Cauldron3D.Bsp.{Face, Light}
  alias Cauldron3D.Formats.Studio
  alias QuakeC.Exec
  alias QuakeServer.{Angles, Args, Edicts, Models}
  alias QuakeServer.Extensions.Lights

  @doc "Run model builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 200, argc) do
    name = Args.str(s, 0)

    if Args.num(s, 1, argc, 0.0) != 0 do
      Args.return(s, (Models.index(s, name) || 0) / 1)
    else
      {s, index} = Models.precache(s, name)
      Args.return(s, index / 1)
    end
  end

  def call(s, 334, _argc), do: Args.return(s, Models.name(s, Args.int(s, 0)))

  def call(s, 276, _argc),
    do:
      Args.return(
        s,
        with_studio(s, Args.int(s, 0), -1.0, &((Studio.sequence(&1, Args.str(s, 1)) || -1) / 1))
      )

  def call(s, 277, _argc) do
    Args.return(
      s,
      with_sequence(s, Args.int(s, 0), Args.int(s, 1), 0.0, fn seq ->
        if seq.fps > 0, do: seq.frames / seq.fps, else: 0.0
      end)
    )
  end

  def call(s, 284, _argc),
    do: Args.return(s, with_sequence(s, Args.int(s, 0), Args.int(s, 1), "", & &1.name))

  def call(s, "modelframecount", _argc),
    do: Args.return(s, with_studio(s, Args.int(s, 0), 0.0, &(tuple_size(&1.sequences) / 1)))

  def call(s, "frameforaction", _argc) do
    action = Args.int(s, 1)
    Args.return(s, with_studio(s, Args.int(s, 0), -1.0, &(for_action(&1, action) / 1)))
  end

  def call(s, "processmodelevents", _argc) do
    from = Args.num(s, 2)
    to = Args.num(s, 3)

    if to == from do
      s
    else
      callback = Args.slot(s, 4)
      events = with_sequence(s, Args.int(s, 0), Args.int(s, 1), [], &due(&1, from, to))
      s = Enum.reduce(events, s, &fire(&2, callback, &1))
      %{s | qc: QuakeC.put_slot(s.qc, 4 + 2 * 3, to)}
    end
  end

  def call(s, 263, _argc) do
    model = Args.int(s, 0)
    handle = Map.get(s.ext, :next_skeleton, 1)

    case with_studio(s, model, nil, & &1) do
      nil ->
        Args.return(s, 0.0)

      studio ->
        relative =
          studio.parents
          |> Skeleton.pose(Studio.locals(studio, 0, 0.0))
          |> relative(studio.parents)

        skeleton = %{
          model: model,
          parents: studio.parents,
          names: Enum.map(Tuple.to_list(studio.bones), & &1.name),
          bones: relative
        }

        skeletons = Map.put(Map.get(s.ext, :skeletons, %{}), handle, skeleton)

        %{s | ext: s.ext |> Map.put(:skeletons, skeletons) |> Map.put(:next_skeleton, handle + 1)}
        |> Args.return(handle / 1)
    end
  end

  def call(s, 264, argc) do
    handle = Args.int(s, 0)
    entity = Args.int(s, 1)
    model = Args.int(s, 2)
    retain = Args.num(s, 3)
    first = max(trunc(Args.num(s, 4)), 1)
    add = Args.num(s, 6, argc, 1.0 - retain)

    with %{} = skeleton <- skeleton(s, handle),
         %Studio{} = studio <- with_studio(s, model, nil, & &1) do
      {sequence, frame, opts} = pose_of(s, entity)

      sequence =
        if sequence >= 0 and sequence < tuple_size(studio.sequences), do: sequence, else: 0

      posed =
        studio.parents
        |> Skeleton.pose(Studio.locals(studio, sequence, frame, opts))
        |> relative(studio.parents)

      last =
        min(
          if(Args.num(s, 5) <= 0, do: tuple_size(posed), else: trunc(Args.num(s, 5))),
          tuple_size(skeleton.bones)
        )

      bones =
        Enum.reduce(first..last//1, skeleton.bones, fn bone, acc ->
          put_elem(acc, bone - 1, mix(elem(acc, bone - 1), elem(posed, bone - 1), retain, add))
        end)

      s |> put_skeleton(handle, %{skeleton | bones: bones}) |> Args.return(handle / 1)
    else
      _ -> Args.return(s, 0.0)
    end
  end

  def call(s, 265, _argc),
    do:
      Args.return(
        s,
        (s |> skeleton(Args.int(s, 0)) |> then(&(&1 && tuple_size(&1.bones))) || 0) / 1
      )

  def call(s, 266, _argc),
    do:
      Args.return(
        s,
        s |> skeleton(Args.int(s, 0)) |> then(&(&1 && Enum.at(&1.names, Args.int(s, 1) - 1))) ||
          ""
      )

  def call(s, 267, _argc) do
    parent = s |> skeleton(Args.int(s, 0)) |> then(&(&1 && elem(&1.parents, Args.int(s, 1) - 1)))
    Args.return(s, ((parent || -1) + 1) / 1)
  end

  def call(s, 268, _argc) do
    index =
      s
      |> skeleton(Args.int(s, 0))
      |> then(&(&1 && Enum.find_index(&1.names, fn name -> name == Args.str(s, 1) end)))

    Args.return(s, ((index || -1) + 1) / 1)
  end

  def call(s, 269, _argc), do: bone_out(s, Args.int(s, 0), Args.int(s, 1), :relative)
  def call(s, 270, _argc), do: bone_out(s, Args.int(s, 0), Args.int(s, 1), :absolute)

  def call(s, 271, argc) do
    handle = Args.int(s, 0)
    bone = Args.int(s, 1)
    with_bone(s, handle, bone, fn _old -> matrix(s, 2, argc) end)
  end

  def call(s, 272, argc) do
    with_bone(s, Args.int(s, 0), Args.int(s, 1), fn old ->
      Skeleton.concat(matrix(s, 2, argc), old)
    end)
  end

  def call(s, 273, argc) do
    handle = Args.int(s, 0)
    transform = matrix(s, 3, argc)

    Enum.reduce(Args.int(s, 1)..Args.int(s, 2)//1, s, fn bone, acc ->
      with_bone(acc, handle, bone, &Skeleton.concat(transform, &1))
    end)
  end

  def call(s, 274, _argc) do
    {to, from} = {Args.int(s, 0), Args.int(s, 1)}

    case {skeleton(s, to), skeleton(s, from)} do
      {%{} = target, %{} = source} ->
        last = min(Args.int(s, 3), min(tuple_size(target.bones), tuple_size(source.bones)))

        bones =
          Enum.reduce(
            max(Args.int(s, 2), 1)..last//1,
            target.bones,
            &put_elem(&2, &1 - 1, elem(source.bones, &1 - 1))
          )

        put_skeleton(s, to, %{target | bones: bones})

      _ ->
        s
    end
  end

  def call(s, 275, _argc),
    do: %{s | ext: Map.update(s.ext, :skeletons, %{}, &Map.delete(&1, Args.int(s, 0)))}

  def call(s, 283, argc) do
    entity = Args.int(s, 0)
    handle = Edicts.int(s, entity, "skeletonindex")
    bone = Args.int(s, 1)
    world = matrix(s, 2, argc)

    case skeleton(s, handle) do
      %{} = skeleton when bone >= 1 and bone <= tuple_size(skeleton.bones) ->
        absolute = absolute(skeleton, root(s, entity))
        parent = elem(skeleton.parents, bone - 1)
        base = if parent >= 0, do: elem(absolute, parent), else: root(s, entity)
        with_bone(s, handle, bone, fn _ -> Skeleton.concat(invert(base), world) end)

      _ ->
        s
    end
  end

  def call(s, 451, _argc) do
    entity = Args.int(s, 0)
    name = Args.str(s, 1)

    Args.return(
      s,
      with_studio(s, Edicts.int(s, entity, "modelindex"), 0.0, &(tag_index(&1, name) / 1))
    )
  end

  def call(s, 452, _argc) do
    entity = Args.int(s, 0)

    case skeleton_transforms(s, Edicts.int(s, entity, "skeletonindex")) do
      nil -> tag_info(s)
      transforms -> skeleton_tag(s, entity, transforms, Args.int(s, 1))
    end
  end

  def call(s, 486, _argc) do
    entity = Args.int(s, 0)
    face = Args.int(s, 1)
    point = Args.int(s, 2)
    attribute = Args.int(s, 3)

    Args.return(
      s,
      with_brush(s, entity, {0.0, 0.0, 0.0}, &point_attribute(s, &1, face, point, attribute))
    )
  end

  def call(s, 438, _argc) do
    entity = Args.int(s, 0)
    point = Vec.sub(Args.vec(s, 1), Edicts.vector(s, entity, "origin"))
    Args.return(s, with_brush(s, entity, -1, &near_face(&1, point)) / 1)
  end

  def call(s, 437, _argc) do
    entity = Args.int(s, 0)
    face = Args.int(s, 1)
    Args.return(s, with_brush(s, entity, "", &face_texture(&1, face)))
  end

  def call(s, 436, _argc) do
    face = Args.int(s, 1)

    normal = with_brush(s, Args.int(s, 0), {0.0, 0.0, 0.0}, &face_normal(&1, face))

    Args.return(s, normal)
  end

  defp skeleton_tag(s, entity, transforms, tag) when tag >= 1 and tag <= tuple_size(transforms) do
    transform = Skeleton.concat(root(s, entity), elem(transforms, tag - 1))
    s |> put_axes(transform) |> Args.return(Skeleton.origin(transform))
  end

  defp skeleton_tag(s, _entity, _transforms, _tag), do: tag_info(s)

  defp tag_info(s) do
    entity = Args.int(s, 0)
    tag = Args.int(s, 1)
    model = Edicts.int(s, entity, "modelindex")
    origin = Edicts.vector(s, entity, "origin")

    case with_studio(s, model, nil, &tag_transform(&1, tag, pose_of(s, entity), root(s, entity))) do
      nil ->
        Args.return(s, origin)

      transform ->
        qc =
          s.qc
          |> QuakeC.put_global("v_forward", Skeleton.rotate(transform, {1.0, 0.0, 0.0}))
          |> QuakeC.put_global(
            "v_right",
            Vec.scale(Skeleton.rotate(transform, {0.0, 1.0, 0.0}), -1.0)
          )
          |> QuakeC.put_global("v_up", Skeleton.rotate(transform, {0.0, 0.0, 1.0}))

        Args.return(%{s | qc: qc}, Skeleton.origin(transform))
    end
  end

  @doc "Skeleton object `handle`'s bones as transforms from bone space to the model's, or `nil`."
  @spec skeleton_transforms(map(), integer()) :: tuple() | nil
  def skeleton_transforms(s, handle) do
    case skeleton(s, handle) do
      nil -> nil
      skeleton -> absolute(skeleton, Skeleton.identity())
    end
  end

  defp skeleton(s, handle), do: s.ext |> Map.get(:skeletons, %{}) |> Map.get(handle)

  defp put_skeleton(s, handle, skeleton),
    do: %{
      s
      | ext: Map.update(s.ext, :skeletons, %{handle => skeleton}, &Map.put(&1, handle, skeleton))
    }

  defp with_bone(s, handle, bone, change) do
    case skeleton(s, handle) do
      %{bones: bones} = skeleton when bone >= 1 and bone <= tuple_size(bones) ->
        put_skeleton(s, handle, %{
          skeleton
          | bones: put_elem(bones, bone - 1, change.(elem(bones, bone - 1)))
        })

      _ ->
        s
    end
  end

  defp bone_out(s, handle, bone, kind) do
    case skeleton(s, handle) do
      %{bones: bones} = skeleton when bone >= 1 and bone <= tuple_size(bones) ->
        transform =
          if kind == :relative,
            do: elem(bones, bone - 1),
            else: elem(absolute(skeleton, Skeleton.identity()), bone - 1)

        s |> put_axes(transform) |> Args.return(Skeleton.origin(transform))

      _ ->
        Args.return(s, {0.0, 0.0, 0.0})
    end
  end

  defp put_axes(s, transform) do
    qc =
      s.qc
      |> QuakeC.put_global("v_forward", Skeleton.rotate(transform, {1.0, 0.0, 0.0}))
      |> QuakeC.put_global(
        "v_right",
        Vec.scale(Skeleton.rotate(transform, {0.0, 1.0, 0.0}), -1.0)
      )
      |> QuakeC.put_global("v_up", Skeleton.rotate(transform, {0.0, 0.0, 1.0}))

    %{s | qc: qc}
  end

  defp matrix(s, at, argc) do
    {ox, oy, oz} = Args.vec(s, at)

    {forward, right, up} =
      if argc > at + 3,
        do: {Args.vec(s, at + 1), Args.vec(s, at + 2), Args.vec(s, at + 3)},
        else:
          {QuakeC.global_vector(s.qc, "v_forward"), QuakeC.global_vector(s.qc, "v_right"),
           QuakeC.global_vector(s.qc, "v_up")}

    {fx, fy, fz} = forward
    {lx, ly, lz} = Vec.scale(right, -1.0)
    {ux, uy, uz} = up
    {{fx, lx, ux, ox}, {fy, ly, uy, oy}, {fz, lz, uz, oz}}
  end

  defp relative(absolute, parents) do
    absolute
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.map(fn {transform, bone} ->
      case elem(parents, bone) do
        parent when parent >= 0 -> Skeleton.concat(invert(elem(absolute, parent)), transform)
        _ -> transform
      end
    end)
    |> List.to_tuple()
  end

  defp absolute(%{bones: bones, parents: parents}, root), do: chain(bones, parents, root)

  defp chain(bones, parents, root) do
    bones
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce({}, fn {transform, bone}, done ->
      parent = elem(parents, bone)
      base = if parent >= 0 and parent < tuple_size(done), do: elem(done, parent), else: root
      Tuple.insert_at(done, tuple_size(done), Skeleton.concat(base, transform))
    end)
  end

  defp invert({{a, b, c, tx}, {d, e, f, ty}, {g, h, i, tz}}) do
    {{a, d, g, -(a * tx + d * ty + g * tz)}, {b, e, h, -(b * tx + e * ty + h * tz)},
     {c, f, i, -(c * tx + f * ty + i * tz)}}
  end

  defp mix(old, new, retain, add) do
    {o0, o1, o2} = old
    {n0, n1, n2} = new
    {row(o0, n0, retain, add), row(o1, n1, retain, add), row(o2, n2, retain, add)}
  end

  defp row({a, b, c, d}, {e, f, g, h}, retain, add),
    do: {a * retain + e * add, b * retain + f * add, c * retain + g * add, d * retain + h * add}

  defp with_studio(s, model, default, use) do
    case Models.get(s, model) do
      %{kind: :studio, data: %Studio{} = studio} -> use.(studio)
      _ -> default
    end
  end

  defp with_sequence(s, model, index, default, use) do
    with_studio(s, model, default, fn studio ->
      if index >= 0 and index < tuple_size(studio.sequences),
        do: use.(elem(studio.sequences, index)),
        else: default
    end)
  end

  defp with_brush(s, entity, default, use) do
    case Models.get(s, Edicts.int(s, entity, "modelindex")) do
      %{kind: :brush} when entity == 0 -> use.(s.bsp)
      %{kind: :brush, data: %{bsp: bsp}} -> use.(bsp)
      _ when entity == 0 -> use.(s.bsp)
      _ -> default
    end
  end

  defp face_normal(bsp, face) do
    if face >= 0 and face < tuple_size(bsp.faces),
      do: oriented_normal(bsp, elem(bsp.faces, face)),
      else: {0.0, 0.0, 0.0}
  end

  defp oriented_normal(bsp, %{plane: plane, back?: back?}) do
    {normal, _} = Bsp.plane(bsp, plane)
    if back?, do: Vec.scale(normal, -1.0), else: normal
  end

  defp for_action(studio, action) do
    choices =
      studio.sequences
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.filter(fn {seq, _} -> seq.activity == action end)

    total = choices |> Enum.map(fn {seq, _} -> max(seq.weight, 1) end) |> Enum.sum()

    if total == 0 do
      -1
    else
      pick = :rand.uniform(total)

      choices
      |> Enum.reduce_while(pick, &take_weighted/2)
      |> then(fn {:index, index} -> index end)
    end
  end

  defp take_weighted({seq, index}, left) do
    left = left - max(seq.weight, 1)
    if left <= 0, do: {:halt, {:index, index}}, else: {:cont, left}
  end

  defp due(%{events: []}, _from, _to), do: []

  defp due(sequence, from, to) do
    fps = if sequence.fps > 0, do: sequence.fps, else: 10.0
    cycle = (sequence.frames - 1) / fps
    looping? = Bitwise.band(sequence.flags, 1) != 0 and cycle > 0
    start = if looping?, do: cycle * trunc(max(from, 0.0) / cycle), else: 0.0
    timed = Enum.map(sequence.events, &{&1.frame / fps, &1})
    rounds(timed, start, if(looping?, do: cycle, else: nil), from, to, [])
  end

  defp rounds(timed, start, cycle, from, to, acc) do
    {acc, ended?} =
      Enum.reduce_while(timed, {acc, false}, fn {offset, event}, {acc, _} ->
        at = start + offset

        cond do
          at >= to -> {:halt, {acc, true}}
          at >= from -> {:cont, {[{at, event} | acc], false}}
          true -> {:cont, {acc, false}}
        end
      end)

    if ended? or cycle == nil,
      do: Enum.reverse(acc),
      else: rounds(timed, start + cycle, cycle, from, to, acc)
  end

  defp fire(s, callback, {at, event}) do
    qc =
      s.qc
      |> QuakeC.put_slot(4, at)
      |> QuakeC.put_slot(7, event.event)
      |> QuakeC.put_slot(10, event.options)

    QuakeServer.Server.keeping_self(%{s | qc: qc}, fn s ->
      Exec.call(s, trunc(QuakeC.float(callback)), s.builtins, QuakeServer.Server.exec_opts(s))
    end)
  end

  defp tag_index(studio, name) do
    bones = studio.bones |> Tuple.to_list() |> Enum.find_index(&(&1.name == name))
    attachment = Enum.find_index(studio.attachments, &(&1.name == name))

    cond do
      bones -> bones + 1
      attachment -> tuple_size(studio.bones) + attachment + 1
      true -> 0
    end
  end

  defp tag_transform(studio, tag, pose, root) do
    bones = tuple_size(studio.bones)

    cond do
      tag >= 1 and tag <= bones ->
        studio |> transforms(pose, root) |> elem(tag - 1)

      tag > bones and tag - bones <= length(studio.attachments) ->
        attachment = Enum.at(studio.attachments, tag - bones - 1)
        bone = studio |> transforms(pose, root) |> elem(max(attachment.bone, 0))
        {{a, b, c, _}, {d, e, f, _}, {g, h, i, _}} = bone
        {x, y, z} = Skeleton.apply(bone, attachment.origin)
        {{a, b, c, x}, {d, e, f, y}, {g, h, i, z}}

      true ->
        nil
    end
  end

  defp transforms(studio, {sequence, frame, opts}, root) do
    sequence = if sequence >= 0 and sequence < tuple_size(studio.sequences), do: sequence, else: 0
    Skeleton.pose(studio.parents, Studio.locals(studio, sequence, frame, opts), root)
  end

  defp pose_of(s, entity) do
    sequence = Edicts.int(s, entity, "frame")
    bonecontrols = for i <- 1..5, do: Edicts.float(s, entity, "bonecontrol#{i}")

    subblend =
      {Edicts.float(s, entity, "subblendfrac"), Edicts.float(s, entity, "subblend2frac")}

    frame = frame_at(s, entity, sequence, Edicts.float(s, entity, "frame1time"))
    {sequence, frame, [bonecontrols: bonecontrols, subblend: subblend]}
  end

  defp frame_at(s, entity, sequence, seconds) do
    with_sequence(s, Edicts.int(s, entity, "modelindex"), sequence, 0.0, fn seq ->
      frames = max(seq.frames, 1)
      frame = seconds * seq.fps

      if band(seq.flags, 1) != 0 and frames > 1,
        do: frame - (frames - 1) * Float.floor(frame / (frames - 1)),
        else: frame |> max(0.0) |> min(frames - 1.0)
    end)
  end

  defp root(s, entity) do
    {ox, oy, oz} = Edicts.vector(s, entity, "origin")
    {forward, right, up} = Angles.vectors(Edicts.vector(s, entity, "angles"))
    {lx, ly, lz} = Vec.scale(right, -1.0)
    {fx, fy, fz} = forward
    {ux, uy, uz} = up
    {{fx, lx, ux, ox}, {fy, ly, uy, oy}, {fz, lz, uz, oz}}
  end

  defp near_face(bsp, point) do
    leaf = elem(bsp.leaves, Bsp.leaf_at(bsp, point))

    leaf.faces
    |> Enum.map(fn index -> {index, distance(bsp, elem(bsp.faces, index), point)} end)
    |> Enum.filter(fn {_index, distance} -> distance != nil end)
    |> Enum.min_by(&elem(&1, 1), fn -> {-1, nil} end)
    |> elem(0)
  end

  defp distance(bsp, %Face{} = face, point) do
    {normal, d} = Bsp.plane(bsp, face.plane)
    away = abs(Vec.dot(point, normal) - d)
    {mins, maxs} = bounds(face.points)

    if inside?(point, Vec.sub(mins, {1.0, 1.0, 1.0}), Vec.add(maxs, {1.0, 1.0, 1.0})),
      do: away,
      else: nil
  end

  defp bounds(points) do
    {xs, ys, zs} =
      {Enum.map(points, &elem(&1, 0)), Enum.map(points, &elem(&1, 1)),
       Enum.map(points, &elem(&1, 2))}

    {{Enum.min(xs), Enum.min(ys), Enum.min(zs)}, {Enum.max(xs), Enum.max(ys), Enum.max(zs)}}
  end

  defp inside?({x, y, z}, {x0, y0, z0}, {x1, y1, z1}),
    do: x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z0 and z <= z1

  defp point_attribute(s, bsp, face, point, attribute)
       when face >= 0 and face < tuple_size(bsp.faces) do
    face = elem(bsp.faces, face)

    case Enum.at(face.points, point) do
      nil -> {0.0, 0.0, 0.0}
      corner -> attribute(s, bsp, face, corner, attribute)
    end
  end

  defp point_attribute(_s, _bsp, _face, _point, _attribute), do: {0.0, 0.0, 0.0}

  defp attribute(_s, _bsp, _face, corner, 0), do: corner
  defp attribute(_s, _bsp, %Face{s: {axis, _}}, _corner, 1), do: axis
  defp attribute(_s, _bsp, %Face{t: {axis, _}}, _corner, 2), do: axis
  defp attribute(_s, bsp, face, _corner, 3), do: oriented_normal(bsp, face)

  defp attribute(_s, bsp, face, corner, 4) do
    {u, v} = Face.st(face, corner)
    {width, height} = texture_size(bsp, face)
    {u / width, v / height, 0.0}
  end

  defp attribute(_s, _bsp, face, corner, 5) do
    {u, v} = Face.st(face, corner)
    {u_min, v_min} = face.mins
    {(u - u_min) / face.luxel, (v - v_min) / face.luxel, 0.0}
  end

  defp attribute(s, bsp, face, corner, 6) do
    {r, g, b} = Light.on_face(bsp, face, corner, Lights.scales(s))
    {r / 255, g / 255, b / 255}
  end

  defp attribute(_s, _bsp, _face, _corner, _attribute), do: {0.0, 0.0, 0.0}

  defp texture_size(bsp, face) do
    case elem(bsp.textures, face.texture) do
      %{mips: [%{width: width, height: height} | _]} -> {width, height}
      _ -> {1, 1}
    end
  end

  defp face_texture(bsp, face)
       when face >= 0 and
              face < tuple_size(bsp.faces),
       do: elem(bsp.textures, elem(bsp.faces, face).texture).name

  defp face_texture(_bsp, _face), do: ""
end
