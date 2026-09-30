defmodule MobDeliver.Client do
  @moduledoc """
  HTTP side of wire format v1: `POST /manifest`.

  Uses `Req`. TLS trust is the host app's call: pass `cacerts` /
  `partial_chain` etc. through `:req_options` (on Android, or anywhere
  the BEAM has no system trust store, see `Mob.Certs`).
  """

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
          | {:http_status, pos_integer()}
          | {:transport, Exception.t()}
          | Manifest.error()

  @doc """
  Fetches and verifies the manifest for `:app` on `:channel` from
  `:endpoint`.

  Fails before any request when `:trusted_publish_key` is unset: there is
  no unverified mode. `:req_options` are merged over the defaults, which
  disable Req's automatic retries (scheduling and retry policy belong to
  the caller) and body decoding (the body is verified as raw JSON).
  """
  @spec fetch_manifest([option()]) :: {:ok, Manifest.t()} | {:error, error()}
  def fetch_manifest(opts) do
    case Keyword.get(opts, :trusted_publish_key) do
      nil -> {:error, :no_trusted_publish_key}
      key -> request_manifest(key, opts)
    end
  end

  @doc """
  Fetches the `.beam` for `sha` (`GET /beam/:sha256`). The bytes are
  unverified here; `MobDeliver.Store.put_blob/3` checks them against `sha`
  before anything can use them.
  """
  @spec fetch_beam(String.t(), [option()]) :: {:ok, binary()} | {:error, error()}
  def fetch_beam(sha, opts) do
    case request(opts, method: :get, url: url(opts, "/beam/" <> sha)) do
      {:ok, body} -> {:ok, body}
      {:error, _} = error -> error
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

    with {:ok, body} <- request(opts, request_opts) do
      Manifest.verify(body, trusted_key, app: app, channel: channel)
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
  end
end
