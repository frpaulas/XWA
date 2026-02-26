defmodule Xwa.BoltIPv6Socket do
  @moduledoc "bolt_sips socket wrapper that enables IPv6 (for Fly.io .internal addresses)."

  def connect(host, port, opts, timeout) do
    :gen_tcp.connect(host, port, [:inet6 | opts], timeout)
  end

  defdelegate setopts(sock, opts), to: :inet
  defdelegate send(sock, package), to: :gen_tcp
  defdelegate recv(sock, length, timeout), to: :gen_tcp
  defdelegate recv(sock, length), to: :gen_tcp
  defdelegate close(sock), to: :inet
end
