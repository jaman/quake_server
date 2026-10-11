defmodule QuakeServer.Extensions.Effects do
  @moduledoc """
  FTE's effect and sound builtins: named particle effects by number, effects at a point
  and along a trail, the `te_` temporary effects, sounds at a point and with pitch, and
  sound numbers. Each becomes an event for the client (`QuakeServer.Server.emit/2`):

    * `{:effect, name, %{origin:, direction:, count:}}`
    * `{:trail, name, %{entity:, from:, to:}}`
    * `{:temp, kind, map}`, `kind` the effect's name without `te_`

  `sound` (8) and `pointsound` (483) start sounds through `QuakeServer.Sounds`, with
  FTE's arguments: pitch in percent, flags and a start offset; under a QuakeWorld program
  without flags, channel bit 8 sends reliably and is taken out of the channel number.

  Effect numbers are kept in the host's `ext.effects`, from 1 up, and reach the players
  as FTE's particle precaches (`QuakeServer.Precaches`). As FTE's `PF_sv_pointparticles`
  and `PF_sv_trailparticles` do, an effect with a number above 0 also goes to the players
  that may hear its point (`QuakeServer.Multicast`, unreliably):
  `<<82, effect::little-16, origin>>` (`svcfte_pointparticles1`) for one with count 1 and
  no direction, else `<<81, effect::little-16, origin, direction, count::little-16>>`
  (`svcfte_pointparticles`, count at most 65535); a trail as `<<80, entity::little-16,
  effect::little-16, from, to>>` (`svcfte_trailparticles`), its arguments taken in
  DarkPlaces' order (entity first) when the second is a non-zero number. Points are
  written as `WriteCoord` writes them.

  `getsoundindex(name)` is the index of `name` in the server's sound list, adding it when
  it is not there, or 0 when the second argument is given and not 0 and the sound is not
  on the list.
  """

  alias Cauldron3D.Vec
  alias QuakeServer.{Args, Models, Multicast, Server, Sounds}
  alias QuakeServer.Builtins.Write

  @phs 1
  @trailparticles 80
  @pointparticles 81
  @pointparticles1 82

  @temps %{
    405 => {:blood, [:vector, :vector, :number]},
    406 => {:bloodshower, [:vector, :vector, :number, :number]},
    407 => {:explosionrgb, [:vector, :vector]},
    408 => {:particlecube, [:vector, :vector, :vector, :number, :number, :number, :number]},
    409 => {:particlerain, [:vector, :vector, :vector, :number, :number]},
    410 => {:particlesnow, [:vector, :vector, :vector, :number, :number]},
    411 => {:spark, [:vector, :vector, :number]},
    412 => {:gunshotquad, [:vector]},
    413 => {:spikequad, [:vector]},
    414 => {:superspikequad, [:vector]},
    415 => {:explosionquad, [:vector]},
    416 => {:smallflash, [:vector]},
    417 => {:customflash, [:vector, :number, :number, :vector]},
    418 => {:gunshot, [:vector, :number]},
    419 => {:spike, [:vector]},
    420 => {:superspike, [:vector]},
    421 => {:explosion, [:vector]},
    422 => {:tarexplosion, [:vector]},
    423 => {:wizspike, [:vector]},
    424 => {:knightspike, [:vector]},
    425 => {:lavasplash, [:vector]},
    426 => {:teleport, [:vector]},
    427 => {:explosion2, [:vector, :number, :number]},
    428 => {:lightning1, [:entity, :vector, :vector]},
    429 => {:lightning2, [:entity, :vector, :vector]},
    430 => {:lightning3, [:entity, :vector, :vector]},
    431 => {:beam, [:entity, :vector, :vector]},
    433 => {:plasmaburn, [:vector]},
    457 => {:flamejet, [:vector, :vector, :number]},
    219 => {:lightningblood, [:vector, :vector, :vector]},
    239 => {:bloodqw, [:vector, :number]}
  }

  @doc "The `te_` builtin numbers."
  @spec temps() :: [integer()]
  def temps, do: Map.keys(@temps)

  @doc "Run effect builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, 335, _argc) do
    name = Args.str(s, 0)
    effects = Map.get(s.ext, :effects, %{})

    case Map.get(effects, name) do
      nil ->
        number = map_size(effects) + 1

        %{s | ext: Map.put(s.ext, :effects, Map.put(effects, name, number))}
        |> Args.return(number / 1)

      number ->
        Args.return(s, number / 1)
    end
  end

  def call(s, 337, argc) do
    number = Args.int(s, 0)
    origin = Args.vec(s, 1)
    direction = if argc > 2, do: Args.vec(s, 2), else: {0.0, 0.0, 0.0}
    count = Args.num(s, 3, argc, 1.0)

    s
    |> Server.emit(
      {:effect, effect_name(s, number), %{origin: origin, direction: direction, count: count}}
    )
    |> send_point(number, origin, direction, trunc(count))
  end

  def call(s, 336, _argc) do
    {number, entity} = trail_arguments(s)
    from = Args.vec(s, 2)
    to = Args.vec(s, 3)

    s
    |> Server.emit({:trail, effect_name(s, number), %{entity: entity, from: from, to: to}})
    |> send_trail(number, entity, from, to)
  end

  def call(s, 483, argc) do
    Sounds.start(s, 0, 0, Args.str(s, 1), min(Args.num(s, 2), 1.0), Args.num(s, 3),
      origin: Args.vec(s, 0),
      pitch: Args.num(s, 4, argc, 0.0) * 0.01
    )
  end

  def call(s, 8, argc) do
    {channel, flags} = sound_channel(s, Args.int(s, 1), argc)
    volume = Args.num(s, 3)

    if volume < 0,
      do: s,
      else:
        Sounds.start(s, Args.int(s, 0), channel, Args.str(s, 2), min(volume, 1.0), Args.num(s, 4),
          pitch: Args.num(s, 5, argc, 0.0) * 0.01,
          flags: flags,
          timeofs: Args.num(s, 7, argc, 0.0)
        )
  end

  def call(s, 177, _argc),
    do:
      Server.emit(
        s,
        {:sound,
         %{
           entity: 0,
           channel: 0,
           name: Args.str(s, 0),
           volume: 1.0,
           attenuation: 0.0,
           origin: {0.0, 0.0, 0.0},
           pitch: 100.0
         }}
      )

  def call(s, "getsoundindex", argc) do
    name = Args.str(s, 0)
    query_only? = argc >= 2 and Args.num(s, 1) != 0

    case Enum.find_index(s.sound_names, &(&1 == name)) do
      nil when query_only? or name == "" -> Args.return(s, 0.0)
      nil -> s |> Models.precache_sound(name) |> Args.return(length(s.sound_names) / 1)
      index -> Args.return(s, index / 1)
    end
  end

  def call(s, number, _argc) when is_map_key(@temps, number) do
    {kind, shape} = Map.fetch!(@temps, number)

    values =
      shape
      |> Enum.with_index()
      |> Enum.map(fn
        {:vector, i} -> Args.vec(s, i)
        {:entity, i} -> Args.int(s, i)
        {:number, i} -> Args.num(s, i)
      end)

    Server.emit(
      s,
      {:temp, kind, %{values: values, origin: List.first(Enum.filter(values, &is_tuple/1))}}
    )
  end

  defp send_point(s, number, _origin, _direction, _count) when number <= 0, do: s

  defp send_point(s, number, origin, direction, count) do
    bytes =
      if count == 1 and Vec.dot(direction, direction) == 0,
        do: <<@pointparticles1, number::little-16>> <> Write.coords(s, origin),
        else:
          <<@pointparticles, number::little-16>> <>
            Write.coords(s, origin) <>
            Write.coords(s, direction) <> <<min(count, 65_535)::little-16>>

    Multicast.send(s, origin, @phs, bytes)
  end

  defp send_trail(s, number, _entity, _from, _to) when number <= 0, do: s

  defp send_trail(s, number, entity, from, to),
    do:
      Multicast.send(
        s,
        from,
        @phs,
        <<@trailparticles, entity::little-16, number::little-16>> <>
          Write.coords(s, from) <> Write.coords(s, to)
      )

  defp trail_arguments(s) do
    case Args.slot(s, 1) do
      effect when is_float(effect) and effect != 0.0 -> {trunc(effect), Args.int(s, 0)}
      _entity -> {Args.int(s, 0), Args.int(s, 1)}
    end
  end

  defp sound_channel(s, channel, argc) when argc > 6,
    do: {max(channel, 0), trunc(Args.num(s, 6))}

  defp sound_channel(%{qc: %{progs: %{crc: 54_730}}}, channel, _argc) do
    flags = if Bitwise.band(channel, 8) != 0, do: 1, else: 0

    {Bitwise.bor(
       Bitwise.band(channel, 7),
       Bitwise.bsr(Bitwise.band(channel, Bitwise.bnot(15)), 1)
     ), flags}
  end

  defp sound_channel(_s, channel, _argc), do: {channel, 0}

  defp effect_name(s, number) do
    s.ext
    |> Map.get(:effects, %{})
    |> Enum.find_value("", fn {name, n} -> if n == number, do: name end)
  end
end
