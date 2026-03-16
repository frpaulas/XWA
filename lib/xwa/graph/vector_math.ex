defmodule Xwa.Graph.VectorMath do
  @moduledoc """
  Shared vector math utilities for embedding-based operations.
  """

  @doc "Normalizes a vector to unit length (L2 norm)."
  def normalize(vec) do
    mag = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))
    if mag == 0.0, do: vec, else: Enum.map(vec, &(&1 / mag))
  end

  @doc "Dot product of two vectors. If both are pre-normalized, equals cosine similarity."
  def dot_product(a, b) do
    Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
  end

  @doc "Cosine similarity between two vectors (normalizes both first)."
  def cosine_similarity(a, b) do
    dot_product(normalize(a), normalize(b))
  end
end
