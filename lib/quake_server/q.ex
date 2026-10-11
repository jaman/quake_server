defmodule QuakeServer.Q do
  @moduledoc """
  The fixed numbers QuakeC programs share with FTE's server: move types, solid kinds,
  entity flags, contents, effects, spawn flags and message types.

      QuakeServer.Q.movetype(:walk)
      #=> 3
  """

  import Bitwise

  @movetypes %{
    none: 0,
    angle_noclip: 1,
    angle_clip: 2,
    walk: 3,
    step: 4,
    fly: 5,
    toss: 6,
    push: 7,
    noclip: 8,
    flymissile: 9,
    bounce: 10,
    follow: 12
  }
  @solids %{not: 0, trigger: 1, bbox: 2, slidebox: 3, bsp: 4, corpse: 5, bsp_trigger: 22}
  @flags %{
    fly: 1,
    swim: 2,
    client: 8,
    inwater: 16,
    monster: 32,
    godmode: 64,
    notarget: 128,
    item: 256,
    onground: 512,
    partialground: 1024,
    waterjump: 2048,
    jumpreleased: 4096
  }
  @contents %{empty: -1, solid: -2, water: -3, slime: -4, lava: -5, sky: -6}
  @effects %{brightfield: 1, muzzleflash: 2, brightlight: 4, dimlight: 8}

  @doc "The number of move type `name`."
  @spec movetype(atom()) :: integer()
  def movetype(name), do: Map.fetch!(@movetypes, name)

  @doc "The number of solid kind `name`."
  @spec solid(atom()) :: integer()
  def solid(name), do: Map.fetch!(@solids, name)

  @doc "Whether solid kind `solid` is a trigger: a box (`:trigger`) or a brush model's shape (`:bsp_trigger`)."
  @spec trigger?(integer()) :: boolean()
  def trigger?(solid), do: solid == 1 or solid == 22

  @doc "Whether solid kind `solid` collides by a brush model's shape (`:bsp` or `:bsp_trigger`)."
  @spec brush?(integer()) :: boolean()
  def brush?(solid), do: solid == 4 or solid == 22

  @doc "The bit of entity flag `name`."
  @spec flag(atom()) :: integer()
  def flag(name), do: Map.fetch!(@flags, name)

  @doc "The contents value `name`."
  @spec contents(atom()) :: integer()
  def contents(name), do: Map.fetch!(@contents, name)

  @doc "The bit of effect `name`."
  @spec effect(atom()) :: integer()
  def effect(name), do: Map.fetch!(@effects, name)

  @doc "Whether the flags value `value` has flag `name` set."
  @spec flag?(number(), atom()) :: boolean()
  def flag?(value, name), do: (trunc(value) &&& flag(name)) != 0

  @doc "The flags value with flag `name` set."
  @spec set_flag(number(), atom()) :: float()
  def set_flag(value, name), do: (trunc(value) ||| flag(name)) / 1

  @doc "The flags value with flag `name` cleared."
  @spec clear_flag(number(), atom()) :: float()
  def clear_flag(value, name), do: (trunc(value) &&& bnot(flag(name))) / 1

  @doc "Whether a spawn flags value keeps an entity out of a single-player game at `skill` (0 to 3)."
  @spec skill_inhibited?(number(), 0..3) :: boolean()
  def skill_inhibited?(spawnflags, skill), do: inhibited?(spawnflags, skill, false)

  @doc "Whether a spawn flags value keeps an entity out of a game at `skill` (0 to 3), deathmatch or not."
  @spec inhibited?(number(), 0..3, boolean()) :: boolean()
  def inhibited?(spawnflags, _skill, true), do: (trunc(spawnflags) &&& 2048) != 0
  def inhibited?(spawnflags, 0, false), do: (trunc(spawnflags) &&& 256) != 0
  def inhibited?(spawnflags, 1, false), do: (trunc(spawnflags) &&& 512) != 0
  def inhibited?(spawnflags, _skill, false), do: (trunc(spawnflags) &&& 1024) != 0
end
