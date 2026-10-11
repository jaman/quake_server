defmodule QuakeServer.Cvars.Cvar do
  @moduledoc """
  One console variable as `QuakeServer.Cvars.fetch/2` reads it.

    * `name` — the name it was made with
    * `string` — its value as text
    * `value` — the text read as a number, a 32-bit float (FTE's `Q_atof`)
    * `ival` — the text read as a whole number (FTE's `Q_atoi`)
    * `default` — the value `cvarreset` gives back; configs move it with
      `cvar_lockdefaults`
    * `engine` — the engine's own default, `nil` for a variable the engine does not
      register
    * `flags` — the flag bitmask, see `QuakeServer.Cvars.flags/0`
    * `latched` — a value waiting to take effect, or `nil`
    * `description` — what it is for, or `nil`
    * `group` — the group it is listed and saved under
    * `alias` — its second name, or `nil`
  """

  @enforce_keys [:name, :string]
  defstruct [
    :name,
    :string,
    :value,
    :ival,
    :default,
    :engine,
    :latched,
    :description,
    :alias,
    flags: 0,
    group: "Custom variables"
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          string: String.t(),
          value: float(),
          ival: integer(),
          default: String.t(),
          engine: String.t() | nil,
          flags: non_neg_integer(),
          latched: String.t() | nil,
          description: String.t() | nil,
          group: String.t(),
          alias: String.t() | nil
        }
end
