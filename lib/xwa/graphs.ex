defmodule Xwa.Graphs do
  @moduledoc """
  Context for managing Graphs and GraphMemberships.

  A Graph is the top-level container for all knowledge graph content.
  Every node and edge in Memgraph carries a `graph_id` that scopes it to
  exactly one Graph record here in Postgres.

  ## Lifecycle

  On user registration, `bootstrap_for_user/1` is called to create:
  1. An Organization (personal, named after the user)
  2. A Graph ("My Graph") within that organization
  3. An owner GraphMembership linking the user to that graph

  This happens transparently — the user never sees the machinery.
  """

  import Ecto.Query
  alias Xwa.Repo
  alias Xwa.Graphs.{Graph, GraphMembership}
  alias Xwa.Accounts.Organization

  # ---------------------------------------------------------------------------
  # Bootstrap
  # ---------------------------------------------------------------------------

  @doc """
  Creates an Organization, a default Graph, and an owner membership for a
  newly registered user. Called once per new user from the auth flow.

  Returns `{:ok, %{organization: org, graph: graph, membership: membership}}`
  or `{:error, step, changeset, changes_so_far}`.
  """
  @spec bootstrap_for_user(Xwa.Accounts.User.t()) ::
          {:ok, %{organization: Organization.t(), graph: Graph.t(), membership: GraphMembership.t()}}
          | {:error, atom(), Ecto.Changeset.t(), map()}
  def bootstrap_for_user(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:organization, Organization.changeset(%Organization{}, %{
      name: org_name_for(user)
    }))
    |> Ecto.Multi.run(:update_user, fn repo, %{organization: org} ->
      user
      |> Ecto.Changeset.change(organization_id: org.id)
      |> repo.update()
    end)
    |> Ecto.Multi.insert(:graph, fn %{organization: org} ->
      Graph.changeset(%Graph{}, %{
        name: "My Graph",
        organization_id: org.id
      })
    end)
    |> Ecto.Multi.insert(:membership, fn %{graph: graph} ->
      GraphMembership.changeset(%GraphMembership{}, %{
        graph_id: graph.id,
        user_id: user.id,
        role: "owner"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{organization: org, graph: graph, membership: membership}} ->
        {:ok, %{organization: org, graph: graph, membership: membership}}

      {:error, step, changeset, changes} ->
        {:error, step, changeset, changes}
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns the graph with the given id, or nil.
  """
  def get_graph(id), do: Repo.get(Graph, id)

  @doc """
  Returns the graph with the given id. Raises if not found.
  """
  def get_graph!(id), do: Repo.get!(Graph, id)

  @doc """
  Returns all graphs the given user is a member of, preloading their membership role.
  """
  @spec list_graphs_for_user(String.t()) :: [Graph.t()]
  def list_graphs_for_user(user_id) do
    Repo.all(
      from g in Graph,
        join: m in GraphMembership,
        on: m.graph_id == g.id and m.user_id == ^user_id,
        preload: [memberships: m],
        order_by: [asc: g.inserted_at]
    )
  end

  @doc """
  Returns the membership record for a user in a graph, or nil.
  """
  @spec get_membership(String.t(), String.t()) :: GraphMembership.t() | nil
  def get_membership(graph_id, user_id) do
    Repo.get_by(GraphMembership, graph_id: graph_id, user_id: user_id)
  end

  @doc """
  Returns the role of a user in a graph, or nil if not a member.
  """
  @spec role_for(String.t(), String.t()) :: String.t() | nil
  def role_for(graph_id, user_id) do
    case get_membership(graph_id, user_id) do
      nil -> nil
      m -> m.role
    end
  end

  @doc """
  Returns true if the user can view content in the graph.
  All roles (viewer, editor, owner) can view.
  """
  @spec can_view?(String.t(), String.t()) :: boolean()
  def can_view?(graph_id, user_id), do: role_for(graph_id, user_id) != nil

  @doc """
  Returns true if the user can add or edit content in the graph.
  """
  @spec can_edit?(String.t(), String.t()) :: boolean()
  def can_edit?(graph_id, user_id), do: role_for(graph_id, user_id) in ["editor", "owner"]

  @doc """
  Returns true if the user is the owner of the graph.
  """
  @spec is_owner?(String.t(), String.t()) :: boolean()
  def is_owner?(graph_id, user_id), do: role_for(graph_id, user_id) == "owner"

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp org_name_for(user) do
    cond do
      user.name && user.name != "" -> "#{user.name}'s Organization"
      true -> "Personal Organization"
    end
  end
end
