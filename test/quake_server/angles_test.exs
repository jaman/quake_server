defmodule QuakeServer.AnglesTest do
  use ExUnit.Case, async: true

  alias QuakeServer.Angles

  test "vectoangles keeps fractions of a degree, so a turn of under a degree a frame adds up" do
    radians = -15.5 * :math.pi() / 180

    {_pitch, yaw, _roll} =
      Angles.vectoangles({:math.cos(radians), :math.sin(radians), 0.0}, nil, {-1.0, 1.0})

    assert_in_delta yaw, 344.5, 1.0e-9
  end
end
