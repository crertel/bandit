defmodule WebsocketAutobahnTest do
  use ExUnit.Case, async: true

  # credo:disable-for-this-file Credo.Check.Design.AliasUsage

  @moduletag :external_conformance
  @moduletag timeout: 3_600_000

  defmodule EchoWebSock do
    use NoopWebSock
    def handle_in({data, opcode: opcode}, state), do: {:push, {opcode, data}, state}
  end

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Bandit.WebSocket.Handshake.valid_upgrade?(conn) do
      true -> Plug.Conn.upgrade_adapter(conn, :websocket, {EchoWebSock, :ok, compress: true})
      false -> Plug.Conn.send_resp(conn, 204, <<>>)
    end
  end

  @tag capture_log: true
  test "autobahn test suite" do
    # We can't use ServerHelpers since we need to bind on all interfaces
    {:ok, server_pid} =
      [plug: __MODULE__, options: [port: 0]]
      |> Bandit.child_spec()
      |> start_supervised()

    {:ok, %{port: port}} = ThousandIsland.listener_info(server_pid)

    output =
      System.cmd(
        "docker",
        [
          "run",
          "--rm",
          "-v",
          "#{Path.join(__DIR__, "../../support/autobahn_config.json")}:/fuzzingclient.json",
          "-v",
          "#{Path.join(__DIR__, "../../../autobahn_reports")}:/reports"
        ] ++
          extra_args() ++
          [
            "--name",
            "fuzzingclient",
            "crossbario/autobahn-testsuite",
            "wstest",
            "--mode",
            "fuzzingclient",
            "-w",
            "ws://host.docker.internal:#{port}"
          ],
        stderr_to_stdout: true
      )

    assert {_, 0} = output

    failures =
      Path.join(__DIR__, "../../../autobahn_reports/servers/index.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("UnknownServer")
      |> Enum.map(fn {test_case, %{"behavior" => res, "behaviorClose" => res_close}} ->
        {test_case, res, res_close}
      end)
      |> Enum.reject(fn {_, res, res_close} ->
        (res == "OK" or res == "NON-STRICT" or res == "INFORMATIONAL") and
          (res_close == "OK" or res_close == "INFORMATIONAL")
      end)
      |> Enum.sort_by(fn {code, _, _} -> code end)

    assert [] = failures
  end

  defp extra_args do
    case :os.type() do
      {:unix, :linux} -> ["--add-host=host.docker.internal:host-gateway"]
      _ -> []
    end
  end
end
