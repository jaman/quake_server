defmodule QuakeServer.Requests do
  @moduledoc """
  A client program's `sendevent` arriving at the server, as FTE handles one (its
  `qcrequest`): the program's function `CSEv_<name>_<types>` runs with `self` the player
  and the values in its parameters, `types` being one letter a value — `f` float, `v`
  vector, `i` integer, `s` string, `e` entity. Without values the function is
  `CSEv_<name>_` when the name holds an underscore and `CSEv_<name>` otherwise. A name
  the program has no function for prints that the request is not supported.

      server = QuakeServer.Requests.run(server, 1, "PlayerSwitchWeapon", [{"i", 3}])

  An entity is given by its number on the server; one past the last entity is the world.
  """

  alias QuakeServer.{Events, Server}

  @doc "Run the request `name` with `values` (`{type, value}` pairs) for player `entity`."
  @spec run(Server.t(), non_neg_integer(), String.t(), [{String.t(), term()}]) :: Server.t()
  def run(%Server{} = server, entity, name, values) do
    function_name = function_name(name, values)

    case QuakeC.Progs.function(server.qc.progs, function_name) do
      nil ->
        Events.print(server, :notify, "qcrequest \"#{function_name}\" not supported\n")

      function ->
        qc =
          values
          |> Enum.with_index()
          |> Enum.reduce(server.qc, &put_value(&2, &1, server))

        %{server | qc: qc}
        |> Server.set_globals(entity, QuakeC.global(qc, "other"))
        |> then(&QuakeC.Exec.call(&1, function, &1.builtins, Server.exec_opts(&1)))
    end
  end

  defp function_name(name, []) do
    if String.contains?(name, "_"), do: "CSEv_#{name}_", else: "CSEv_#{name}"
  end

  defp function_name(name, values),
    do: "CSEv_#{name}_" <> Enum.map_join(values, &elem(&1, 0))

  defp put_value(qc, {{"v", vector}, i}, _server),
    do: QuakeC.put_slot_vector(qc, 4 + 3 * i, vector)

  defp put_value(qc, {{"e", number}, i}, server) do
    entity = if is_integer(number) and number >= 0 and number < server.count, do: number, else: 0
    QuakeC.put_slot(qc, 4 + 3 * i, entity)
  end

  defp put_value(qc, {{"i", value}, i}, _server), do: QuakeC.put_slot(qc, 4 + 3 * i, trunc(value))
  defp put_value(qc, {{"s", text}, i}, _server), do: QuakeC.put_slot(qc, 4 + 3 * i, text)
  defp put_value(qc, {{_type, value}, i}, _server), do: QuakeC.put_slot(qc, 4 + 3 * i, value / 1)
end
