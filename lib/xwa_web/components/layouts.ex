defmodule XwaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use XwaWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current scope, containing the authenticated user if any"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div id="app-shell" class="min-h-screen flex flex-col bg-base-100">
      <header class="sticky top-0 z-50 w-full border-b border-base-200 bg-base-100/80 backdrop-blur-md">
        <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
          <div class="flex h-16 items-center justify-between gap-4">
            <%!-- Logo / wordmark --%>
            <a href="/" class="flex items-center gap-3 group shrink-0">
              <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-primary text-primary-content font-bold text-sm shadow-sm group-hover:shadow-md transition-shadow">
                X
              </div>
              <div class="flex flex-col leading-none">
                <span class="text-base font-bold tracking-tight text-base-content">XWA</span>
                <span class="text-[0.6rem] font-medium text-base-content/50 tracking-widest uppercase">
                  Knowledge Graph
                </span>
              </div>
            </a>

            <%!-- Desktop nav links --%>
            <nav class="hidden sm:flex items-center gap-1 flex-1">
              <.link
                navigate={~p"/sources"}
                class="flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-200 transition-colors"
              >
                <.icon name="hero-circle-stack" class="w-4 h-4" /> Sources
              </.link>
              <.link
                navigate={~p"/graph"}
                class="flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-200 transition-colors"
              >
                <.icon name="hero-share" class="w-4 h-4" /> Reset graph
              </.link>
            </nav>

            <%!-- Right side controls --%>
            <div class="flex items-center gap-2">
              <.theme_toggle />

              <%= if @current_scope do %>
                <%!-- Authenticated user menu --%>
                <div class="hidden sm:flex items-center gap-3">
                  <div class="flex flex-col items-end leading-none">
                    <span class="text-sm font-medium text-base-content">
                      {@current_scope.user.name || @current_scope.user.email}
                    </span>
                    <span class="text-xs text-base-content/50 mt-0.5">
                      {@current_scope.user.email}
                    </span>
                  </div>

                  <div class="relative group">
                    <%= if @current_scope.user.avatar_url do %>
                      <img
                        src={@current_scope.user.avatar_url}
                        alt={@current_scope.user.name || "User avatar"}
                        class="h-8 w-8 rounded-full ring-2 ring-base-300 group-hover:ring-primary transition-all cursor-pointer"
                      />
                    <% else %>
                      <div class="h-8 w-8 rounded-full bg-primary/10 ring-2 ring-base-300 group-hover:ring-primary transition-all flex items-center justify-center cursor-pointer">
                        <span class="text-sm font-semibold text-primary">
                          {String.first(@current_scope.user.name || @current_scope.user.email)
                          |> String.upcase()}
                        </span>
                      </div>
                    <% end %>

                    <%!-- Dropdown menu --%>
                    <div class="absolute right-0 top-full mt-2 w-48 rounded-xl border border-base-200 bg-base-100 shadow-lg opacity-0 invisible group-hover:opacity-100 group-hover:visible transition-all duration-150 origin-top-right">
                      <div class="p-1">
                        <div class="px-3 py-2 border-b border-base-200 mb-1">
                          <p class="text-xs text-base-content/50 uppercase tracking-wide font-medium">
                            Signed in via
                          </p>
                          <p class="text-sm font-medium text-base-content capitalize mt-0.5">
                            {@current_scope.user.provider}
                          </p>
                        </div>
                        <.link
                          href={~p"/auth/logout"}
                          method="delete"
                          class="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-base-content/70 hover:bg-base-200 hover:text-base-content transition-colors"
                        >
                          <.icon name="hero-arrow-right-start-on-rectangle" class="w-4 h-4" />
                          Sign out
                        </.link>
                      </div>
                    </div>
                  </div>
                </div>
              <% else %>
                <%!-- Sign in dropdown --%>
                <div class="hidden sm:block relative group">
                  <button class="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content shadow-sm hover:brightness-110 active:scale-95 transition-all">
                    <.icon name="hero-user" class="w-4 h-4" /> Sign in
                    <.icon name="hero-chevron-down" class="w-3 h-3 opacity-70" />
                  </button>
                  <div class="absolute right-0 top-full mt-2 w-52 rounded-xl border border-base-200 bg-base-100 shadow-lg opacity-0 invisible group-hover:opacity-100 group-hover:visible transition-all duration-150 origin-top-right">
                    <div class="p-1.5 flex flex-col gap-0.5">
                      <a
                        href={~p"/auth/google"}
                        class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-base-content hover:bg-base-200 transition-colors"
                      >
                        <svg class="h-4 w-4 shrink-0" viewBox="0 0 24 24" aria-hidden="true">
                          <path
                            d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
                            fill="#4285F4"
                          />
                          <path
                            d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                            fill="#34A853"
                          />
                          <path
                            d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
                            fill="#FBBC05"
                          />
                          <path
                            d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
                            fill="#EA4335"
                          />
                        </svg>
                        Continue with Google
                      </a>
                      <a
                        href={~p"/auth/github"}
                        class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-base-content hover:bg-base-200 transition-colors"
                      >
                        <svg
                          class="h-4 w-4 shrink-0"
                          viewBox="0 0 24 24"
                          aria-hidden="true"
                          fill="currentColor"
                        >
                          <path
                            fill-rule="evenodd"
                            clip-rule="evenodd"
                            d="M12 0C5.37 0 0 5.506 0 12.303c0 5.445 3.435 10.043 8.205 11.674.6.107.825-.262.825-.585 0-.292-.015-1.261-.015-2.291C6 21.67 5.22 20.346 4.98 19.654c-.135-.354-.72-1.446-1.23-1.738-.42-.23-1.02-.8-.015-.815.945-.015 1.62.892 1.845 1.261 1.08 1.86 2.805 1.338 3.495 1.015.105-.8.42-1.338.765-1.645-2.67-.308-5.46-1.37-5.46-6.075 0-1.338.465-2.446 1.23-3.307-.12-.308-.54-1.569.12-3.26 0 0 1.005-.323 3.3 1.26.96-.276 1.98-.415 3-.415s2.04.139 3 .416c2.295-1.6 3.3-1.261 3.3-1.261.66 1.691.24 2.952.12 3.26.765.861 1.23 1.953 1.23 3.307 0 4.721-2.805 5.767-5.475 6.075.435.384.81 1.122.81 2.276 0 1.645-.015 2.968-.015 3.383 0 .323.225.707.825.585a12.047 12.047 0 0 0 5.919-4.489A12.536 12.536 0 0 0 24 12.304C24 5.505 18.63 0 12 0Z"
                          />
                        </svg>
                        Continue with GitHub
                      </a>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Hamburger (mobile only) --%>
              <button
                id="mobile-menu-btn"
                class="sm:hidden flex items-center justify-center w-9 h-9 rounded-lg text-base-content/60 hover:text-base-content hover:bg-base-200 transition-colors"
                aria-label="Toggle menu"
                aria-expanded="false"
                aria-controls="mobile-menu"
              >
                <.icon name="hero-bars-3" class="w-5 h-5" />
              </button>
            </div>
          </div>
        </div>

        <%!-- Mobile menu panel --%>
        <div
          id="mobile-menu"
          class="sm:hidden hidden border-t border-base-200 bg-base-100"
          aria-hidden="true"
        >
          <div class="mx-auto max-w-7xl px-4 py-3 flex flex-col gap-1">
            <.link
              navigate={~p"/sources"}
              class="flex items-center gap-2 rounded-lg px-3 py-2.5 text-sm font-medium text-base-content/70 hover:text-base-content hover:bg-base-200 transition-colors"
            >
              <.icon name="hero-circle-stack" class="w-4 h-4" /> Sources
            </.link>
            <.link
              navigate={~p"/graph"}
              class="flex items-center gap-2 rounded-lg px-3 py-2.5 text-sm font-medium text-base-content/70 hover:text-base-content hover:bg-base-200 transition-colors"
            >
              <.icon name="hero-share" class="w-4 h-4" /> Reset graph
            </.link>

            <div class="my-1 border-t border-base-200"></div>

            <%= if @current_scope do %>
              <div class="px-3 py-2 flex items-center gap-3">
                <%= if @current_scope.user.avatar_url do %>
                  <img
                    src={@current_scope.user.avatar_url}
                    alt={@current_scope.user.name || "User avatar"}
                    class="h-8 w-8 rounded-full ring-2 ring-base-300"
                  />
                <% else %>
                  <div class="h-8 w-8 rounded-full bg-primary/10 ring-2 ring-base-300 flex items-center justify-center">
                    <span class="text-sm font-semibold text-primary">
                      {String.first(@current_scope.user.name || @current_scope.user.email)
                      |> String.upcase()}
                    </span>
                  </div>
                <% end %>
                <div class="flex flex-col leading-none">
                  <span class="text-sm font-medium text-base-content">
                    {@current_scope.user.name || @current_scope.user.email}
                  </span>
                  <span class="text-xs text-base-content/50 mt-0.5">{@current_scope.user.email}</span>
                </div>
              </div>
              <.link
                href={~p"/auth/logout"}
                method="delete"
                class="flex items-center gap-2 rounded-lg px-3 py-2.5 text-sm font-medium text-base-content/70 hover:text-base-content hover:bg-base-200 transition-colors"
              >
                <.icon name="hero-arrow-right-start-on-rectangle" class="w-4 h-4" /> Sign out
              </.link>
            <% else %>
              <a
                href={~p"/auth/google"}
                class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-base-content hover:bg-base-200 transition-colors"
              >
                <svg class="h-4 w-4 shrink-0" viewBox="0 0 24 24" aria-hidden="true">
                  <path
                    d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
                    fill="#4285F4"
                  />
                  <path
                    d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                    fill="#34A853"
                  />
                  <path
                    d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
                    fill="#FBBC05"
                  />
                  <path
                    d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
                    fill="#EA4335"
                  />
                </svg>
                Continue with Google
              </a>
              <a
                href={~p"/auth/github"}
                class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium text-base-content hover:bg-base-200 transition-colors"
              >
                <svg
                  class="h-4 w-4 shrink-0"
                  viewBox="0 0 24 24"
                  aria-hidden="true"
                  fill="currentColor"
                >
                  <path
                    fill-rule="evenodd"
                    clip-rule="evenodd"
                    d="M12 0C5.37 0 0 5.506 0 12.303c0 5.445 3.435 10.043 8.205 11.674.6.107.825-.262.825-.585 0-.292-.015-1.261-.015-2.291C6 21.67 5.22 20.346 4.98 19.654c-.135-.354-.72-1.446-1.23-1.738-.42-.23-1.02-.8-.015-.815.945-.015 1.62.892 1.845 1.261 1.08 1.86 2.805 1.338 3.495 1.015.105-.8.42-1.338.765-1.645-2.67-.308-5.46-1.37-5.46-6.075 0-1.338.465-2.446 1.23-3.307-.12-.308-.54-1.569.12-3.26 0 0 1.005-.323 3.3 1.26.96-.276 1.98-.415 3-.415s2.04.139 3 .416c2.295-1.6 3.3-1.261 3.3-1.261.66 1.691.24 2.952.12 3.26.765.861 1.23 1.953 1.23 3.307 0 4.721-2.805 5.767-5.475 6.075.435.384.81 1.122.81 2.276 0 1.645-.015 2.968-.015 3.383 0 .323.225.707.825.585a12.047 12.047 0 0 0 5.919-4.489A12.536 12.536 0 0 0 24 12.304C24 5.505 18.63 0 12 0Z"
                  />
                </svg>
                Continue with GitHub
              </a>
            <% end %>
          </div>
        </div>
      </header>

      <main class="flex-1 px-4 sm:px-6 lg:px-8 py-8 min-h-0">
        <div class="mx-auto max-w-7xl h-full">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark / light / system theme toggle.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-base-300 bg-base-200 p-0.5">
      <div class="absolute h-[calc(100%-4px)] w-1/3 rounded-full bg-base-100 shadow-sm
                  left-0.5
                  [[data-theme=light]_&]:left-[calc(33.333%+1px)]
                  [[data-theme=dark]_&]:left-[calc(66.666%+1px)]
                  transition-[left] duration-200">
      </div>

      <button
        class="relative flex items-center justify-center w-7 h-7 rounded-full cursor-pointer text-base-content/60 hover:text-base-content transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-3.5" />
      </button>

      <button
        class="relative flex items-center justify-center w-7 h-7 rounded-full cursor-pointer text-base-content/60 hover:text-base-content transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-3.5" />
      </button>

      <button
        class="relative flex items-center justify-center w-7 h-7 rounded-full cursor-pointer text-base-content/60 hover:text-base-content transition-colors"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-3.5" />
      </button>
    </div>
    """
  end
end
