defmodule MobDeliver.Manifest do
  @moduledoc """
  Wire format v1 manifest: signature verification and parsing.

  `verify/3` takes the raw `POST /manifest` response body and returns a
  parsed `t:t/0` only if the Ed25519 signature checks out against the
  trusted publish key. The signature is checked before any field is
  interpreted; nothing from an unverified body reaches the caller.

  ## Signing payload

  The `signature` field signs every other top-level field, encoded as
  canonical JSON by `signing_payload/1`:

    * object keys sorted by UTF-8 byte order, at every depth;
    * no whitespace between tokens;
    * strings escape only `"`, `\\`, and U+0000–U+001F (non-ASCII is
      raw UTF-8, `/` is not escaped);
    * integers in plain decimal.

  Unknown top-level fields are part of the payload, so fields added by a
  later additive wire change stay covered by the signature. A publisher
  signs exactly `signing_payload(fields)` and sends
  `"signature": "ed25519:" <> Base.encode64(sig)`.
  """

  @enforce_keys [:app, :channel, :issued_at, :modules]
  defstruct [:app, :channel, :issued_at, :min_app_version, :force_update_after, :modules]

  @typedoc "Lowercase hex SHA-256 of a `.beam`, as used in `GET /beam/:sha256`."
  @type sha256 :: String.t()

  @type t :: %__MODULE__{
          app: String.t(),
          channel: String.t(),
          issued_at: DateTime.t(),
          min_app_version: String.t() | nil,
          force_update_after: DateTime.t() | nil,
          modules: %{String.t() => sha256()}
        }

  @type error ::
          :malformed_json
          | :malformed_key
          | :missing_signature
          | :malformed_signature
          | :invalid_signature
          | {:unsupported_manifest_version, term()}
          | {:app_mismatch, term()}
          | {:channel_mismatch, term()}
          | {:invalid_field, String.t()}

  @manifest_version 1

  @doc """
  Verifies and parses a manifest response body.

  `trusted_key` is the app's `"ed25519:<base64 of the raw 32-byte public
  key>"`. `expected` must carry `:app` and `:channel`: a validly signed
  manifest for a different app or channel (same publish key, different
  channel) is rejected rather than installed.
  """
  @spec verify(binary(), String.t(), app: String.t(), channel: String.t()) ::
          {:ok, t()} | {:error, error()}
  def verify(body, trusted_key, expected) when is_binary(body) do
    with {:ok, public_key} <- decode_key(trusted_key),
         {:ok, fields} <- decode_json(body),
         {:ok, signature} <- fetch_signature(fields),
         :ok <- check_signature(fields, signature, public_key) do
      parse(fields, Keyword.fetch!(expected, :app), Keyword.fetch!(expected, :channel))
    end
  end

  @doc """
  The exact bytes the manifest signature covers: `fields` minus
  `"signature"`, canonically encoded (see the moduledoc). `fields` uses
  string keys, as decoded from JSON.
  """
  @spec signing_payload(%{String.t() => term()}) :: binary()
  def signing_payload(fields) when is_map(fields) do
    fields |> Map.delete("signature") |> canonical() |> IO.iodata_to_binary()
  end

  defp canonical(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _} when is_binary(key) -> key end)
      |> Enum.map_intersperse(?,, fn {key, value} -> [JSON.encode!(key), ?:, canonical(value)] end)

    [?{, entries, ?}]
  end

  defp canonical(list) when is_list(list),
    do: [?[, Enum.map_intersperse(list, ?,, &canonical/1), ?]]

  defp canonical(scalar), do: JSON.encode!(scalar)

  defp decode_key("ed25519:" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      _ -> {:error, :malformed_key}
    end
  end

  defp decode_key(_), do: {:error, :malformed_key}

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, fields} when is_map(fields) -> {:ok, fields}
      _ -> {:error, :malformed_json}
    end
  end

  defp fetch_signature(%{"signature" => "ed25519:" <> encoded}) do
    case Base.decode64(encoded) do
      {:ok, <<_::binary-size(64)>> = signature} -> {:ok, signature}
      _ -> {:error, :malformed_signature}
    end
  end

  defp fetch_signature(%{"signature" => _}), do: {:error, :malformed_signature}
  defp fetch_signature(_), do: {:error, :missing_signature}

  defp check_signature(fields, signature, public_key) do
    payload = signing_payload(fields)

    if :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp parse(%{"manifest_version" => @manifest_version} = fields, app, channel) do
    with :ok <- match_field(fields, "app", app, :app_mismatch),
         :ok <- match_field(fields, "channel", channel, :channel_mismatch),
         {:ok, issued_at} <- datetime(fields, "issued_at", :required),
         {:ok, force_update_after} <- datetime(fields, "force_update_after", :optional),
         {:ok, min_app_version} <- optional_string(fields, "min_app_version"),
         {:ok, modules} <- modules(fields) do
      {:ok,
       %__MODULE__{
         app: app,
         channel: channel,
         issued_at: issued_at,
         min_app_version: min_app_version,
         force_update_after: force_update_after,
         modules: modules
       }}
    end
  end

  defp parse(fields, _app, _channel),
    do: {:error, {:unsupported_manifest_version, Map.get(fields, "manifest_version")}}

  defp match_field(fields, name, expected, error) do
    case Map.get(fields, name) do
      ^expected -> :ok
      other -> {:error, {error, other}}
    end
  end

  defp datetime(fields, name, presence) do
    case {Map.get(fields, name), presence} do
      {nil, :optional} -> {:ok, nil}
      {value, _} when is_binary(value) -> parse_datetime(value, name)
      _ -> {:error, {:invalid_field, name}}
    end
  end

  defp parse_datetime(value, name) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} -> {:error, {:invalid_field, name}}
    end
  end

  defp optional_string(fields, name) do
    case Map.get(fields, name) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, name}}
    end
  end

  defp modules(%{"modules" => modules}) when is_map(modules) do
    Enum.reduce_while(modules, {:ok, %{}}, fn
      {name, "sha256:" <> hex}, {:ok, acc} when name != "" and byte_size(hex) == 64 ->
        # Base.decode16, not a ~r literal: compile-time regexes break on
        # OTP 28.0 devices (mob AGENTS.md rule 10).
        case Base.decode16(hex, case: :lower) do
          {:ok, _} -> {:cont, {:ok, Map.put(acc, name, hex)}}
          :error -> {:halt, {:error, {:invalid_field, "modules"}}}
        end

      _, _ ->
        {:halt, {:error, {:invalid_field, "modules"}}}
    end)
  end

  defp modules(_), do: {:error, {:invalid_field, "modules"}}
end
