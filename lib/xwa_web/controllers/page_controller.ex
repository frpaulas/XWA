defmodule XwaWeb.PageController do
  use XwaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
