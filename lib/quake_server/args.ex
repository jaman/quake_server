defmodule QuakeServer.Args do
  @moduledoc """
  A builtin's arguments and result: argument `i` (from 0) sits in the program's
  parameter slots at `4 + 3 * i`, and the result goes to slot 1.

      QuakeServer.Args.num(server, 0)
      QuakeServer.Args.return(server, 1.0)
  """

  @return 1

  @doc "Argument `i` as it is held."
  @spec slot(map(), non_neg_integer()) :: QuakeC.value()
  def slot(host, i), do: QuakeC.slot(host.qc, 4 + i * 3)

  @doc "Argument `i` as a float."
  @spec num(map(), non_neg_integer()) :: float()
  def num(host, i), do: QuakeC.float(slot(host, i))

  @doc "Argument `i` as an integer: an entity, an integer or a float cut to one."
  @spec int(map(), non_neg_integer()) :: integer()
  def int(host, i) do
    case slot(host, i) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _ -> 0
    end
  end

  @doc "Argument `i` as a vector."
  @spec vec(map(), non_neg_integer()) :: QuakeC.vector()
  def vec(host, i), do: QuakeC.slot_vector(host.qc, 4 + i * 3)

  @doc "Argument `i`'s three slots as they are held, for a value of any type."
  @spec vec_raw(map(), non_neg_integer()) :: {QuakeC.value(), QuakeC.value(), QuakeC.value()}
  def vec_raw(host, i) do
    at = 4 + i * 3
    {QuakeC.slot(host.qc, at), QuakeC.slot(host.qc, at + 1), QuakeC.slot(host.qc, at + 2)}
  end

  @doc "Argument `i` as text."
  @spec str(map(), non_neg_integer()) :: String.t()
  def str(host, i), do: QuakeC.string(host.qc, slot(host, i))

  @doc "Argument `i` as text, or `default` when the call passed fewer than `i + 1` arguments."
  @spec str(map(), non_neg_integer(), non_neg_integer(), String.t()) :: String.t()
  def str(host, i, argc, default), do: if(i < argc, do: str(host, i), else: default)

  @doc "Argument `i` as a float, or `default` when the call passed fewer than `i + 1` arguments."
  @spec num(map(), non_neg_integer(), non_neg_integer(), float()) :: float()
  def num(host, i, argc, default), do: if(i < argc, do: num(host, i), else: default)

  @doc "The value of global `self`, an entity number."
  @spec self(map()) :: non_neg_integer()
  def self(host), do: trunc(QuakeC.float(QuakeC.global(host.qc, "self")))

  @doc "Write the builtin's result; a vector fills three slots, a boolean becomes 1.0 or 0.0."
  @spec return(map(), QuakeC.value() | QuakeC.vector() | boolean()) :: map()
  def return(host, true), do: return(host, 1.0)
  def return(host, false), do: return(host, 0.0)

  def return(host, {x, y, z}) do
    qc =
      host.qc
      |> QuakeC.put_slot(@return, x)
      |> QuakeC.put_slot(@return + 1, y)
      |> QuakeC.put_slot(@return + 2, z)

    %{host | qc: qc}
  end

  def return(host, value) do
    case QuakeC.update_slot(host.qc, @return, value) do
      :ok -> host
      qc -> %{host | qc: qc}
    end
  end
end
