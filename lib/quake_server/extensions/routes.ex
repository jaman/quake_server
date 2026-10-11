defmodule QuakeServer.Extensions.Routes do
  @moduledoc """
  FTE's `route_calculate` (`sv_move.c`): a path over the level's waypoints from where an
  entity stands to a destination, handed to the program's callback at the start of the
  next frame (`run/1`) as a list of nodes in allocated memory.

  The waypoints are read once a level, the first time a route is asked for, from the
  first of `data/<map>.way`, `bots/navigation/<map>.nav` and `maps/<map>.bsp.way` that
  exists, in FTE's text form: a count, then for each waypoint `x y z radius links`
  followed by `links` lines of `target cost flags`. With none, the level has no
  waypoints.

  The start and end waypoints are those nearest the entity and the destination, a
  waypoint whose radius holds the point first, and otherwise only one the point can see
  through the world model. The path is FTE's A* search over the links, leaving out links
  with any of the deny flags.

  The callback is `callback(entity, destination, count, nodes)`, `count` an integer;
  `nodes` points at `count` records of five words: the place `x y z`, the flags of the
  link that reaches it (an integer) and its radius. Record 0 is the destination (flags
  `LF_DESTINATION`, radius 32), then the waypoints from the end back to the start, then
  the entity's place (flags 0, radius 32): the last record is the first place to go.
  Without a path the records are the destination and the entity's place, radius 0.
  """

  import Bitwise

  alias Cauldron3D.Vec
  alias QuakeC.Exec
  alias QuakeServer.{Args, Edicts, Server, World}
  alias QuakeServer.Extensions.{Store, Strings}

  @destination -0x80000000

  @doc "Run `route_calculate`."
  @spec call(map(), String.t(), non_neg_integer()) :: map()
  def call(s, "route_calculate", _argc) do
    entity = Args.int(s, 0)
    destination = Args.vec(s, 1)
    deny = Args.int(s, 2)
    callback = Args.int(s, 3)
    {s, graph} = graph(s)
    start = Edicts.vector(s, entity, "origin")
    from = nearest(s, graph, start)
    to = nearest(s, graph, destination)
    records = records(graph, start, destination, from, to, deny)
    route = %{entity: entity, destination: destination, callback: callback, records: records}
    %{s | ext: Map.update(s.ext, :routes, [route], &(&1 ++ [route]))}
  end

  @doc "Hand every route asked for since the last call to its callback, oldest first."
  @spec run(Server.t()) :: Server.t()
  def run(%Server{} = server) do
    {routes, ext} = Map.pop(server.ext, :routes, [])
    Enum.reduce(routes, %{server | ext: ext}, &hand_over/2)
  end

  defp hand_over(%{callback: callback}, server) when callback <= 0, do: server

  defp hand_over(route, server) do
    {qc, pointer} = write(server.qc, route.records)

    qc =
      qc
      |> QuakeC.put_slot(4, route.entity)
      |> QuakeC.put_slot_vector(7, route.destination)
      |> QuakeC.put_slot(10, length(route.records))
      |> QuakeC.put_slot(13, pointer)

    Exec.call(%{server | qc: qc}, route.callback, server.builtins, Server.exec_opts(server))
  end

  defp graph(s) do
    case Map.fetch(s.ext, :waypoints) do
      {:ok, graph} ->
        {s, graph}

      :error ->
        text = Enum.find_value(sources(s.map), &Store.read(s, &1)) || ""
        graph = parse(text)
        {%{s | ext: Map.put(s.ext, :waypoints, graph)}, graph}
    end
  end

  defp sources(map), do: ["data/#{map}.way", "bots/navigation/#{map}.nav", "maps/#{map}.bsp.way"]

  defp parse(text) do
    case String.split(text, "\n") do
      [count | rest] -> nodes(rest, max(trunc(Strings.number(count)), 0), [])
      [] -> {}
    end
  end

  defp nodes(_lines, 0, acc), do: acc |> Enum.reverse() |> List.to_tuple()
  defp nodes([], _left, acc), do: acc |> Enum.reverse() |> List.to_tuple()

  defp nodes([line | rest], left, acc) do
    case String.split(line) do
      [] ->
        nodes(rest, left, acc)

      words ->
        [x, y, z, radius, links] = Enum.take(words ++ List.duplicate("0", 5), 5)
        {links, rest} = links(rest, max(trunc(Strings.number(links)), 0), [])
        at = {Strings.number(x), Strings.number(y), Strings.number(z)}
        nodes(rest, left - 1, [%{at: at, radius: Strings.number(radius), links: links} | acc])
    end
  end

  defp links(rest, 0, acc), do: {Enum.reverse(acc), rest}
  defp links([], _left, acc), do: {Enum.reverse(acc), []}

  defp links([line | rest], left, acc) do
    case String.split(line) do
      [] ->
        links(rest, left, acc)

      words ->
        [target, cost, flags] = Enum.take(words ++ List.duplicate("0", 3), 3)

        link =
          {trunc(Strings.number(target)), Strings.number(cost), trunc(Strings.number(flags))}

        links(rest, left - 1, [link | acc])
    end
  end

  defp nearest(_server, graph, _point) when tuple_size(graph) == 0, do: -1

  defp nearest(server, graph, point) do
    0..(tuple_size(graph) - 1)
    |> Enum.map(fn index -> {closeness(elem(graph, index), point), index} end)
    |> Enum.sort()
    |> Enum.find_value(-1, fn {closeness, index} ->
      if closeness <= 0 or seen?(server, point, elem(graph, index).at), do: index
    end)
  end

  defp closeness(%{at: at, radius: radius}, point) do
    distance = at |> Vec.sub(point) |> Vec.dot(Vec.sub(at, point))
    inside = radius * radius
    if distance < inside, do: distance - inside, else: distance
  end

  defp seen?(server, point, at), do: World.trace_world(server, point, at).fraction >= 1.0

  defp records(graph, start, destination, from, to, deny) when from >= 0 and to >= 0 do
    case search(graph, to, destination, deny, [{from, 0.0}], %{from => 0.0}, %{}) do
      nil -> fallback(start, destination)
      came_from -> path_records(graph, start, destination, from, to, came_from)
    end
  end

  defp records(_graph, start, destination, _from, _to, _deny), do: fallback(start, destination)

  defp fallback(start, destination), do: [{destination, @destination, 0.0}, {start, 0, 0.0}]

  defp path_records(graph, start, destination, from, to, came_from) do
    [{destination, @destination, 32.0} | back(graph, from, to, came_from, [])] ++
      [{start, 0, 32.0}]
  end

  defp back(graph, from, node, came_from, acc) do
    {previous, flags} = Map.get(came_from, node, {nil, 0})
    acc = [{elem(graph, node).at, flags, elem(graph, node).radius} | acc]

    if node == from,
      do: Enum.reverse(acc),
      else: back(graph, from, previous, came_from, acc)
  end

  defp search(_graph, _goal, _destination, _deny, [], _costs, _came_from), do: nil

  defp search(graph, goal, destination, deny, open, costs, came_from) do
    {node, _} = List.last(open)
    open = Enum.drop(open, -1)

    if node == goal do
      came_from
    else
      {open, costs, came_from} =
        Enum.reduce(
          elem(graph, node).links,
          {open, costs, came_from},
          &relax(&1, &2, node, {graph, destination, deny})
        )

      search(graph, goal, destination, deny, open, costs, came_from)
    end
  end

  defp relax({target, link_cost, flags}, {open, costs, came_from} = state, node, context) do
    {graph, destination, deny} = context
    cost = Map.fetch!(costs, node) + link_cost

    cond do
      band(flags, deny) != 0 or target < 0 or target >= tuple_size(graph) ->
        state

      cost >= Map.get(costs, target, :infinity) ->
        state

      true ->
        guess = cost + Vec.length(Vec.sub(destination, elem(graph, target).at))

        {queue(open, target, guess), Map.put(costs, target, cost),
         Map.put(came_from, target, {node, flags})}
    end
  end

  defp queue(open, target, guess) do
    case Enum.find_index(open, fn {node, _} -> node == target end) do
      nil -> insert(open, target, guess)
      at -> requeue(open, at, target, guess)
    end
  end

  defp insert(open, target, guess) do
    at =
      open
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(0, fn {{_, cost}, index} -> if guess <= cost, do: index + 1 end)

    List.insert_at(open, at, {target, guess})
  end

  defp requeue(open, at, target, guess) do
    {_, old} = Enum.at(open, at)

    if guess < old do
      {before, [_ | rest]} = Enum.split(open, at)
      {moved, kept} = Enum.split_while(rest, fn {_, cost} -> cost > guess end)
      before ++ moved ++ [{target, guess} | kept]
    else
      open
    end
  end

  defp write(qc, records) do
    {qc, pointer} = QuakeC.alloc(qc, length(records) * 20)

    qc =
      records
      |> Enum.with_index()
      |> Enum.reduce(qc, fn {{{x, y, z}, flags, radius}, i}, qc ->
        at = pointer + i * 20

        qc
        |> QuakeC.store(at, x / 1)
        |> QuakeC.store(at + 4, y / 1)
        |> QuakeC.store(at + 8, z / 1)
        |> QuakeC.store(at + 12, flags)
        |> QuakeC.store(at + 16, radius / 1)
      end)

    {qc, pointer}
  end
end
