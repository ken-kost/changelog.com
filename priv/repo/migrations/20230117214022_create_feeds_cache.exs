defmodule Changelog.Repo.Migrations.CreateFeedsCache do
  use Ecto.Migration

  def change do
    create table(:feeds_cache) do
      add :key, :string, null: false
      add :data, :bytea
    end

    create unique_index(:feeds_cache, [:key])
  end
end
