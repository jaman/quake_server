defmodule QuakeServer.Extensions.Levels do
  @moduledoc """
  FTE's `changelevel(map, optional startspot)`: the first change asked for in a frame
  is kept, in the server's `changelevel` and, given a second argument, the landmark in
  `changelevel_startspot`; later ones are ignored.
  """

  alias QuakeServer.Args

  @doc "Run level builtin `builtin`."
  @spec call(map(), integer(), non_neg_integer()) :: map()
  def call(%{changelevel: nil} = s, 70, argc),
    do: %{s | changelevel: Args.str(s, 0), changelevel_startspot: Args.str(s, 1, argc, nil)}

  def call(s, 70, _argc), do: s
end
