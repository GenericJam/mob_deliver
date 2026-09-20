defmodule MobDeliverTest do
  use ExUnit.Case
  doctest MobDeliver

  # Scaffold-only placeholder. Real coverage lands with the child issues:
  # signature verification round-trip, content-addressed store atomicity,
  # watchdog state machine, JIT resolve single-flight, forced-update gate.

  test "moduledoc is present" do
    assert {:docs_v1, _, :elixir, "text/markdown", %{"en" => moduledoc}, _, _} =
             Code.fetch_docs(MobDeliver)

    assert moduledoc =~ "Content-addressed BEAM delivery"
  end
end
