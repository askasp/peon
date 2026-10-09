defmodule Beamcode.Repo do
  use Ecto.Repo,
    otp_app: :beamcode,
    adapter: Ecto.Adapters.Postgres
end
