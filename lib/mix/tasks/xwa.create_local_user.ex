defmodule Mix.Tasks.Xwa.CreateLocalUser do
  use Mix.Task

  @shortdoc "Create a local (username/password) user"

  @moduledoc """
  Creates a local user account with a username and bcrypt-hashed password.

      mix xwa.create_local_user USERNAME PASSWORD

  Example:

      mix xwa.create_local_user govinfo password

  The user is created with `provider: "local"` and a bootstrapped graph.
  If the username already exists, the task exits with an error.
  """

  def run([username, password]) do
    Mix.Task.run("app.start")

    case Xwa.Accounts.create_local_user(username, password) do
      {:ok, user} ->
        Mix.shell().info("Created local user #{user.username} (id: #{user.id})")

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        Mix.shell().error("Failed to create user: #{inspect(errors)}")
        exit({:shutdown, 1})
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix xwa.create_local_user USERNAME PASSWORD")
    exit({:shutdown, 1})
  end
end
