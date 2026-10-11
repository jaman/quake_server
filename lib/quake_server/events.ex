defmodule QuakeServer.Events do
  @moduledoc """
  What the server tells the client happened: particles and printed messages, added to
  the server's events. Sounds are `QuakeServer.Sounds`.

      QuakeServer.Events.print(server, :center, "Hello")
  """

  alias Cauldron3D.Vec
  alias QuakeServer.Server

  @doc "Particles at `origin` thrown along `direction`, `count` of them in palette colour `colour`."
  @spec particles(Server.t(), Vec.t(), Vec.t(), number(), number()) :: Server.t()
  def particles(%Server{} = server, origin, direction, colour, count),
    do:
      Server.emit(
        server,
        {:particles,
         %{origin: origin, direction: direction, colour: trunc(colour), count: trunc(count)}}
      )

  @doc "A line of text printed for the player (`:notify`) or in the middle of the screen (`:center`)."
  @spec print(Server.t(), :notify | :center, String.t()) :: Server.t()
  def print(%Server{} = server, where, text), do: Server.emit(server, {:print, where, text})
end
