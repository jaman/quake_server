defmodule QuakeServer.Extensions.Memory do
  @moduledoc """
  FTE's builtins over a program's memory as bytes: `createbuffer` (a zeroed block one
  byte longer than asked, or null for a size below 1), `memrealloc` (a new block holding
  the old one's bytes, the old one given back; a size of 0 is taken as 1, one below 0 or
  above 16 MiB fails with null), `memcmp` (bytes compared as unsigned, the sign of the
  first difference) and `memstrsize` (a string's length in bytes).

  Memory words hold integers, floats and strings made while running; as bytes an integer
  is its 32 bits and a float its single-precision bits, little end first, and a string
  reads as zeros.
  """

  import Bitwise

  alias QuakeServer.Args

  @limit 0x01000000

  @doc "Run memory builtin `builtin`."
  @spec call(map(), String.t(), non_neg_integer()) :: map()
  def call(s, "createbuffer", _argc) do
    case Args.int(s, 0) do
      size when size <= 0 ->
        Args.return(s, 0)

      size ->
        {qc, address} = QuakeC.alloc(s.qc, size + 1)
        Args.return(%{s | qc: qc}, address)
    end
  end

  def call(s, "memrealloc", _argc) do
    old = Args.int(s, 0)
    size = if Args.int(s, 1) == 0, do: 1, else: Args.int(s, 1)

    if size < 0 or size > @limit do
      Args.return(s, 0)
    else
      words = min(div(size + 3, 4), block_words(s.qc, old))
      {qc, address} = QuakeC.alloc(s.qc, size)
      qc = if words > 0, do: QuakeC.move(qc, old, address, words), else: qc
      Args.return(%{s | qc: QuakeC.free(qc, old)}, address)
    end
  end

  def call(s, "memcmp", argc) do
    size = Args.int(s, 2)
    from = Args.int(s, 1) + if(argc > 3, do: Args.int(s, 3), else: 0)
    to = Args.int(s, 0) + if(argc > 4, do: Args.int(s, 4), else: 0)

    if size <= 0 do
      Args.return(s, 0)
    else
      Args.return(s, compare(bytes(s.qc, to, size), bytes(s.qc, from, size)))
    end
  end

  def call(s, "memstrsize", _argc), do: Args.return(s, byte_size(Args.str(s, 0)) / 1)

  @doc "`size` bytes of the program's memory from byte address `address`."
  @spec bytes(QuakeC.t(), integer(), non_neg_integer()) :: binary()
  def bytes(_qc, _address, size) when size <= 0, do: <<>>

  def bytes(qc, address, size) do
    first = address - rem(address, 4)
    skip = address - first
    words = div(skip + size + 3, 4)

    data =
      for i <- 0..(words - 1)//1, into: <<>>, do: word_bytes(QuakeC.load(qc, first + 4 * i))

    binary_part(data, skip, size)
  end

  @doc "Write `data` into the program's memory from byte address `address`, the bytes around it in its words kept."
  @spec put_bytes(QuakeC.t(), integer(), binary()) :: QuakeC.t()
  def put_bytes(qc, _address, <<>>), do: qc

  def put_bytes(qc, address, data) do
    first = address - rem(address, 4)
    skip = address - first
    words = div(skip + byte_size(data) + 3, 4)
    old = bytes(qc, first, words * 4)
    tail = binary_part(old, skip + byte_size(data), words * 4 - skip - byte_size(data))
    merged = binary_part(old, 0, skip) <> data <> tail

    for(<<word::little-signed-32 <- merged>>, do: word)
    |> Enum.with_index()
    |> Enum.reduce(qc, fn {word, i}, qc -> QuakeC.store(qc, first + 4 * i, word) end)
  end

  defp block_words(qc, address) do
    word = div(address - QuakeC.heap_base(), 4)
    Map.get(qc.blocks, word, 0)
  end

  defp compare(<<a, rest_a::binary>>, <<a, rest_b::binary>>), do: compare(rest_a, rest_b)
  defp compare(<<a, _::binary>>, <<b, _::binary>>), do: a - b
  defp compare(_a, _b), do: 0

  defp word_bytes(value) when is_integer(value), do: <<band(value, 0xFFFFFFFF)::little-32>>
  defp word_bytes(value) when is_float(value), do: <<value::little-float-32>>
  defp word_bytes(_value), do: <<0::32>>
end
