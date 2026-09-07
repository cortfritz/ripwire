defmodule Repo.GreeterTest do
  use ExUnit.Case

  alias Repo.Greeter

  # `test "…" do` is a MACRO CALL, not a def — the disclosed metaprogramming floor.
  test "it greets" do
    assert Greeter.greet("ada") == "ADA"
  end

  def helper do
    Greeter.default()
  end
end
