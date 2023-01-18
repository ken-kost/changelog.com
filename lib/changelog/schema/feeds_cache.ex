defmodule Changelog.FeedsCache do
  use Changelog.Schema

  schema "feeds_cache" do
    field :key, :string
    field :data, :string
  end

  def changeset(feed, attrs \\ %{}) do
    feed
    |> cast(attrs, ~w(key data)a)
    |> validate_required([:key, :data])
  end

  def with_key(query \\ __MODULE__, key), do: from(q in query, where: q.key == ^key)
end
