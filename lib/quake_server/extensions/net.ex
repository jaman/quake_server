defmodule QuakeServer.Extensions.Net do
  @moduledoc """
  FTE's message builtins beyond Quake's: writing floats and integers, and `multicast`,
  which sends the message built with `MSG_MULTICAST` (`QuakeServer.Multicast.send/4`)
  and starts a new one.
  """

  alias QuakeServer.{Args, Multicast}
  alias QuakeServer.Builtins.Write

  @doc "Run message builtin `builtin` (a number or a name)."
  @spec call(map(), integer() | String.t(), non_neg_integer()) :: map()
  def call(s, builtin, _argc) when builtin in [280, "WriteInt", 456],
    do: Write.write(s, builtin, Args.slot(s, 1))

  def call(s, 82, _argc) do
    bytes = Map.get(s.ext, :multicast, <<>>)
    s = %{s | ext: Map.put(s.ext, :multicast, <<>>)}
    Multicast.send(s, Args.vec(s, 0), trunc(Args.num(s, 1)), bytes)
  end
end
