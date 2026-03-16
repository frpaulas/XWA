defmodule Mix.Tasks.ExportIlvCsv do
  @moduledoc """
  Exports ILV credibility data for all claims in a user's graphs to CSV.

  ## Usage

      mix export_ilv_csv --username gv
      mix export_ilv_csv --username gv --output /tmp/ilv_export.csv

  Output columns:
    claim, cfp_w, cfp_x, cfp_y, cfp_z, sigma_w, sigma_x, sigma_y, sigma_z

  GFP (corpus median + SD) is written as a header block at the top of the file.
  """

  use Mix.Task

  import Ecto.Query

  alias Xwa.Repo
  alias Xwa.Graphs.Graph
  alias Xwa.Graphs.GraphMembership
  alias Xwa.Accounts.User
  alias Xwa.Graph, as: MemGraph

  @shortdoc "Export ILV CFP + Z-scores for a user's claims to CSV"

  @dims ["w", "x", "y", "z"]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args, strict: [username: :string, output: :string])
    username = Keyword.fetch!(opts, :username)
    output_path = Keyword.get(opts, :output, "ilv_export_#{username}.csv")

    graphs = graphs_for_user(username)

    if graphs == [] do
      Mix.shell().error("No graphs found for user #{username}")
      exit(:normal)
    end

    Mix.shell().info("Found #{length(graphs)} graph(s) for #{username}")

    rows = build_rows(graphs)

    File.write!(output_path, rows)
    Mix.shell().info("Written to #{output_path} (#{length(String.split(rows, "\n")) - 1} lines)")
  end

  # ---------------------------------------------------------------------------

  defp graphs_for_user(username) do
    Repo.all(
      from g in Graph,
        join: m in GraphMembership,
        on: m.graph_id == g.id and m.role == "owner",
        join: u in User,
        on: u.id == m.user_id,
        where: u.username == ^username,
        select: g
    )
  end

  defp build_rows(graphs) do
    sections =
      Enum.map(graphs, fn graph ->
        gfp = graph.fingerprint

        claims = fetch_claims(graph.id)
        scored = Enum.filter(claims, fn c -> c["ilv_score"] != nil end)

        Mix.shell().info(
          "  Graph \"#{graph.name}\" (#{graph.id}): #{length(scored)}/#{length(claims)} claims scored"
        )

        [
          gfp_header(graph, gfp),
          column_header(),
          claim_rows(scored, gfp)
        ]
        |> List.flatten()
        |> Enum.join("\n")
      end)

    Enum.join(sections, "\n\n") <> "\n"
  end

  defp gfp_header(graph, nil) do
    ["# Graph: #{graph.name} (#{graph.id})", "# GFP: not calibrated"]
  end

  defp gfp_header(graph, gfp) do
    medians = Enum.map_join(@dims, ", ", fn d -> "#{d}=#{fmt(get_median(gfp, d))}" end)
    sds = Enum.map_join(@dims, ", ", fn d -> "#{d}=#{fmt(get_sd(gfp, d))}" end)

    [
      "# Graph: #{graph.name} (#{graph.id})",
      "# GFP median: #{medians}",
      "# GFP SD:     #{sds}"
    ]
  end

  defp column_header do
    ["claim,cfp_w,cfp_x,cfp_y,cfp_z,sigma_w,sigma_x,sigma_y,sigma_z"]
  end

  defp claim_rows(claims, gfp) do
    Enum.map(claims, fn claim ->
      fp = parse_fp(claim["ilv_fingerprint"])
      content = escape_csv(claim["content"])

      cfp_vals = Enum.map(@dims, fn d -> fmt(fp[d] || 0.5) end)

      sigma_vals =
        Enum.map(@dims, fn d ->
          sd = get_sd(gfp, d)
          cfp = fp[d] || 0.5

          if sd && sd > 0,
            do: fmt(Float.round((cfp - 0.5) / sd, 3)),
            else: ""
        end)

      ([content] ++ cfp_vals ++ sigma_vals) |> Enum.join(",")
    end)
  end

  defp fetch_claims(graph_id) do
    cypher = """
    MATCH (n:Claim {graph_id: $graph_id})
    WHERE n.content IS NOT NULL AND n.content <> ''
    RETURN n.content AS content,
           n.ilv_score AS ilv_score,
           n.ilv_fingerprint AS ilv_fingerprint
    ORDER BY n.ilv_score DESC
    """

    case MemGraph.query(cypher, %{graph_id: graph_id}) do
      {:ok, rows} -> rows
      {:error, reason} ->
        Mix.shell().error("Memgraph query failed: #{inspect(reason)}")
        []
    end
  end

  # fp stored as string-keyed map in Memgraph
  defp parse_fp(nil), do: %{}
  defp parse_fp(fp) when is_map(fp), do: fp
  defp parse_fp(_), do: %{}

  defp get_median(nil, _d), do: nil
  defp get_median(gfp, d) do
    entry = gfp[d] || gfp[to_string(d)]
    if is_map(entry), do: entry["median"], else: entry
  end

  defp get_sd(nil, _d), do: nil
  defp get_sd(gfp, d) do
    entry = gfp[d] || gfp[to_string(d)]
    if is_map(entry), do: entry["sd"], else: nil
  end

  defp fmt(nil), do: ""
  defp fmt(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 4)
  defp fmt(i) when is_integer(i), do: Integer.to_string(i)
  defp fmt(x), do: to_string(x)

  defp escape_csv(s) when is_binary(s) do
    escaped = String.replace(s, "\"", "\"\"")
    "\"#{escaped}\""
  end
  defp escape_csv(_), do: "\"\""
end
