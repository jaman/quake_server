defmodule QuakeServer.Extensions.Control do
  @moduledoc """
  FTE's `abort` (211), which stops every QuakeC function running
  (`QuakeC.Exec.abort/1`), and `checkcommand` (294), which says what a console name is,
  in the order the console looks: 1 a command (the console's own,
  `QuakeServer.Console.command?/1`, or one the program registered), 2 an alias, 3 a
  console variable, 0 nothing.
  """

  alias QuakeServer.{Args, Console, Cvars}

  @doc "Run builtin `builtin`, 211 or 294."
  @spec call(map(), integer(), non_neg_integer()) :: map()
  def call(s, 211, _argc), do: QuakeC.Exec.abort(s)

  def call(s, 294, _argc) do
    name = Args.str(s, 0)

    kind =
      cond do
        Console.command?(name) or registered?(s, name) -> 1.0
        alias?(s, name) -> 2.0
        variable?(s, name) -> 3.0
        true -> 0.0
      end

    Args.return(s, kind)
  end

  defp registered?(s, name), do: s.ext |> Map.get(:commands, MapSet.new()) |> MapSet.member?(name)

  defp alias?(%{cvars: %Cvars{} = cvars}, name), do: Cvars.command_alias(cvars, name) != nil
  defp alias?(_s, _name), do: false

  defp variable?(%{cvars: %Cvars{} = cvars}, name), do: Cvars.fetch(cvars, name) != nil
  defp variable?(_s, _name), do: false
end
