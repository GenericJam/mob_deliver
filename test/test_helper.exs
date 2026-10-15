defmodule MobDeliver.TestPublisher do
  @moduledoc false
  # Plays the publisher side of wire format v1: builds manifest fields and
  # signs them exactly as a server must.

  alias MobDeliver.Manifest

  @sha String.duplicate("ab", 32)

  def sha, do: @sha

  def keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {"ed25519:" <> Base.encode64(public), private}
  end

  def fields(overrides \\ %{}) do
    Map.merge(
      %{
        "manifest_version" => 1,
        "app" => "com.example.app",
        "channel" => "production",
        "issued_at" => "2026-09-19T22:00:00Z",
        "min_app_version" => "1.4.0",
        "force_update_after" => "2026-10-19T00:00:00Z",
        "modules" => %{"MyApp.HomeScreen" => "sha256:" <> @sha}
      },
      overrides
    )
  end

  # A publish newer than every earlier one in this VM (seconds after the
  # default issued_at): a device refuses a manifest that isn't newer than
  # the newest it has verified (MobDeliver.Floor).
  def next_issued_at do
    ~U[2026-09-19 22:00:00Z]
    |> DateTime.add(System.unique_integer([:monotonic, :positive]))
    |> DateTime.to_iso8601()
  end

  def sign(fields, private) do
    signature = :crypto.sign(:eddsa, :none, Manifest.signing_payload(fields), [private, :ed25519])
    Map.put(fields, "signature", "ed25519:" <> Base.encode64(signature))
  end
end

ExUnit.start()
