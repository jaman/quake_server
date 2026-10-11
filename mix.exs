defmodule QuakeServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :quake_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      description:
        "The server of the Quake engine in Elixir: runs a QuakeC game's levels, its physics, monster movement and builtins.",
      package: [licenses: ["GPL-2.0-or-later"]],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl, :public_key]]

  defp deps do
    [
      {:quake_c, path: "../cauldron/quake_c"},
      {:cauldron_3d, path: "../cauldron/cauldron_3d"},
      {:cauldron_3d_formats, path: "../cauldron/cauldron_3d_formats"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
