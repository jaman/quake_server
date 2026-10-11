defmodule QuakeServer.World.Trace do
  @moduledoc """
  What a move through the world ran into, with every field FTE's `trace_t` gives a
  program.

    * `fraction` — how much of the move was made, 1.0 when nothing was hit
    * `end_pos` — where it stopped
    * `normal`, `distance` — the plane hit
    * `all_solid`, `start_solid` — the whole move, or its start, was inside something
    * `in_open`, `in_water` — whether it passed through empty or liquid space
    * `hit` — the entity hit, `nil` when none
    * `contents` — the contents bits (`QuakeServer.Contents`) of what was hit
    * `surface_id` — a studio model hitbox's group, 0 otherwise
    * `bone_id`, `brush_id`, `brush_face`, `triangle_id` — numbered from 1, 0 when unknown

  `to_hull/1` gives the same move as a `Cauldron3D.Hull.Trace`.
  """

  alias Cauldron3D.Hull

  @type t :: %__MODULE__{
          fraction: float(),
          end_pos: Cauldron3D.Vec.t(),
          normal: Cauldron3D.Vec.t(),
          distance: float(),
          all_solid: boolean(),
          start_solid: boolean(),
          in_open: boolean(),
          in_water: boolean(),
          hit: non_neg_integer() | nil,
          contents: non_neg_integer(),
          surface_id: integer(),
          bone_id: integer(),
          brush_id: integer(),
          brush_face: integer(),
          triangle_id: integer()
        }

  defstruct fraction: 1.0,
            end_pos: {0.0, 0.0, 0.0},
            normal: {0.0, 0.0, 0.0},
            distance: 0.0,
            all_solid: false,
            start_solid: false,
            in_open: false,
            in_water: false,
            hit: nil,
            contents: 0,
            surface_id: 0,
            bone_id: 0,
            brush_id: 0,
            brush_face: 0,
            triangle_id: 0

  @doc "The move as a `Cauldron3D.Hull.Trace`, keeping the fields that struct has."
  @spec to_hull(t()) :: Hull.Trace.t()
  def to_hull(%__MODULE__{} = trace) do
    %Hull.Trace{
      fraction: trace.fraction,
      end_pos: trace.end_pos,
      normal: trace.normal,
      distance: trace.distance,
      all_solid: trace.all_solid,
      start_solid: trace.start_solid,
      in_open: trace.in_open,
      in_water: trace.in_water,
      hit: trace.hit
    }
  end

  @doc "A `Cauldron3D.Hull.Trace` as this struct, the fields it lacks zero."
  @spec from_hull(Hull.Trace.t()) :: t()
  def from_hull(%Hull.Trace{} = trace) do
    %__MODULE__{
      fraction: trace.fraction,
      end_pos: trace.end_pos,
      normal: trace.normal,
      distance: trace.distance,
      all_solid: trace.all_solid,
      start_solid: trace.start_solid,
      in_open: trace.in_open,
      in_water: trace.in_water,
      hit: trace.hit
    }
  end
end
