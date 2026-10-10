defmodule BeamcodeWeb.ChannelCase do
  @moduledoc """
  The test case for the phone app's channels (`BeamcodeWeb.UserSocket`).
  Connect as the app does: `connect(BeamcodeWeb.UserSocket, token_params(user))`.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import BeamcodeWeb.ChannelCase
      import BeamcodeWeb.ConnCase, only: [user_fixture: 0, user_fixture: 1, user_fixture: 2]

      @endpoint BeamcodeWeb.Endpoint
    end
  end

  setup tags do
    Beamcode.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Connect params for `user`, as the app sends them after logging in."
  def token_params(user), do: %{"token" => BeamcodeWeb.AppToken.sign(user)}

  def project_fixture(attrs, owner) do
    {:ok, p} =
      Beamcode.Projects.insert_project(
        Map.merge(%{directory: "/srv/#{attrs.name}", scope: "team", kind: "code"}, attrs),
        owner
      )

    p
  end
end
