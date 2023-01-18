defmodule ChangelogWeb.FeedGenerator do
  import Logger
  import Phoenix.View, only: [render_to_string: 3]

  alias Changelog.{Episode, FeedsCache, Podcast, Repo}
  alias ChangelogWeb.{Endpoint, FeedView}


  def get_or_store(podcast = %Podcast{slug: slug}) do
    if cached = slug |> FeedsCache.with_key() |> Repo.one() do
      Logger.info "returning cached feed"
      cached.data
    else
      content = generate(podcast)
      Repo.insert(%FeedsCache{key: slug, data: content})
      Logger.info "returning generated feed"
      content
    end
  end

  def generate(podcast = %Podcast{}, template \\ "podcast.xml") do
    podcast = Podcast.preload_active_hosts(podcast)

    episodes =
      podcast
      |> Podcast.get_news_item_episode_ids!()
      |> Episode.with_ids()
      |> Episode.published()
      |> Episode.newest_first()
      |> Episode.exclude_transcript()
      |> Episode.preload_all()
      |> Repo.all()

    render_to_string(FeedView, template, conn: Endpoint, podcast: podcast, episodes: episodes)
  end
end
