defmodule MobDeliver.ManifestTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Manifest, TestPublisher}

  setup do
    {key, private} = TestPublisher.keypair()
    %{key: key, private: private}
  end

  defp verify(body, key) when is_binary(body),
    do: Manifest.verify(body, key, app: "com.example.app", channel: "production")

  defp verify(fields, key), do: verify(JSON.encode!(fields), key)

  test "a correctly signed manifest parses into typed fields", %{key: key, private: private} do
    sha = TestPublisher.sha()

    assert {:ok,
            %Manifest{
              app: "com.example.app",
              channel: "production",
              issued_at: ~U[2026-09-19 22:00:00Z],
              min_app_version: "1.4.0",
              force_update_after: ~U[2026-10-19 00:00:00Z],
              modules: %{"MyApp.HomeScreen" => ^sha}
            }} = TestPublisher.fields() |> TestPublisher.sign(private) |> verify(key)
  end

  test "verification does not depend on key order on the wire", %{key: key, private: private} do
    signed = TestPublisher.fields() |> TestPublisher.sign(private)

    reversed =
      signed
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.map_join(",", fn {k, v} -> JSON.encode!(k) <> " : " <> JSON.encode!(v) end)

    assert {:ok, %Manifest{}} = verify("{\n" <> reversed <> "\n}", key)
  end

  test "the signing payload is canonical JSON: sorted keys at every depth, minimal escaping" do
    fields = %{
      "signature" => "ignored",
      "z" => [%{"b" => 1, "a" => "é/\"\\\n"}],
      "a" => %{"y" => true, "x" => nil}
    }

    assert Manifest.signing_payload(fields) ==
             ~S({"a":{"x":null,"y":true},"z":[{"a":"é/\"\\\n","b":1}]})
  end

  test "manifests with more than 32 modules verify and sign in sorted order",
       %{key: key, private: private} do
    names = for i <- 1..40, do: "MyApp.Screen" <> String.pad_leading("#{i}", 2, "0")
    modules = Map.new(names, &{&1, "sha256:" <> TestPublisher.sha()})

    expected_modules =
      Enum.map_join(
        names,
        ",",
        &(JSON.encode!(&1) <> ":" <> JSON.encode!("sha256:" <> TestPublisher.sha()))
      )

    assert Manifest.signing_payload(%{"modules" => modules}) ==
             ~s({"modules":{#{expected_modules}}})

    signed = TestPublisher.fields(%{"modules" => modules}) |> TestPublisher.sign(private)
    assert {:ok, %Manifest{modules: parsed}} = verify(signed, key)
    assert map_size(parsed) == 40
  end

  test "changing, adding, or removing any signed field invalidates the signature",
       %{key: key, private: private} do
    signed = TestPublisher.fields() |> TestPublisher.sign(private)

    tampered = [
      put_in(signed, ["modules", "MyApp.HomeScreen"], "sha256:" <> String.duplicate("cd", 32)),
      put_in(signed, ["modules", "MyApp.Evil"], "sha256:" <> TestPublisher.sha()),
      Map.put(signed, "min_app_version", "1.0.0"),
      Map.put(signed, "cohort", "beta"),
      Map.delete(signed, "force_update_after")
    ]

    for manifest <- tampered do
      assert verify(manifest, key) == {:error, :invalid_signature}
    end
  end

  test "a manifest signed by another key is rejected", %{key: key} do
    {_other_key, other_private} = TestPublisher.keypair()
    signed = TestPublisher.fields() |> TestPublisher.sign(other_private)

    assert verify(signed, key) == {:error, :invalid_signature}
  end

  test "missing or malformed signatures are rejected", %{key: key} do
    unsigned = TestPublisher.fields()

    assert verify(unsigned, key) == {:error, :missing_signature}

    assert verify(Map.put(unsigned, "signature", "ed25519:not-base64!"), key) ==
             {:error, :malformed_signature}

    assert verify(Map.put(unsigned, "signature", "rsa:" <> Base.encode64(<<0::512>>)), key) ==
             {:error, :malformed_signature}

    assert verify(Map.put(unsigned, "signature", "ed25519:" <> Base.encode64(<<0::256>>)), key) ==
             {:error, :malformed_signature}
  end

  test "a validly signed manifest for another app or channel is rejected",
       %{key: key, private: private} do
    other_app = TestPublisher.fields(%{"app" => "com.other.app"}) |> TestPublisher.sign(private)
    other_channel = TestPublisher.fields(%{"channel" => "staging"}) |> TestPublisher.sign(private)

    assert verify(other_app, key) == {:error, {:app_mismatch, "com.other.app"}}
    assert verify(other_channel, key) == {:error, {:channel_mismatch, "staging"}}
  end

  test "unknown fields are accepted when they are signed", %{key: key, private: private} do
    signed = TestPublisher.fields(%{"cohort" => %{"percent" => 5}}) |> TestPublisher.sign(private)

    assert {:ok, %Manifest{}} = verify(signed, key)
  end

  test "the update-window fields are optional", %{key: key, private: private} do
    signed =
      TestPublisher.fields()
      |> Map.drop(["min_app_version", "force_update_after"])
      |> TestPublisher.sign(private)

    assert {:ok, %Manifest{min_app_version: nil, force_update_after: nil}} = verify(signed, key)
  end

  test "signed manifests with invalid fields are rejected", %{key: key, private: private} do
    cases = [
      {%{"manifest_version" => 2}, {:unsupported_manifest_version, 2}},
      {%{"issued_at" => "yesterday"}, {:invalid_field, "issued_at"}},
      {%{"force_update_after" => 1_700_000_000}, {:invalid_field, "force_update_after"}},
      {%{"min_app_version" => ""}, {:invalid_field, "min_app_version"}},
      {%{"modules" => %{"MyApp.A" => "sha256:" <> String.upcase(TestPublisher.sha())}},
       {:invalid_field, "modules"}},
      {%{"modules" => %{"MyApp.A" => "md5:abc"}}, {:invalid_field, "modules"}},
      {%{"modules" => ["MyApp.A"]}, {:invalid_field, "modules"}}
    ]

    for {overrides, error} <- cases do
      signed = TestPublisher.fields(overrides) |> TestPublisher.sign(private)
      assert verify(signed, key) == {:error, error}
    end
  end

  test "a malformed trusted key or body is rejected", %{key: key, private: private} do
    signed = TestPublisher.fields() |> TestPublisher.sign(private)

    assert verify(signed, "ed25519:" <> Base.encode64(<<1, 2, 3>>)) == {:error, :malformed_key}
    assert verify(signed, "ed25519-" <> key) == {:error, :malformed_key}
    assert verify("not json", key) == {:error, :malformed_json}
    assert verify("[1, 2]", key) == {:error, :malformed_json}
  end
end
