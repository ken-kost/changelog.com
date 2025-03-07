defmodule Changelog.PodPing do

  # alias Changelog.HTTP
  alias ChangelogWeb.{Endpoint}
  alias ChangelogWeb.Router.Helpers, as: Routes

  def overcast(episode) do
    url = Routes.feed_url(Endpoint, :podcast, episode.podcast.slug)
    # disabling this until we have instant feed refresh on public
    # HTTP.post("https://overcast.fm/ping", {:form, [{"urlprefix", url}]})
    url
  end
end
