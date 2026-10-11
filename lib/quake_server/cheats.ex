defmodule QuakeServer.Cheats do
  @moduledoc """
  FTE's player cheat commands, for the host's player (entity 1), allowed as FTE's
  `SV_MayCheat` allows them: with `sv_cheats` set, or always on a single-player server.

    * `setpos/2` (`Cmd_SetPos_f`) — with no position, prints the player's place as a
      `setpos x y z pitch yaw roll` line (origin and view angles); with `x y z`, moves the
      player there, stopped and in noclip (printing `noclip on` when it was off), and with
      `x y z pitch yaw roll` also turns the player (`fixangle` set)
    * `noclip/1` (`Cmd_Noclip_f`) — noclip on (`MOVETYPE_NOCLIP`, `SOLID_TRIGGER`) or off
      (`MOVETYPE_WALK`, `SOLID_SLIDEBOX`, or `SOLID_NOT` when dead), printing
      `noclip ON` or `noclip OFF`

  Prints reach the player as `svc_print` at level 2 (`QuakeServer.Outbox`) and the
  server's events.

      server = QuakeServer.Cheats.setpos(server, ["-1250", "-718", "40"])
  """

  alias QuakeServer.{Edicts, Events, Outbox, Q, Server, TextNumbers, World}

  @player 1
  @high 2

  @doc "Run FTE's `setpos` with the command's arguments (the words after `setpos`)."
  @spec setpos(Server.t(), [String.t()]) :: Server.t()
  def setpos(%Server{} = server, args) do
    cond do
      not may_cheat?(server) -> say(server, "Cheats are not allowed on this server\n")
      length(args) not in [3, 6] -> say(server, position_line(server))
      true -> place(server, Enum.map(args, &TextNumbers.atof/1))
    end
  end

  @doc "Run FTE's `noclip` for the player."
  @spec noclip(Server.t()) :: Server.t()
  def noclip(%Server{} = server) do
    cond do
      not may_cheat?(server) ->
        say(server, "Cheats are not allowed on this server\n")

      Edicts.int(server, @player, "movetype") != Q.movetype(:noclip) ->
        server
        |> Edicts.put(@player, "movetype", Q.movetype(:noclip) / 1)
        |> Edicts.put(@player, "solid", Q.solid(:trigger) / 1)
        |> say("noclip ON\n")

      true ->
        solid = if Edicts.float(server, @player, "health") > 0, do: :slidebox, else: :not

        server
        |> Edicts.put(@player, "movetype", Q.movetype(:walk) / 1)
        |> Edicts.put(@player, "solid", Q.solid(solid) / 1)
        |> say("noclip OFF\n")
    end
  end

  defp may_cheat?(server), do: Server.cvar(server, "sv_cheats") != 0 or server.slots == 1

  defp place(server, [x, y, z | angles]) do
    server =
      if Edicts.int(server, @player, "movetype") != Q.movetype(:noclip),
        do:
          server
          |> Edicts.put(@player, "movetype", Q.movetype(:noclip) / 1)
          |> say("noclip on\n"),
        else: server

    server
    |> Edicts.put(@player, "velocity", {0.0, 0.0, 0.0})
    |> Edicts.put(@player, "origin", {x, y, z})
    |> World.link(@player, false)
    |> turn(angles)
  end

  defp turn(server, [pitch, yaw, roll]) do
    server
    |> Edicts.put(@player, "angles", {pitch, yaw, roll})
    |> Edicts.put(@player, "fixangle", 1.0)
  end

  defp turn(server, []), do: server

  defp position_line(server) do
    {x, y, z} = Edicts.vector(server, @player, "origin")
    {pitch, yaw, roll} = Edicts.vector(server, @player, "v_angle")
    "setpos " <> Enum.map_join([x, y, z, pitch, yaw, roll], " ", &six_places/1) <> "\n"
  end

  defp six_places(value), do: :erlang.float_to_binary(value / 1, decimals: 6)

  defp say(server, text),
    do: server |> Outbox.print(@player, @high, text) |> Events.print(:notify, text)
end
