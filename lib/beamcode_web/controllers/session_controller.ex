defmodule BeamcodeWeb.SessionController do
  use BeamcodeWeb, :controller
  alias Beamcode.Accounts
  alias BeamcodeWeb.UserAuth

  plug :put_page_title

  defp put_page_title(conn, _opts), do: assign(conn, :page_title, "Sign in")

  def new(conn, _params) do
    first_run? = not Accounts.any_users?()
    render(conn, :new, form: Phoenix.Component.to_form(%{}, as: :user), first_run?: first_run?)
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password} = params}) do
    if Accounts.any_users?() do
      case Accounts.authenticate(username, password) do
        {:ok, user} ->
          UserAuth.log_in(conn, user)

        :error ->
          conn
          |> put_flash(:error, "Wrong username or password.")
          |> render(:new,
            form: Phoenix.Component.to_form(%{"username" => username}, as: :user),
            first_run?: false
          )
      end
    else
      case Accounts.create_user(params, admin: true) do
        {:ok, user} ->
          UserAuth.log_in(conn, user)

        {:error, changeset} ->
          render(conn, :new,
            form: Phoenix.Component.to_form(changeset, as: :user),
            first_run?: true
          )
      end
    end
  end

  def delete(conn, _params), do: UserAuth.log_out(conn)
end
