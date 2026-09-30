defmodule MobDeliver.Client do
  @moduledoc """
  HTTP side of wire format v1: `POST /manifest`.

  Uses `Req`. TLS trust is the host app's call: pass `cacerts` /
  `partial_chain` etc. through `:req_options`. On Android the BEAM has no
  system trust store, so without them every HTTPS request fails with
  `{:transport, _}` (see the README's "HTTPS on Android").
  """

  require Logger

  alias MobDeliver.Manifest

  @accept "application/vnd.mob-deliver.v1+json"

  @type option ::
          {:endpoint, String.t()}
          | {:app, String.t()}
          | {:channel, String.t() | atom()}
          | {:trusted_publish_key, String.t() | nil}
          | {:req_options, keyword()}

  @type error ::
          :no_trusted_publish_key
          | :not_configured
          | {:http_status, pos_integer()}
          | {:transport, Exception.t() | {:exit, term()}}
          | Manifest.error()

  @doc """
  Fetches and verifies the manifest for `:app` on `:channel` from
  `:endpoint`. Returns the parsed manifest and the signed body it came
  from (what `MobDeliver.Store` persists and re-verifies).

  Fails before any request when `:trusted_publish_key` is unset: there is
  no unverified mode. `{:error, :not_configured}` (logged, naming the
  missing keys) when `:endpoint`, `:app` or `:channel` is `nil`.
  `:req_options` are merged over the defaults, which disable Req's
  automatic retries (scheduling and retry policy belong to the caller)
  and body decoding (the body is verified as raw JSON).
  """
  @spec fetch_manifest([option()]) :: {:ok, Manifest.t(), binary()} | {:error, error()}
  def fetch_manifest(opts) do
    with :ok <- configured(opts, [:endpoint, :app, :channel]) do
      case Keyword.get(opts, :trusted_publish_key) do
        nil -> {:error, :no_trusted_publish_key}
        key -> request_manifest(key, opts)
      end
    end
  end

  @doc """
  Fetches the `.beam` for `sha` (`GET /beam/:sha256`). The bytes are
  unverified here; `MobDeliver.Store.put_blob/3` checks them against `sha`
  before anything can use them.
  """
  @spec fetch_beam(String.t(), [option()]) :: {:ok, binary()} | {:error, error()}
  def fetch_beam(sha, opts) do
    with :ok <- configured(opts, [:endpoint]) do
      request(opts, method: :get, url: url(opts, "/beam/" <> sha))
    end
  end

  defp configured(opts, keys) do
    case Enum.filter(keys, &(Keyword.get(opts, &1) == nil)) do
      [] ->
        :ok

      missing ->
        Logger.warning(
          "mob_deliver: not configured (#{Enum.map_join(missing, ", ", &inspect/1)} unset in " <>
            "config :mob_deliver, or the config didn't reach the device: that needs mob >= 0.9.6 " <>
            "and a native build with the matching mob_dev); no update check"
        )

        {:error, :not_configured}
    end
  end

  defp request_manifest(trusted_key, opts) do
    app = Keyword.fetch!(opts, :app)
    channel = opts |> Keyword.fetch!(:channel) |> to_string()

    request_opts = [
      method: :post,
      url: url(opts, "/manifest"),
      headers: [accept: @accept, content_type: "application/json"],
      body: JSON.encode!(%{"app" => app, "channel" => channel})
    ]

    with {:ok, body} <- request(opts, request_opts),
         {:ok, manifest} <- Manifest.verify(body, trusted_key, app: app, channel: channel) do
      {:ok, manifest, body}
    end
  end

  defp url(opts, path), do: String.trim_trailing(Keyword.fetch!(opts, :endpoint), "/") <> path

  defp request(opts, request_opts) do
    req =
      [decode_body: false, retry: false]
      |> Keyword.merge(request_opts)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, {:transport, exception}}
    end
  rescue
    # Some failures raise instead of returning an error, e.g. Mint's
    # "default CA trust store not available" when no CA certs are configured.
    exception -> {:error, {:transport, exception}}
  catch
    :exit, reason -> {:error, {:transport, {:exit, reason}}}
  end
end
