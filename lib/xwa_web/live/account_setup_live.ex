defmodule XwaWeb.AccountSetupLive do
  @moduledoc """
  One-time username setup page for OAuth users who have not yet chosen a username.

  After submitting a valid username the user is redirected to the main app.
  Already-set usernames cannot be changed here (use profile settings).
  """

  use XwaWeb, :live_view

  alias Xwa.Accounts

  @impl true
  def mount(_params, session, socket) do
    user_id = session["user_id"]
    user = user_id && Accounts.get_user(user_id)

    cond do
      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, "You must be signed in.")
         |> redirect(to: ~p"/")}

      not is_nil(user.username) ->
        # Already has a username — nothing to do
        {:ok, redirect(socket, to: ~p"/")}

      true ->
        {:ok,
         socket
         |> assign(:user, user)
         |> assign(:username, "")
         |> assign(:error, nil)}
    end
  end

  @impl true
  def handle_event("submit", %{"username" => username}, socket) do
    case Accounts.set_username(socket.assigns.user, username) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Username set. Welcome!")
         |> redirect(to: ~p"/")}

      {:error, changeset} ->
        error =
          changeset.errors
          |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

        {:noreply, assign(socket, error: error, username: username)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200 px-4">
      <div class="w-full max-w-sm bg-base-100 rounded-2xl shadow-lg p-8">
        <h1 class="text-2xl font-bold text-base-content mb-1">Choose a username</h1>
        <p class="text-sm text-base-content/60 mb-6">
          Your username will be part of your public graph URLs, e.g.
          <span class="font-mono text-xs text-base-content/80">/graphs/you/my-graph</span>.
          It cannot contain spaces.
        </p>

        <%= if @error do %>
          <div class="mb-4 rounded-lg bg-error/10 border border-error/30 px-4 py-3 text-sm text-error">
            {@error}
          </div>
        <% end %>

        <form phx-submit="submit" class="flex flex-col gap-4">
          <div>
            <label class="block text-sm font-medium text-base-content mb-1" for="username">
              Username
            </label>
            <input
              id="username"
              name="username"
              type="text"
              value={@username}
              placeholder="e.g. janedoe"
              autofocus
              class="input input-bordered w-full"
              minlength="2"
              maxlength="40"
              pattern="[a-zA-Z0-9_\-]+"
              required
            />
            <p class="mt-1 text-xs text-base-content/40">Letters, numbers, hyphens, underscores. 2–40 chars.</p>
          </div>

          <button type="submit" class="btn btn-primary w-full">
            Continue
          </button>
        </form>
      </div>
    </div>
    """
  end
end
