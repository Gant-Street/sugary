defmodule Sugary.ReviewerPacks do
  def load!(path), do: Sugary.Toml.parse_reviewer_pack_file!(path)

  def reviewer_id(reviewer), do: reviewer["id"] || reviewer[:id]

  def capabilities(reviewer), do: reviewer["capabilities"] || reviewer[:capabilities] || []
end
