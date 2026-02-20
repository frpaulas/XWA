defmodule Xwa.Repo do
  use Ecto.Repo,
    otp_app: :xwa,
    adapter: Ecto.Adapters.Postgres
end
