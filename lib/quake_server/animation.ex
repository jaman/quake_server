defmodule QuakeServer.Animation do
  @moduledoc """
  The animation of the entities a program sends itself, carried to each watching player
  as GoldSrc's engine carries `entity_state_t`'s `sequence`, `frame`, `animtime` and
  `framerate` for every entity it sends (`delta.lst`).

      server = QuakeServer.Animation.sample(server)
      {states, server} = QuakeServer.Animation.take(server, 1)
      states #=> %{374 => %{sequence: 0.0, time: 3.0, framerate: 1.0, animtime: 3.97}}

  `sample/1` runs once a server frame, at the server's `time`. For each live entity with
  a `SendEntity`, its state is `sequence`, the program's `frame` (the studio sequence);
  `time`, the program's `frame1time` (seconds into the sequence); `animtime`, the
  server's time; and `framerate`, how many seconds `frame1time` moved for each second
  the server's time moved since the entity's last sample in the same sequence. When the
  sequence changes or `frame1time` goes back, the framerate stays the last one
  measured; an entity sampled the first time has framerate 0. A program without a
  `frame1time` field has no animation.

  `take/2` gives the states of the entities the player holds
  (`QuakeServer.Network.held/2`) that the player was not sent yet, or whose state is not
  the one the player can work out from the state last sent: its sequence or framerate
  differs, or its `time` differs by more than a thousandth of a second from the last
  `time` moved on at the last framerate to the new `animtime`. GoldSrc's client shows
  the sequence at `time + (now - animtime) * framerate` seconds, and with no time passed
  since `animtime` at `time`.
  """

  alias QuakeServer.{Edicts, Network, Server}

  @typedoc "An entity's animation as sent to a player."
  @type state :: %{
          sequence: float(),
          time: float(),
          framerate: float(),
          animtime: float()
        }

  @drift 0.001
  @rate_drift 1.0e-6

  @doc "Sample the animation of every live entity with a `SendEntity` at the server's time."
  @spec sample(Server.t()) :: Server.t()
  def sample(%Server{} = server) do
    if animated?(server), do: put_samples(server, samples(server)), else: server
  end

  @doc "The states player `viewer` lacks of the entities it holds, kept as sent."
  @spec take(Server.t(), non_neg_integer()) :: {%{pos_integer() => state()}, Server.t()}
  def take(%Server{} = server, viewer) do
    samples = Map.get(animation(server), :samples, %{})
    sent = server |> animation() |> Map.get(:sent, %{}) |> Map.get(viewer, %{})

    held =
      for entity <- Network.held(server, viewer),
          state = Map.get(samples, entity),
          state != nil,
          into: %{},
          do: {entity, state}

    changed = Map.filter(held, fn {entity, state} -> changed?(Map.get(sent, entity), state) end)
    kept = sent |> Map.take(Map.keys(held)) |> Map.merge(changed)
    {changed, put_sent(server, viewer, kept)}
  end

  defp animated?(server),
    do:
      QuakeC.field_offset(server.qc, "frame1time") != nil and
        QuakeC.field_offset(server.qc, "SendEntity") != nil

  defp samples(server) do
    last = Map.get(animation(server), :samples, %{})

    for entity <- 1..(server.count - 1)//1,
        not Edicts.free?(server, entity),
        Edicts.int(server, entity, "SendEntity") != 0,
        into: %{},
        do: {entity, measure(Map.get(last, entity), observe(server, entity))}
  end

  defp observe(server, entity),
    do: %{
      sequence: Edicts.float(server, entity, "frame"),
      time: Edicts.float(server, entity, "frame1time"),
      framerate: 0.0,
      animtime: server.time / 1
    }

  defp measure(nil, state), do: state

  defp measure(%{animtime: animtime} = last, %{animtime: animtime}), do: last

  defp measure(%{sequence: sequence, time: before} = last, %{sequence: sequence} = state)
       when state.time >= before,
       do: %{state | framerate: (state.time - before) / (state.animtime - last.animtime)}

  defp measure(last, state), do: %{state | framerate: last.framerate}

  defp changed?(nil, _state), do: true

  defp changed?(last, state) do
    worked_out = last.time + (state.animtime - last.animtime) * last.framerate

    last.sequence != state.sequence or abs(last.framerate - state.framerate) > @rate_drift or
      abs(worked_out - state.time) > @drift
  end

  defp animation(server), do: Map.get(server.ext, :animation, %{})

  defp put_samples(server, samples),
    do: put_animation(server, Map.put(animation(server), :samples, samples))

  defp put_sent(server, viewer, kept) do
    sent = server |> animation() |> Map.get(:sent, %{}) |> Map.put(viewer, kept)
    put_animation(server, Map.put(animation(server), :sent, sent))
  end

  defp put_animation(server, animation),
    do: %{server | ext: Map.put(server.ext, :animation, animation)}
end
