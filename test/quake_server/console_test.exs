defmodule QuakeServer.ConsoleTest do
  use ExUnit.Case, async: true

  alias QuakeServer.{Console, Cvars, Server}
  alias QuakeServer.Cvars.Engine

  test "a program's localcmd restart reaches the host as a command event" do
    server = %Server{
      cvars: Engine.register(Cvars.new()),
      map: "",
      ext: %{},
      console: ["restart\n"]
    }

    {events, _server} = server |> Console.flush() |> Server.drain()

    assert {:command, "restart"} in events
  end
end
