defmodule MobDeliver.ClientTest do
  use ExUnit.Case, async: true

  alias MobDeliver.{Client, Manifest, TestPublisher}

  setup do
    {key, private} = TestPublisher.keypair()

    opts = [
      endpoint: "https://updates.example.test/deliver/",
      app: "com.example.app",
      channel: :production,
      trusted_publish_key: key,
      req_options: [plug: {Req.Test, Client}]
    ]

    %{opts: opts, private: private}
  end

  test "posts app and channel as v1 and returns the verified manifest",
       %{opts: opts, private: private} do
    body = TestPublisher.fields() |> TestPublisher.sign(private) |> JSON.encode!()

    Req.Test.stub(Client, fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)

      send(
        self(),
        {:request, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "accept"),
         request_body}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/vnd.mob-deliver.v1+json")
      |> Plug.Conn.send_resp(200, body)
    end)

    assert {:ok, %Manifest{app: "com.example.app", channel: "production"}} =
             Client.fetch_manifest(opts)

    assert_received {:request, "POST", "/deliver/manifest",
                     ["application/vnd.mob-deliver.v1+json"], request_body}

    assert JSON.decode!(request_body) == %{"app" => "com.example.app", "channel" => "production"}
  end

  test "a forged manifest from the server is rejected", %{opts: opts} do
    {_other_key, other_private} = TestPublisher.keypair()
    body = TestPublisher.fields() |> TestPublisher.sign(other_private) |> JSON.encode!()

    Req.Test.stub(Client, &Plug.Conn.send_resp(&1, 200, body))

    assert Client.fetch_manifest(opts) == {:error, :invalid_signature}
  end

  test "non-200 responses are errors, without retrying", %{opts: opts} do
    Req.Test.stub(Client, fn conn ->
      send(self(), :requested)
      Plug.Conn.send_resp(conn, 503, "down")
    end)

    assert Client.fetch_manifest(opts) == {:error, {:http_status, 503}}
    assert_received :requested
    refute_received :requested
  end

  test "transport failures are errors", %{opts: opts} do
    Req.Test.stub(Client, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, {:transport, %Req.TransportError{reason: :econnrefused}}} =
             Client.fetch_manifest(opts)
  end

  test "without a trusted key nothing is fetched", %{opts: opts} do
    Req.Test.stub(Client, fn conn ->
      send(self(), :requested)
      Plug.Conn.send_resp(conn, 500, "")
    end)

    assert Client.fetch_manifest(Keyword.put(opts, :trusted_publish_key, nil)) ==
             {:error, :no_trusted_publish_key}

    refute_received :requested
  end
end
