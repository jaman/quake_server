defmodule QuakeServer.Models do
  @moduledoc """
  The models a level has asked for, by index, as the server needs them: their box, and
  for brush models the hulls things collide with.

      QuakeServer.Models.info(server, "*3")
      #=> %{name: "*3", kind: :brush, mins:, maxs:, hulls: [...]}

  A client program's world shares its server's model list (`share/2`): the server's
  models keep the server's indexes, and a model only the client asks for gets an index
  below zero, -1 first. The client's own names are kept in the host's `ext.own_models`.
  """

  alias Cauldron3D.Hull
  alias QuakeServer.Server

  @doc "What the server needs of model `name`: a world submodel `*n`, or a model file."
  @spec info(Server.t(), String.t()) :: map()
  def info(%Server{bsp: bsp}, "*" <> number) do
    index = String.to_integer(number)
    model = elem(bsp.models, index)

    %{
      name: "*" <> number,
      kind: :brush,
      mins: model.mins,
      maxs: model.maxs,
      hulls: hulls(bsp, model)
    }
  end

  def info(%Server{bsp: bsp, map: map} = server, name) do
    if name == "maps/#{map}.bsp" do
      model = elem(bsp.models, 0)
      %{name: name, kind: :brush, mins: model.mins, maxs: model.maxs, hulls: bsp.hulls}
    else
      file(server, name)
    end
  end

  @doc "Register model `name` (a precache), returning its index."
  @spec precache(Server.t(), String.t()) :: {Server.t(), non_neg_integer()}
  def precache(%Server{ext: %{own_models: own}} = server, name) do
    case {index(server, name), Enum.find_index(own, &(&1 == name))} do
      {nil, nil} ->
        index = -(length(own) + 1)

        {%{
           server
           | ext: Map.put(server.ext, :own_models, own ++ [name]),
             models: Map.put(server.models, index, info(server, name))
         }, index}

      {nil, place} ->
        {server, -(place + 1)}

      {index, _} ->
        {server, index}
    end
  end

  def precache(%Server{} = server, name) do
    case Enum.find_index(server.model_names, &(&1 == name)) do
      nil ->
        index = length(server.model_names)

        {%{
           server
           | model_names: server.model_names ++ [name],
             models: Map.put(server.models, index, info(server, name))
         }, index}

      index ->
        {server, index}
    end
  end

  @doc "The index of model `name`, or `nil` when it was never registered."
  @spec index(Server.t(), String.t()) :: integer() | nil
  def index(%Server{model_names: names, ext: ext}, name) do
    case Enum.find_index(names, &(&1 == name)) do
      nil -> own_index(Map.get(ext, :own_models, []), name)
      index -> index
    end
  end

  @doc "The name of model `index`, `\"\"` when there is none."
  @spec name(Server.t(), integer()) :: String.t()
  def name(%Server{ext: ext}, index) when index < 0,
    do: ext |> Map.get(:own_models, []) |> Enum.at(-index - 1, "")

  def name(%Server{model_names: names}, index), do: Enum.at(names, index, "")

  @doc """
  Take the server's model list `names` (index 0 the empty name) as this client world's:
  each model is loaded at the server's index, and models this world asks for that the
  server lacks are numbered below zero from here on.
  """
  @spec share(Server.t(), [String.t()]) :: Server.t()
  def share(%Server{} = server, names) do
    models =
      names
      |> Enum.with_index()
      |> Enum.drop(1)
      |> Enum.reduce(server.models, fn {name, index}, acc ->
        if Enum.at(server.model_names, index) == name and Map.has_key?(acc, index),
          do: acc,
          else: Map.put(acc, index, info(server, name))
      end)

    %{
      server
      | model_names: names,
        models: models,
        ext: Map.put_new(server.ext, :own_models, [])
    }
  end

  @doc "The model of index `index`, or `nil`."
  @spec get(Server.t(), integer()) :: map() | nil
  def get(%Server{models: models}, index), do: Map.get(models, index)

  @doc "Register sound `name`, returning the server."
  @spec precache_sound(Server.t(), String.t()) :: Server.t()
  def precache_sound(%Server{} = server, name) do
    if name in server.sound_names,
      do: server,
      else: %{server | sound_names: server.sound_names ++ [name]}
  end

  defp file(server, name) do
    model = server.source.model(name)

    hulls =
      case model do
        %{kind: :brush, data: %{bsp: bsp}} -> bsp.hulls
        _ -> []
      end

    %{
      name: name,
      kind: model.kind,
      mins: model.mins,
      maxs: model.maxs,
      hulls: hulls,
      data: model.data
    }
  end

  defp own_index(own, name) do
    case Enum.find_index(own, &(&1 == name)) do
      nil -> nil
      place -> -(place + 1)
    end
  end

  defp hulls(bsp, model) do
    bsp.hulls
    |> Enum.zip(model.heads)
    |> Enum.map(fn {%Hull{} = hull, head} -> Hull.at(hull, head) end)
  end
end
