defmodule ChangelogWeb.EpisodeView do
  use ChangelogWeb, :public_view

  alias Changelog.{
    Episode,
    Files,
    Github,
    HtmlKit,
    ListKit,
    NewsItem,
    Subscription,
    UrlKit
  }

  alias ChangelogWeb.{
    Endpoint,
    LayoutView,
    Meta,
    PersonView,
    PodcastView,
    SponsorView,
    TimeView
  }

  def admin_edit_link(conn, %{admin: true}, episode) do
    path =
      Routes.admin_podcast_episode_path(conn, :edit, episode.podcast.slug, episode.slug,
        next: SharedHelpers.current_path(conn)
      )

    content_tag(:span) do
      [
        link("🎧 #{SharedHelpers.pretty_downloads(episode)}",
          to: path,
          data: [turbolinks: false]
        )
      ]
    end
  end

  def admin_edit_link(_, _, episode) do
    if episode.download_count > 0 do
      content_tag(:span, "🎧 #{SharedHelpers.pretty_downloads(episode)}")
    end
  end

  def audio_filename(episode) do
    Files.Audio.filename(:original, {episode.audio_file.file_name, episode}) <> ".mp3"
  end

  def plusplus_filename(episode) do
    Files.PlusPlus.filename(:original, {episode.plusplus_file.file_name, episode}) <> ".mp3"
  end

  # use this whenever fetching audio for public consumption
  def audio_url(episode) do
    episode
    |> audio_direct_url()
    |> get_down_with_op3(Mix.env())
  end

  # use this whenever fetching audio for direct manipulation
  def audio_direct_url(episode) do
    {episode.audio_file, episode}
    |> Files.Audio.url(:original)
    |> UrlKit.sans_cache_buster()
  end

  defp get_down_with_op3(url, :dev), do: url

  defp get_down_with_op3(url, _mode), do: String.replace_prefix(url, "", "https://op3.dev/e/")

  # simplest case, no ++
  def plusplus_cta(%{plusplus_file: pp}) when is_nil(pp), do: fallback_cta()

  # yes ++ but no sponsors
  def plusplus_cta(episode = %{episode_sponsors: []}) do
    pp_diff = episode.plusplus_duration - episode.audio_duration

    # we only care if the bonus is a minute or longer
    if pp_diff > 60 do
      bonus_cta(pp_diff)
    else
      fallback_cta()
    end
  end

  def plusplus_cta(episode) do
    pp_diff = episode.plusplus_duration - episode.audio_duration
    ads_duration = Episode.sponsors_duration(episode)
    bonus_duration = pp_diff + ads_duration

    cond do
      # bonus of a minute or longer
      bonus_duration > 60 -> bonus_cta(bonus_duration)
      # nothing to talk about if it's less than a minute saved
      pp_diff < -60 -> saved_cta(abs(pp_diff))
      true -> fallback_cta()
    end
  end

  defp bonus_cta(time) do
    bonus_minutes = SharedHelpers.pluralize(TimeView.rounded_minutes(time), "minute", "minutes")
    "members get a bonus #{bonus_minutes} at the end of this episode and zero ads."
  end

  defp saved_cta(time) do
    saved_minutes = SharedHelpers.pluralize(TimeView.rounded_minutes(time), "minute", "minutes")
    "members save #{saved_minutes} on this episode because they made the ads disappear."
  end

  defp fallback_cta do
    "members support our work, get closer to the metal, and make the ads disappear."
  end

  def plusplus_url(episode) do
    {episode.audio_file, episode}
    |> Files.PlusPlus.url(:original)
    |> UrlKit.sans_cache_buster()
  end

  def classy_highlight(episode) do
    episode.highlight
    |> PublicHelpers.no_widowed_words()
    |> PublicHelpers.with_smart_quotes()
    |> raw
  end

  def embed_code(episode), do: embed_code(episode, episode.podcast)

  def embed_code(episode, podcast) do
    ~s{<audio data-theme="night" data-src="#{url(episode, :embed)}" src="#{audio_url(episode)}" preload="none" class="changelog-episode" controls></audio>} <>
      ~s{<p><a href="#{url(episode, :show)}">#{podcast.name} #{numbered_title(episode)}</a> – Listen on <a href="#{Routes.root_url(Endpoint, :index)}">Changelog.com</a></p>} <>
      ~s{<script async src="//cdn.changelog.com/embed.js"></script>}
  end

  def embed_iframe(episode, theme) do
    ~s{<iframe src="#{url(episode, :embed)}?theme=#{theme}" width="100%" height=220 scrolling=no frameborder=no></iframe>}
  end

  def guest_focused_subtitle(episode) do
    if is_subtitle_guest_focused(episode), do: episode.subtitle, else: ""
  end

  def guid(episode) do
    episode.guid || "changelog.com/#{episode.podcast_id}/#{episode.id}"
  end

  def is_subtitle_guest_focused(%{subtitle: nil}), do: false
  def is_subtitle_guest_focused(%{guests: nil}), do: false
  def is_subtitle_guest_focused(%{guests: []}), do: false

  def is_subtitle_guest_focused(%{subtitle: subtitle}) do
    String.starts_with?(subtitle, "with ") ||
      String.starts_with?(subtitle, "featuring ")
  end

  def megabytes(episode, type \\ "audio") do
    bytes = Map.get(episode, String.to_existing_atom("#{type}_bytes"), 0)
    round(bytes / 1000 / 1000)
  end

  def number(episode) do
    case Float.parse(episode.slug) do
      {_, _} -> episode.slug
      :error -> nil
    end
  end

  def number_with_pound(episode) do
    if episode_number = number(episode) do
      "##{episode_number}"
    end
  end

  def numbered_title(episode, prefix \\ "") do
    episode_number = number(episode)

    if is_nil(episode_number) do
      episode.title
    else
      "#{prefix}#{episode_number}: #{episode.title}"
    end
  end

  def participants(episode) do
    Episode.participants(episode)
  end

  def podcast_aside(episode) do
    "(#{podcast_name_and_number(episode)})"
  end

  def podcast_name_and_number(episode) do
    [episode.podcast.name, number_with_pound(episode)] |> ListKit.compact_join(" ")
  end

  def published_before_transcripts?(episode) do
    !is_nil(episode.published_at) && Timex.before?(episode.published_at, ~D[2016-04-20])
  end

  def sponsorships_with_dark_logo(episode) do
    Enum.reject(episode.episode_sponsors, fn s -> is_nil(s.sponsor.dark_logo) end)
  end

  def show_notes_source_url(episode) do
    Github.Source.new("show-notes", episode).html_url
  end

  def title_with_podcast_aside(episode) do
    [
      episode.title,
      podcast_aside(episode)
    ]
    |> ListKit.compact_join(" ")
  end

  def title_with_guest_focused_subtitle_and_podcast_aside(episode = %{type: :trailer}),
    do: episode.title

  def title_with_guest_focused_subtitle_and_podcast_aside(episode) do
    [
      episode.title,
      guest_focused_subtitle(episode),
      "(#{podcast_name_and_number(episode)})"
    ]
    |> ListKit.compact_join(" ")
  end

  def transcript_url(episode) do
    Routes.episode_url(Endpoint, :show, episode.podcast.slug, episode.slug) <> "#transcript"
  end

  def transcript_source_url(episode) do
    Github.Source.new("transcripts", episode).html_url
  end

  def transcript_repo_url(episode) do
    Github.Source.new("transcripts", episode).repo_url
  end

  defp chapters_json(chapters) do
    chapters
    |> Enum.with_index()
    |> Enum.map(fn {chapter, index} ->
      %{
        title: chapter.title,
        number: index + 1,
        startTime: round(chapter.starts_at),
        endTime: round(chapter.ends_at),
        url: chapter.link_url,
        img: chapter.image_url
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
    end)
  end

  # format: https://github.com/Podcastindex-org/podcast-namespace/blob/main/chapters/jsonChapters.md
  def render("chapters.json", %{chapters: chapters}) do
    %{
      version: "1.2.0",
      chapters: chapters_json(chapters)
    }
  end

  def render("play.json", %{podcast: podcast, episode: episode, prev: prev, next: next}) do
    info = %{
      podcast: podcast.name,
      title: episode.title,
      number: number(episode),
      duration: episode.audio_duration,
      art_url: PodcastView.cover_url(podcast, :medium),
      audio_url: audio_url(episode),
      chapters: chapters_json(episode.audio_chapters),
      share_url: share_url(episode)
    }

    info =
      if prev do
        Map.put(info, :prev, %{
          number: prev.slug,
          title: prev.title,
          location: Routes.episode_path(Endpoint, :play, podcast.slug, prev.slug),
          audio_url: audio_url(prev)
        })
      else
        info
      end

    info =
      if next do
        Map.put(info, :next, %{
          number: next.slug,
          title: next.title,
          location: Routes.episode_path(Endpoint, :play, podcast.slug, next.slug),
          audio_url: audio_url(next)
        })
      else
        info
      end

    info
  end

  def render("share.json", %{podcast: _podcast, episode: episode}) do
    url = share_url(episode)

    %{
      url: url,
      twitter: PublicHelpers.tweet_url(episode.title, url),
      mastodon: PublicHelpers.mastodon_url(episode.title, url),
      hackernews: PublicHelpers.hackernews_url(episode.title, url),
      reddit: PublicHelpers.reddit_url(episode.title, url),
      facebook: PublicHelpers.facebook_url(url),
      embed: embed_code(episode)
    }
  end

  def share_url(episode) do
    episode = Episode.preload_podcast(episode)
    vanity = episode.podcast.vanity_domain

    if vanity do
      vanity <> "/" <> episode.slug
    else
      url(episode, :show)
    end
  end

  def url(episode, action) do
    episode = Episode.preload_podcast(episode)
    Routes.episode_url(Endpoint, action, episode.podcast.slug, episode.slug)
  end
end
