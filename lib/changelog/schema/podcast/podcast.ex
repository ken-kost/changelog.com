defmodule Changelog.Podcast do
  use Changelog.Schema

  alias Changelog.{
    Episode,
    EpisodeRequest,
    EpisodeStat,
    Files,
    NewsItem,
    Person,
    PodcastTopic,
    PodcastHost,
    Regexp,
    Subscription
  }

  require Logger

  defenum(Status, draft: 0, soon: 1, published: 2, retired: 3)

  schema "podcasts" do
    field :name, :string
    field :slug, :string
    field :status, Status
    field :is_meta, :boolean, virtual: true, default: false

    field :welcome, :string
    field :description, :string
    field :extended_description, :string

    field :vanity_domain, :string
    field :keywords, :string
    field :mastodon_handle, :string
    field :twitter_handle, :string
    field :apple_url, :string
    field :spotify_url, :string
    field :riverside_url, :string
    field :chartable_id, :string
    field :schedule_note, :string
    field :download_count, :float
    field :reach_count, :integer
    field :recorded_live, :boolean, default: false
    field :partner, :boolean, default: false
    field :position, :integer
    field :subscribers, :map

    field :cover, Files.Cover.Type

    has_many :episodes, Episode, on_delete: :delete_all
    has_many :episode_requests, EpisodeRequest, on_delete: :delete_all
    has_many :podcast_topics, PodcastTopic, on_delete: :delete_all
    has_many :topics, through: [:podcast_topics, :topic]

    has_many :podcast_hosts, PodcastHost, on_delete: :delete_all
    has_many :hosts, through: [:podcast_hosts, :person]

    has_many :active_podcast_hosts, PodcastHost, where: [retired: false]
    has_many :active_hosts, through: [:active_podcast_hosts, :person]

    has_many :retired_podcast_hosts, PodcastHost, where: [retired: true]
    has_many :retired_hosts, through: [:retired_podcast_hosts, :person]

    has_many :episode_stats, EpisodeStat
    has_many :subscriptions, Subscription, where: [unsubscribed_at: nil]

    timestamps()
  end

  def master do
    %__MODULE__{
      name: "Changelog Master Feed",
      slug: "master",
      status: :published,
      is_meta: true,
      twitter_handle: "changelog",
      mastodon_handle: "changelog@changelog.social",
      welcome: "Your one-stop shop for all Changelog podcasts",
      description: "Your one-stop shop for all Changelog podcasts.",
      extended_description:
        "Weekly shows about software development, developer culture, open source, building startups, artificial intelligence, shipping code to production, and the people involved. Yes, we focus on the people. Everything else is an implementation detail.",
      keywords: "changelog, open source, oss, software, development, developer, hacker",
      apple_url: "https://itunes.apple.com/us/podcast/changelog-master-feed/id1164554936",
      spotify_url: "https://open.spotify.com/show/0S1h5K7jm2YvOcM7y1ZMXY",
      cover: true,
      active_hosts: [],
      retired_hosts: []
    }
  end

  def changelog do
    %__MODULE__{
      name: "The Changelog",
      slug: "podcast",
      status: :published,
      is_meta: true,
      vanity_domain: "https://changelog.fm",
      twitter_handle: "changelog",
      mastodon_handle: "changelog@changelog.social",
      welcome: "Software's best weekly news brief, deep technical interviews & talk show",
      description: "Software's best weekly news brief, deep technical interviews & talk show.",
      extended_description: "",
      keywords: "changelog, open source, software, development, code, programming, hacker, change log, software engineering",
      apple_url: "https://podcasts.apple.com/us/podcast/the-changelog/id341623264",
      spotify_url: "https://open.spotify.com/show/5bBki72YeKSLUqyD94qsuJ",
      cover: true,
      active_hosts: Person.with_ids([1, 2]) |> Person.newest_first() |> Repo.all()
    }
  end

  def changelog_ids do
    from(q in __MODULE__, where: q.slug in ~w(news podcast friends), select: [:id]) |> Repo.all() |> Enum.map(&(&1.id))
  end

  def file_changeset(podcast, attrs \\ %{}), do: cast_attachments(podcast, attrs, [:cover])

  def insert_changeset(podcast, attrs \\ %{}) do
    podcast
    |> cast(
      attrs,
      ~w(name slug status vanity_domain schedule_note welcome description extended_description keywords mastodon_handle twitter_handle apple_url spotify_url riverside_url chartable_id recorded_live partner position)a
    )
    |> validate_required([:name, :slug, :status])
    |> validate_format(:vanity_domain, Regexp.http(), message: Regexp.http_message())
    |> validate_format(:apple_url, Regexp.http(), message: Regexp.http_message())
    |> validate_format(:spotify_url, Regexp.http(), message: Regexp.http_message())
    |> validate_format(:slug, Regexp.slug(), message: Regexp.slug_message())
    |> unique_constraint(:slug)
    |> cast_assoc(:podcast_topics)
    |> cast_assoc(:podcast_hosts)
  end

  def update_changeset(podcast, attrs \\ %{}) do
    podcast
    |> insert_changeset(attrs)
    |> file_changeset(attrs)
  end

  def active(query \\ __MODULE__), do: from(q in query, where: q.status in [^:soon, ^:published])
  def draft(query \\ __MODULE__), do: from(q in query, where: q.status == ^:draft)

  def public(query \\ __MODULE__),
    do: from(q in query, where: q.status in [^:soon, ^:published, ^:retired])

  def retired(query \\ __MODULE__), do: from(q in query, where: q.status == ^:retired)
  def not_retired(query \\ __MODULE__), do: from(q in query, where: q.status != ^:retired)
  def oldest_first(query \\ __MODULE__), do: from(q in query, order_by: [asc: q.id])
  def retired_last(query \\ __MODULE__), do: from(q in query, order_by: [asc: q.status])

  def get_by_slug!("master"), do: master()

  def get_by_slug!(slug) do
    public()
    |> Repo.get_by!(slug: slug)
    |> preload_active_hosts()
    |> preload_retired_hosts()
  end

  def get_episodes(%{slug: "master"}), do: from(e in Episode)
  def get_episodes(podcast), do: assoc(podcast, :episodes)

  def get_news_items(%{slug: "master"}), do: NewsItem.with_object(NewsItem.audio())
  def get_news_items(podcast), do: NewsItem.with_object_prefix(NewsItem.audio(), podcast.id)

  def get_news_item_episode_ids!(podcast) do
    podcast
    |> get_news_items()
    |> Ecto.Query.select([:object_id])
    |> Repo.all()
    |> Enum.map(fn i ->
      i.object_id
      |> String.split(":")
      |> List.last()
    end)
  end

  def episode_count(podcast), do: podcast |> assoc(:episodes) |> Repo.count()

  def subscription_count(podcast), do: podcast |> assoc(:subscriptions) |> Repo.count()

  def has_feed(podcast), do: podcast.slug != "backstage"

  def is_changelog(podcast), do: podcast.slug == "podcast" && podcast.is_meta

  def is_a_changelog_pod(podcast) do
    Enum.member?(~w(news podcast friends), podcast.slug)
  end

  def is_interviews(podcast), do: podcast.slug == "podcast" && !podcast.is_meta

  def is_news(podcast), do: podcast.slug == "news"

  def is_master(podcast), do: podcast.slug == "master"

  def published_episode_count(%{slug: "master"}), do: Repo.count(Episode.published())

  def published_episode_count(podcast) do
    podcast
    |> assoc(:episodes)
    |> Episode.published()
    |> Repo.count()
  end

  def last_numbered_slug(podcast) do
    Repo.preload(podcast, :episodes).episodes
    |> Enum.map(fn x ->
      case Integer.parse(x.slug) do
        {int, _remainder} -> int
        :error -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
  end

  def latest_episode(podcast) do
    podcast
    |> assoc(:episodes)
    |> Episode.published()
    |> Episode.newest_first()
    |> Ecto.Query.first()
    |> Repo.one()
  end

  def preload_episode_stats(query = %Ecto.Query{}), do: Ecto.Query.preload(query, :episode_stats)
  def preload_episode_stats(podcast), do: Repo.preload(podcast, :episode_stats)

  def preload_hosts(query = %Ecto.Query{}) do
    query
    |> Ecto.Query.preload(podcast_hosts: ^PodcastHost.by_position())
    |> Ecto.Query.preload(:hosts)
  end

  def preload_hosts(podcast) do
    podcast
    |> Repo.preload(podcast_hosts: {PodcastHost.by_position(), :person})
    |> Repo.preload(:hosts)
  end

  def preload_active_hosts(query = %Ecto.Query{}) do
    query
    |> Ecto.Query.preload(active_podcast_hosts: ^PodcastHost.by_position())
    |> Ecto.Query.preload(:active_hosts)
  end

  def preload_active_hosts(podcast) do
    podcast
    |> Repo.preload(active_podcast_hosts: {PodcastHost.by_position(), :person})
    |> Repo.preload(:active_hosts)
  end

  def preload_retired_hosts(query = %Ecto.Query{}) do
    query
    |> Ecto.Query.preload(retired_podcast_hosts: ^PodcastHost.by_position())
    |> Ecto.Query.preload(:retired_hosts)
  end

  def preload_retired_hosts(podcast) do
    podcast
    |> Repo.preload(retired_podcast_hosts: {PodcastHost.by_position(), :person})
    |> Repo.preload(:retired_hosts)
  end

  def preload_topics(query = %Ecto.Query{}) do
    query
    |> Ecto.Query.preload(podcast_topics: ^PodcastTopic.by_position())
    |> Ecto.Query.preload(:topics)
  end

  def preload_topics(podcast) do
    podcast
    |> Repo.preload(podcast_topics: {PodcastTopic.by_position(), :topic})
    |> Repo.preload(:topics)
  end

  def preload_subscriptions(query = %Ecto.Query{}), do: Ecto.Query.preload(query, :subscriptions)
  def preload_subscriptions(podcast), do: Repo.preload(podcast, :subscriptions)

  def update_stat_counts(podcast) do
    episodes = Repo.all(assoc(podcast, :episodes))

    new_downloads =
      episodes
      |> Enum.map(& &1.download_count)
      |> Enum.sum()
      |> Kernel./(1)
      |> Float.round(2)

    new_reach =
      episodes
      |> Enum.map(& &1.reach_count)
      |> Enum.sum()

    podcast
    |> change(%{download_count: new_downloads, reach_count: new_reach})
    |> Repo.update!()
  end

  def update_subscribers(slug, client, count) when is_binary(slug) do
    podcast = get_by_slug!(slug)
    update_subscribers(podcast, client, count)
  end

  def update_subscribers(%{slug: "master"}, client, count) do
    update_subscribers("backstage", client, count)
  end

  def update_subscribers(podcast = %{subscribers: nil}, client, count) do
    podcast
    |> Map.put(:subscribers, %{})
    |> update_subscribers(client, count)
  end

  def update_subscribers(podcast, client, count) do
    new_subscribers = Map.put(podcast.subscribers, client, count)

    podcast
    |> change(%{subscribers: new_subscribers})
    |> Repo.update!()
  end
end
