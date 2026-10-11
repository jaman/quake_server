defmodule QuakeServer.TextNumbersTest do
  use ExUnit.Case, async: true

  alias QuakeServer.TextNumbers

  test "a number with no digit before its point reads as C's strtod reads it" do
    assert TextNumbers.strtod(".3") == {0.3, ""}
    assert TextNumbers.strtod(" -.5e1x") == {-5.0, "x"}
    assert TextNumbers.atof(".3") == 0.30000001192092896
  end
end
