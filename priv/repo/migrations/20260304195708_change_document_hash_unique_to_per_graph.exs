defmodule Xwa.Repo.Migrations.ChangeDocumentHashUniqueToPerGraph do
  use Ecto.Migration

  def change do
    # Replace the global content_hash uniqueness with per-graph uniqueness.
    # Different users/graphs may legitimately ingest the same source document.
    drop unique_index(:documents, [:content_hash], name: :documents_content_hash_unique)

    create unique_index(:documents, [:content_hash, :graph_id],
             where: "content_hash IS NOT NULL AND graph_id IS NOT NULL",
             name: :documents_content_hash_graph_unique
           )
  end
end
