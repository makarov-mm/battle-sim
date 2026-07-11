defmodule Battlefield.WS do
  @moduledoc """
  Minimal hand-rolled WebSocket server (RFC 6455, server->client binary
  frames only) over :gen_tcp. No external dependencies. Each connection
  is a process registered in Battlefield.Clients; the sim pushes frames
  with `send(pid, {:frame, bin})`.
  """
  require Logger
  import Bitwise

  @magic "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    port = Keyword.get(opts, :port, 4040)
    pid = spawn_link(fn -> listen(port) end)
    {:ok, pid}
  end

  defp listen(port) do
    {:ok, ls} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        nodelay: true
      ])

    Logger.info("Battlefield WS listening on ws://0.0.0.0:#{port}/")
    accept(ls)
  end

  defp accept(ls) do
    {:ok, sock} = :gen_tcp.accept(ls)
    pid = spawn(fn -> await_socket(sock) end)
    :gen_tcp.controlling_process(sock, pid)
    send(pid, :go)
    accept(ls)
  end

  defp await_socket(sock) do
    receive do
      :go -> handshake(sock)
    after
      5000 -> :gen_tcp.close(sock)
    end
  end

  defp handshake(sock) do
    with {:ok, req} <- read_request(sock, ""),
         [_, key] <- Regex.run(~r/Sec-WebSocket-Key:\s*(.+?)\r\n/i, req) do
      accept_key = Base.encode64(:crypto.hash(:sha, String.trim(key) <> @magic))

      resp =
        "HTTP/1.1 101 Switching Protocols\r\n" <>
          "Upgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept_key}\r\n\r\n"

      :ok = :gen_tcp.send(sock, resp)
      Registry.register(Battlefield.Clients, :ws, nil)
      :inet.setopts(sock, active: true)
      Logger.info("WS client connected")
      loop(sock)
    else
      _ -> :gen_tcp.close(sock)
    end
  end

  defp read_request(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5000) do
      {:ok, data} ->
        acc = acc <> data
        if String.contains?(acc, "\r\n\r\n"), do: {:ok, acc}, else: read_request(sock, acc)

      err ->
        err
    end
  end

  defp loop(sock) do
    receive do
      {:frame, bin} ->
        case :gen_tcp.send(sock, frame(bin)) do
          :ok -> loop(sock)
          _ -> :gen_tcp.close(sock)
        end

      {:tcp, ^sock, data} ->
        handle_in(sock, data)
        loop(sock)

      {:tcp_closed, ^sock} ->
        Logger.info("WS client disconnected")

      {:tcp_error, ^sock, _} ->
        :ok
    end
  end

  # Only control frames matter for a broadcast-only server.
  defp handle_in(sock, <<b0, _rest::binary>>) do
    case b0 &&& 0x0F do
      0x8 -> :gen_tcp.close(sock)
      0x9 -> :gen_tcp.send(sock, <<0x8A, 0>>)
      _ -> :ok
    end
  end

  defp handle_in(_sock, _), do: :ok

  defp frame(payload) do
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<0x82, len>>
        len < 65_536 -> <<0x82, 126, len::16>>
        true -> <<0x82, 127, len::64>>
      end

    [header, payload]
  end
end
