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
  alias Xwa.Graphs.{Graph, GraphMembership, GraphSubscription}
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
  Returns all graphs in the system with their owner user preloaded.
  Used by admin UI to select a target graph for document import.
  """
  @spec list_all_graphs() :: [Graph.t()]
  def list_all_graphs do
    Repo.all(
      from g in Graph,
        left_join: m in GraphMembership,
        on: m.graph_id == g.id and m.role == "owner",
        left_join: u in Xwa.Accounts.User,
        on: u.id == m.user_id,
        order_by: [asc: g.inserted_at],
        select: %{id: g.id, name: g.name, owner_email: u.email}
    )
  end

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
  # ---------------------------------------------------------------------------
  # Composite graphs & subscriptions
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a graph_id to the list of Memgraph graph_ids that should be queried.

  - For a personal (non-composite) graph, returns `[graph_id]`.
  - For a composite graph, returns the source_graph_ids of all active subscriptions.

  This is the single choke-point that makes composite graphs transparent to
  all Memgraph query functions.
  """
  @spec resolve_graph_ids(String.t()) :: [String.t()]
  def resolve_graph_ids(graph_id) do
    case Repo.get(Graph, graph_id) do
      %Graph{is_composite: false} ->
        [graph_id]

      %Graph{is_composite: true} ->
        source_ids = Repo.all(
          from s in GraphSubscription,
            where: s.composite_graph_id == ^graph_id and s.status == "active",
            select: s.source_graph_id
        )
        # Include the composite graph_id itself so cross-graph edges stored
        # under it are also retrieved.
        [graph_id | source_ids]

      nil ->
        [graph_id]
    end
  end

  @doc """
  Creates a new composite graph owned by the given user, then creates an
  active subscription for each source_graph_id.

  Returns `{:ok, composite_graph}` or `{:error, reason}`.
  """
  @spec create_composite(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, Graph.t()} | {:error, any()}
  def create_composite(name, invited_by_user_id, source_graph_ids, opts \\ []) do
    user = Xwa.Accounts.get_user(invited_by_user_id)
    org_id = user && user.organization_id

    Repo.transaction(fn ->
      {:ok, graph} =
        %Graph{}
        |> Graph.changeset(%{
          name: name,
          description: Keyword.get(opts, :description),
          organization_id: org_id,
          is_composite: true
        })
        |> Repo.insert()

      Enum.each(source_graph_ids, fn source_id ->
        %GraphSubscription{}
        |> GraphSubscription.changeset(%{
          composite_graph_id: graph.id,
          source_graph_id: source_id,
          role: Keyword.get(opts, :role, "co-owner"),
          status: "active",
          invited_by: invited_by_user_id
        })
        |> Repo.insert!()
      end)

      graph
    end)
  end

  @doc """
  Invites a graph to join a composite graph. Creates a pending subscription
  that the source graph's owner must accept.
  """
  @spec invite_graph(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, GraphSubscription.t()} | {:error, any()}
  def invite_graph(composite_graph_id, source_graph_id, invited_by_user_id, opts \\ []) do
    %GraphSubscription{}
    |> GraphSubscription.changeset(%{
      composite_graph_id: composite_graph_id,
      source_graph_id: source_graph_id,
      role: Keyword.get(opts, :role, "co-owner"),
      status: "pending",
      invited_by: invited_by_user_id
    })
    |> Repo.insert()
  end

  @doc """
  Accepts a pending subscription invite. Called by the source graph's owner.
  """
  @spec accept_invite(String.t()) :: {:ok, GraphSubscription.t()} | {:error, any()}
  def accept_invite(subscription_id) do
    case Repo.get(GraphSubscription, subscription_id) do
      nil -> {:error, :not_found}
      sub -> sub |> GraphSubscription.changeset(%{status: "active"}) |> Repo.update()
    end
  end

  @doc """
  Revokes a subscription — either declining an invite or leaving a composite graph.
  The source graph's data is unaffected.
  """
  @spec revoke_subscription(String.t()) :: {:ok, GraphSubscription.t()} | {:error, any()}
  def revoke_subscription(subscription_id) do
    case Repo.get(GraphSubscription, subscription_id) do
      nil -> {:error, :not_found}
      sub -> sub |> GraphSubscription.changeset(%{status: "revoked"}) |> Repo.update()
    end
  end

  @doc """
  Returns all pending invites for graphs owned by the given user.
  Used to show the user their pending composite graph invitations.
  """
  @spec list_pending_invites_for_user(String.t()) :: [GraphSubscription.t()]
  def list_pending_invites_for_user(user_id) do
    Repo.all(
      from s in GraphSubscription,
        join: g in Graph, on: g.id == s.source_graph_id,
        join: m in GraphMembership,
          on: m.graph_id == g.id and m.user_id == ^user_id and m.role == "owner",
        where: s.status == "pending",
        preload: [composite_graph: :memberships, source_graph: []]
    )
  end

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
