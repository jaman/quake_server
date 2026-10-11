defmodule QuakeServer.Builtins.Print do
  @moduledoc """
  The print builtins as FTE runs them: `bprint` (23) to every player, `sprint` (24) to
  one, and `centerprint` (73) in the middle of one player's screen, their text joined
  from every argument after the leading ones. A QuakeWorld program (`crc` 54730) gives
  `bprint` and `sprint` a print level before the text; otherwise the level is 2
  (`PRINT_HIGH`). Prints reach a player's reliable messages (`QuakeServer.Outbox`) and,
  as `{:print, :notify | :center, text}`, the server's events. A `sprint` or
  `centerprint` to an entity that is not a player prints that it was tried.

      server = QuakeServer.Builtins.Print.call(server, 24, 3)
  """

  alias QuakeServer.{Args, Events, Outbox, Server}

  @high 2

  @doc "Run print builtin `number` called with `argc` arguments."
  @spec call(Server.t(), 23 | 24 | 73, non_neg_integer()) :: Server.t()
  def call(%Server{} = server, 23, argc) do
    {level, text} =
      if quakeworld?(server),
        do: {level(server, 0), text(server, 1, argc)},
        else: {@high, text(server, 0, argc)}

    server
    |> Outbox.players()
    |> Enum.reduce(server, &Outbox.print(&2, &1, level, text))
    |> Events.print(:notify, text)
  end

  def call(%Server{} = server, 24, argc) do
    {level, text} =
      if quakeworld?(server),
        do: {level(server, 1), text(server, 2, argc)},
        else: {@high, text(server, 1, argc)}

    with_player(server, "sprint", fn player ->
      server |> Outbox.print(player, level, text) |> Events.print(:notify, text)
    end)
  end

  def call(%Server{} = server, 73, argc) do
    text = text(server, 1, argc)

    with_player(server, "centerprint", fn player ->
      server |> Outbox.centerprint(player, text) |> Events.print(:center, text)
    end)
  end

  defp with_player(server, name, print) do
    player = trunc(Args.num(server, 0))

    if player >= 1 and player <= server.slots,
      do: print.(player),
      else: Events.print(server, :notify, "tried to #{name} to a non-client\n")
  end

  defp level(server, index), do: trunc(Args.num(server, index))

  defp text(server, first, argc), do: Enum.map_join(first..(argc - 1)//1, &Args.str(server, &1))

  defp quakeworld?(server), do: server.qc.progs.crc == 54_730
end
