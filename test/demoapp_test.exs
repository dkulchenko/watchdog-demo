defmodule DemoappTest do
  use ExUnit.Case
  doctest Demoapp

  test "greets the world" do
    assert Demoapp.hello() == :world
  end
end
