defmodule QuakeServer.Contents do
  @moduledoc """
  FTE's contents as bits (`bspfile.h`), and the translation from the codes Quake and
  Half-Life maps store (`Q1BSP_TranslateContents`, and the contents a brush entity's
  negative `skin` forces on all of its brushes).

      QuakeServer.Contents.of_code(-16)
      #=> QuakeServer.Contents.bit(:ladder)

  Half-Life's currents are water with a current bit; its translucent contents are empty;
  its clip brushes are player and monster clip.
  """

  import Bitwise

  @bits %{
    empty: 0,
    solid: 0x00000001,
    window: 0x00000002,
    lava: 0x00000008,
    slime: 0x00000010,
    water: 0x00000020,
    ladder: 0x00004000,
    player_clip: 0x00010000,
    monster_clip: 0x00020000,
    current_0: 0x00040000,
    current_90: 0x00080000,
    current_180: 0x00100000,
    current_270: 0x00200000,
    current_up: 0x00400000,
    current_down: 0x00800000,
    body: 0x02000000,
    corpse: 0x04000000,
    detail: 0x08000000,
    sky: 0x80000000
  }

  @fluid 0x00000008 ||| 0x00000010 ||| 0x00000020 ||| 0x80000000

  @doc "The bit of contents `name`."
  @spec bit(atom()) :: non_neg_integer()
  def bit(name), do: Map.fetch!(@bits, name)

  @doc "Water, slime, lava and sky: what Quake's code counts as a fluid."
  @spec fluid() :: non_neg_integer()
  def fluid, do: @fluid

  @doc "Whether `bits` hold a fluid."
  @spec fluid?(non_neg_integer()) :: boolean()
  def fluid?(bits), do: (bits &&& @fluid) != 0

  @doc "Whether `bits` hold contents `name`."
  @spec has?(non_neg_integer(), atom()) :: boolean()
  def has?(bits, name), do: (bits &&& bit(name)) != 0

  @doc "The bits of contents code `code` a map's hull stores (`Q1BSP_TranslateContents`)."
  @spec of_code(integer()) :: non_neg_integer()
  def of_code(-1), do: bit(:empty)
  def of_code(-2), do: bit(:solid)
  def of_code(-3), do: bit(:water)
  def of_code(-4), do: bit(:slime)
  def of_code(-5), do: bit(:lava)
  def of_code(-6), do: bit(:sky) ||| bit(:player_clip) ||| bit(:monster_clip)
  def of_code(-8), do: bit(:player_clip) ||| bit(:monster_clip)
  def of_code(-9), do: bit(:water) ||| bit(:current_0)
  def of_code(-10), do: bit(:water) ||| bit(:current_90)
  def of_code(-11), do: bit(:water) ||| bit(:current_180)
  def of_code(-12), do: bit(:water) ||| bit(:current_270)
  def of_code(-13), do: bit(:water) ||| bit(:current_up)
  def of_code(-14), do: bit(:water) ||| bit(:current_down)
  def of_code(-15), do: bit(:empty)
  def of_code(-16), do: bit(:ladder)
  def of_code(-17), do: bit(:monster_clip)
  def of_code(-18), do: bit(:player_clip)
  def of_code(-19), do: bit(:corpse)
  def of_code(_code), do: bit(:solid)

  @doc """
  The bits a brush entity's negative `skin` forces on every brush of its model; `0` for a
  skin that forces nothing.
  """
  @spec forced(integer()) :: non_neg_integer()
  def forced(-6), do: bit(:sky)
  def forced(skin) when skin in [-1, -2, -3, -4, -5] or skin in -19..-8//1, do: of_code(skin)
  def forced(_skin), do: 0

  @doc "Quake's code for `bits` as a program's `watertype` reads it: lava, slime, water or empty."
  @spec water_code(non_neg_integer()) :: integer()
  def water_code(bits) do
    cond do
      has?(bits, :lava) -> -5
      has?(bits, :slime) -> -4
      has?(bits, :water) -> -3
      true -> -1
    end
  end

  @doc "Quake's code for fluid `bits`: lava, slime, water, or sky for any other fluid."
  @spec fluid_code(non_neg_integer()) :: integer()
  def fluid_code(bits) do
    cond do
      has?(bits, :lava) -> -5
      has?(bits, :slime) -> -4
      has?(bits, :water) -> -3
      true -> -6
    end
  end

  @leaf_bits {0, 0x00000001, 0x00000020, 0x00000010, 0x00000008, 0x80000000, 0x00000001,
              0x00010000, 0x00040000, 0x00080000, 0x00100000, 0x00200000, 0x00400000, 0x00800000,
              0x00000002, 0x00004000}

  @doc """
  The bits a hull trace gives the leaf contents code `code` (`q1toftecontents`): clip is
  player clip alone, Half-Life's translucent contents are window, its currents are the
  current bits without water. A code below -16 counts as solid.
  """
  @spec of_leaf(integer()) :: non_neg_integer()
  def of_leaf(code) when code <= -1 and code >= -16, do: elem(@leaf_bits, -1 - code)
  def of_leaf(_code), do: bit(:solid)

  @doc "Quake's code for `bits` as the `pointcontents` builtin gives it: solid, sky, lava, slime, water, ladder or empty, the first held."
  @spec point_code(non_neg_integer()) :: integer()
  def point_code(bits) do
    cond do
      has?(bits, :solid) -> -2
      has?(bits, :sky) -> -6
      has?(bits, :lava) -> -5
      has?(bits, :slime) -> -4
      has?(bits, :water) -> -3
      has?(bits, :ladder) -> -16
      true -> -1
    end
  end

  @dp_pairs [
    {1, 0x00000001},
    {2, 0x00000020},
    {4, 0x00000010},
    {8, 0x00000008},
    {16, 0x80000000},
    {32, 0x02000000},
    {64, 0x04000000},
    {128, 0x80000000},
    {256, 0x00010000},
    {512, 0x00020000},
    {1024, 0x00200000},
    {2048, 0x00400000}
  ]

  @doc "Darkplaces contents bits (`dphitcontentsmask`) as FTE's."
  @spec from_dp(non_neg_integer()) :: non_neg_integer()
  def from_dp(dp) do
    Enum.reduce(@dp_pairs, 0, fn {dp_bit, fte_bit}, bits ->
      if (dp &&& dp_bit) != 0, do: bits ||| fte_bit, else: bits
    end)
  end

  @doc "FTE contents bits as Darkplaces'."
  @spec to_dp(non_neg_integer()) :: non_neg_integer()
  def to_dp(bits) do
    Enum.reduce(@dp_pairs, 0, fn {dp_bit, fte_bit}, dp ->
      if (bits &&& fte_bit) != 0, do: dp ||| dp_bit, else: dp
    end)
  end
end
