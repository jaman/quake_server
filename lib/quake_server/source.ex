defmodule QuakeServer.Source do
  @moduledoc """
  Where a server finds its game: the compiled QuakeC program, the maps and the model
  files. A game names a module with these callbacks as `QuakeServer.Server.start/2`'s
  `:source`.

      defmodule MyGame.Source do
        @behaviour QuakeServer.Source

        def progs, do: MyGame.Assets.progs()
        def map(name), do: MyGame.Assets.map(name)
        def model(name), do: MyGame.Assets.model(name)
      end
  """

  @typedoc "A map: its world and its entity text."
  @type map_file :: %{bsp: Cauldron3D.Bsp.t(), entities: String.t()}

  @typedoc """
  A model file: `kind` `:alias`, `:sprite`, `:brush` (with `data` a `t:map_file/0`) or
  `:missing`, and its box.
  """
  @type model :: %{
          kind: :alias | :sprite | :brush | :missing,
          data: term(),
          mins: Cauldron3D.Vec.t(),
          maxs: Cauldron3D.Vec.t()
        }

  @doc "The game's QuakeC program."
  @callback progs() :: QuakeC.Progs.t()

  @doc "The map `name` (without `maps/` or `.bsp`), or `nil` when there is none."
  @callback map(String.t()) :: map_file() | nil

  @doc "The model file `name`."
  @callback model(String.t()) :: model()

  @doc "The bytes of game file `name`, or `nil`; the files the program's file builtins read."
  @callback read(String.t()) :: binary() | nil

  @doc "The names of the game's files beginning with `prefix`, lower case."
  @callback list(String.t()) :: [String.t()]

  @doc "The package game file `name` comes from, or `nil` when there is no such file."
  @callback package(String.t()) :: String.t() | nil

  @doc """
  Where game file `name` is found in the game's search order, as FTE's
  `COM_FDepthFile`: lower is searched first; `nil` when there is no such file. The
  console's `exec` compares `default.cfg`'s depth with a config's.
  """
  @callback depth(String.t()) :: integer() | nil

  @doc """
  The program's functions the game runs itself, by name: each runs in place of the
  QuakeC function of that name (`QuakeC.Progs.replace/2`) as `fun.(server, argc)`,
  reading its arguments from the parameter slots and returning the server with any
  return value in the return slots, as a builtin does. A name the program lacks is
  passed over.
  """
  @callback replacements() :: %{String.t() => (QuakeServer.Server.t(), non_neg_integer() ->
                                                  QuakeServer.Server.t())}

  @optional_callbacks read: 1, list: 1, package: 1, depth: 1, replacements: 0
end
