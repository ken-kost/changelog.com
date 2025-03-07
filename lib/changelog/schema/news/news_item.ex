defmodule Changelog.NewsItem do
  use Changelog.Schema, default_sort: :published_at

  require Logger

  alias Changelog.{
    Episode,
    Files,
    NewsItemComment,
    NewsItemTopic,
    NewsIssue,
    NewsQueue,
    NewsSource,
    Person,
    Post,
    Regexp,
    Subscription,
    UrlKit
  }

  defenum(Status, declined: -1, draft: 0, queued: 1, submitted: 2, published: 3)
  defenum(Type, link: 0, audio: 1, video: 2, project: 3, announcement: 4)

  schema "news_items" do
    field :status, Status, default: :draft
    field :type, Type

    field :url, :string
    field :headline, :string
    field :story, :string
    field :image, Files.Image.Type
    field :object_id, :string
    field :object, :map, virtual: true

    field :feed_only, :boolean, default: false
    field :pinned, :boolean, default: false

    field :published_at, :utc_datetime
    field :refreshed_at, :utc_datetime

    field :impression_count, :integer, default: 0
    field :click_count, :integer, default: 0

    field :decline_message, :string, default: ""

    belongs_to :author, Person
    belongs_to :logger, Person
    belongs_to :submitter, Person
    belongs_to :source, NewsSource
    has_one :news_queue, NewsQueue, foreign_key: :item_id, on_delete: :delete_all

    has_many :news_item_topics, NewsItemTopic,
      foreign_key: :item_id,
      on_delete: :delete_all,
      on_replace: :delete

    has_many :topics, through: [:news_item_topics, :topic]
    has_many :comments, NewsItemComment, foreign_key: :item_id, on_delete: :delete_all
    has_many :subscriptions, Subscription, where: [unsubscribed_at: nil], foreign_key: :item_id

    timestamps()
  end

  def audio(query \\ __MODULE__), do: from(q in query, where: q.type == ^:audio)
  def non_audio(query \\ __MODULE__), do: from(q in query, where: q.type != ^:audio)

  def by_ids(query \\ __MODULE__, ids),
    do:
      from(q in query, where: q.id in ^ids, order_by: fragment("array_position(?, ?)", ^ids, q.id))

  def feed_only(query \\ __MODULE__), do: from(q in query, where: q.feed_only)
  def non_feed_only(query \\ __MODULE__), do: from(q in query, where: not q.feed_only)

  def declined(query \\ __MODULE__), do: from(q in query, where: q.status == ^:declined)
  def drafted(query \\ __MODULE__), do: from(q in query, where: q.status == ^:draft)

  def logged_by(query \\ __MODULE__, person),
    do: from(q in query, where: q.logger_id == ^person.id)

  def post(query \\ __MODULE__), do: from(q in query, where: like(q.object_id, ^"posts:%"))

  def non_post(query \\ __MODULE__),
    do:
      from(q in query,
        where: fragment("? is null or ? not like 'posts:%'", q.object_id, q.object_id)
      )

  def published(query \\ __MODULE__),
    do: from(q in query, where: q.status == ^:published, where: q.published_at <= ^Timex.now())

  def pinned(query \\ __MODULE__), do: from(q in query, where: q.pinned)
  def unpinned(query \\ __MODULE__), do: from(q in query, where: not q.pinned)

  def search(query, term),
    do: from(q in query, where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^term))

  def similar_to(query \\ __MODULE__, item),
    do:
      from(q in query,
        where: q.id != ^item.id,
        where: ilike(q.url, ^"%#{UrlKit.sans_scheme(item.url)}%")
      )

  def similar_url(query \\ __MODULE__, url),
    do: from(q in query, where: ilike(q.url, ^"%#{UrlKit.sans_scheme(url)}%"))

  def submitted(query \\ __MODULE__), do: from(q in query, where: q.status == ^:submitted)
  def with_author(query \\ __MODULE__), do: from(q in query, where: not is_nil(q.author_id))

  def with_episode(query \\ __MODULE__, episode),
    do: from(q in query, where: q.object_id == ^Episode.object_id(episode))

  def with_episodes(query \\ __MODULE__, episodes),
    do: from(q in query, where: q.object_id in ^Enum.map(episodes, &Episode.object_id/1))

  def with_person(query \\ __MODULE__, person),
    do: from(q in query, where: fragment("submitter_id=? or author_id=?", ^person.id, ^person.id))

  def with_post(query \\ __MODULE__, post),
    do: from(q in query, where: q.object_id == ^"posts:#{post.slug}")

  def with_object(query \\ __MODULE__), do: from(q in query, where: not is_nil(q.object_id))
  def sans_object(query \\ __MODULE__), do: from(q in query, where: is_nil(q.object_id))

  def with_object_prefix(query \\ __MODULE__, prefix),
    do: from(q in query, where: like(q.object_id, ^"#{prefix}:%"))

  def with_image(query \\ __MODULE__), do: from(q in query, where: not is_nil(q.image))

  def with_source(query \\ __MODULE__, source),
    do: from(q in query, where: q.source_id == ^source.id)

  def with_topic(query \\ __MODULE__, topic),
    do: from(q in query, join: t in assoc(q, :news_item_topics), where: t.topic_id == ^topic.id)

  def with_url(query \\ __MODULE__, url), do: from(q in query, where: q.url == ^url)

  def with_person_or_episodes(person, episodes) do
    person_query = with_person(person)
    episode_query = with_episodes(episodes)
    unioned_query = Ecto.Query.union(person_query, ^episode_query)
    from(q in Ecto.Query.subquery(unioned_query))
  end

  def published_since(query \\ __MODULE__, issue_or_time)

  def published_since(query, i = %NewsIssue{}),
    do: from(q in query, where: q.status == ^:published, where: q.published_at >= ^i.published_at)

  def published_since(query, time = %DateTime{}),
    do: from(q in query, where: q.status == ^:published, where: q.published_at >= ^time)

  def published_since(query, _), do: published(query)

  def freshest_first(query \\ __MODULE__), do: from(q in query, order_by: [desc: :refreshed_at])
  def top_clicked_first(query \\ __MODULE__), do: from(q in query, order_by: [desc: :click_count])

  def top_ctr_first(query \\ __MODULE__),
    do:
      from(q in query,
        order_by: fragment("click_count::float / NULLIF(impression_count, 0) desc nulls last")
      )

  def top_impressed_first(query \\ __MODULE__),
    do: from(q in query, order_by: [desc: :impression_count])

  def file_changeset(item, attrs \\ %{}),
    do: cast_attachments(item, attrs, [:image], allow_urls: true)

  def insert_changeset(item, attrs \\ %{}) do
    item
    |> cast(
      attrs,
      ~w(status type url headline story pinned published_at author_id logger_id submitter_id object_id source_id)a
    )
    |> validate_required([:type, :url, :headline, :logger_id])
    |> validate_format(:url, Regexp.http(), message: Regexp.http_message())
    |> foreign_key_constraint(:author_id)
    |> foreign_key_constraint(:logger_id)
    |> foreign_key_constraint(:source_id)
    |> cast_assoc(:news_item_topics)
  end

  def submission_changeset(item, attrs \\ %{}) do
    item
    |> cast(attrs, ~w(url headline story author_id submitter_id)a)
    |> validate_required([:type, :url, :headline, :submitter_id])
    |> validate_format(:url, Regexp.http(), message: Regexp.http_message())
  end

  def update_changeset(item, attrs \\ %{}) do
    item
    |> insert_changeset(attrs)
    |> file_changeset(attrs)
  end

  def get_pinned_non_feed_news_items do
    from(news_item in __MODULE__,
      left_join: author in assoc(news_item, :author),
      left_join: comments in assoc(news_item, :comments),
      left_join: submitter in assoc(news_item, :submitter),
      left_join: source in assoc(news_item, :source),
      left_join: logger in assoc(news_item, :logger),
      left_join: news_item_topics in assoc(news_item, :news_item_topics),
      left_join: news_item_topics_topic in assoc(news_item_topics, :topic),
      where: news_item.status == ^:published,
      where: news_item.published_at <= ^Timex.now(),
      where: not news_item.feed_only,
      where: news_item.pinned,
      order_by: [desc: :published_at, asc: news_item_topics.position],
      preload: [
        author: author,
        comments: comments,
        submitter: submitter,
        topics: news_item_topics_topic,
        source: source,
        logger: logger
      ]
    )
    |> Repo.all()
  end

  def get_unpinned_non_feed_news_items(params) do
    page =
      from(news_item in __MODULE__,
        where: news_item.status == ^:published,
        where: news_item.published_at <= ^Timex.now(),
        where: not news_item.feed_only,
        where: not news_item.pinned,
        order_by: [desc: :published_at]
      )
      |> Repo.paginate(Map.put(params, :page_size, 20))

    news_item_ids =
      page
      |> Map.get(:entries)
      |> Enum.map(fn news_item ->
        news_item.id
      end)

    results =
      from(news_item in __MODULE__,
        left_join: author in assoc(news_item, :author),
        left_join: comments in assoc(news_item, :comments),
        left_join: submitter in assoc(news_item, :submitter),
        left_join: source in assoc(news_item, :source),
        left_join: logger in assoc(news_item, :logger),
        left_join: news_item_topics in assoc(news_item, :news_item_topics),
        left_join: news_item_topics_topic in assoc(news_item_topics, :topic),
        where: news_item.id in ^news_item_ids,
        order_by: [desc: :published_at, asc: news_item_topics.position],
        preload: [
          author: author,
          comments: comments,
          submitter: submitter,
          topics: news_item_topics_topic,
          source: source,
          logger: logger
        ]
      )
      |> Repo.all()

    {page, results}
  end

  def get_post_news_items(params) do
    page =
      from(news_item in __MODULE__,
        where: like(news_item.object_id, ^"posts:%"),
        where: news_item.status == ^:published,
        where: news_item.published_at <= ^Timex.now(),
        where: not news_item.feed_only,
        order_by: [desc: :inserted_at]
      )
      |> Repo.paginate(Map.put(params, :page_size, 15))

    news_item_ids =
      page
      |> Map.get(:entries)
      |> Enum.map(fn news_item ->
        news_item.id
      end)

    results =
      from(news_item in __MODULE__,
        left_join: author in assoc(news_item, :author),
        left_join: logger in assoc(news_item, :logger),
        left_join: submitter in assoc(news_item, :submitter),
        left_join: topics in assoc(news_item, :topics),
        left_join: source in assoc(news_item, :source),
        left_join: comments in assoc(news_item, :comments),
        left_join: news_item_topics in assoc(news_item, :news_item_topics),
        left_join: news_item_topics_topic in assoc(news_item_topics, :topic),
        where: news_item.id in ^news_item_ids,
        order_by: [desc: :inserted_at, asc: news_item_topics.position, desc: topics.id],
        preload: [
          author: author,
          comments: comments,
          logger: logger,
          submitter: submitter,
          source: source,
          topics: topics,
          news_item_topics: {news_item_topics, topic: news_item_topics_topic}
        ]
      )
      |> Repo.all()
      |> batch_load_objects()

    {page, results}
  end

  def batch_load_objects(news_items) do
    {episodes, posts} =
      Enum.split_with(news_items, fn news_item ->
        news_item.type == :audio
      end)

    episode_ids =
      episodes
      |> Enum.map(fn
        %{object_id: nil} ->
          nil

        %{object_id: object_id} ->
          [_podcast_id, episode_id] = String.split(object_id, ":")
          episode_id

        _ ->
          nil
      end)
      |> Enum.reject(fn
        nil -> true
        _ -> false
      end)

    # Only hit the DB if there are episodes to resolve
    episode_data =
      if episode_ids == [] do
        []
      else
        from(episode in Episode.exclude_transcript(),
          left_join: podcast in assoc(episode, :podcast),
          left_join: episode_guests in assoc(episode, :episode_guests),
          left_join: person in assoc(episode_guests, :person),
          left_join: guests in assoc(episode, :guests),
          left_join: hosts in assoc(episode, :hosts),
          where: episode.id in ^episode_ids,
          order_by: [asc: episode_guests.position],
          preload: [
            podcast: podcast,
            episode_guests: {episode_guests, person: person},
            guests: guests,
            hosts: hosts
          ]
        )
        |> Repo.all()
      end

    post_ids =
      posts
      |> Enum.map(fn
        %{object_id: nil} ->
          nil

        %{object_id: object_id} ->
          [_, slug] = String.split(object_id, ":")
          slug

        _ ->
          nil
      end)

    # Only hit the DB if there are posts to resolve
    post_data =
      if post_ids == [] do
        []
      else
        from(post in Post.published(),
          left_join: author in assoc(post, :author),
          left_join: editor in assoc(post, :editor),
          left_join: post_topics in assoc(post, :post_topics),
          left_join: post_topics_topic in assoc(post_topics, :topic),
          left_join: topics in assoc(post, :topics),
          where: post.slug in ^post_ids,
          order_by: [asc: post_topics.position, asc: post_topics_topic.id],
          preload: [
            author: author,
            editor: editor,
            post_topics: {post_topics, topic: post_topics_topic},
            topics: topics
          ]
        )
        |> Repo.all()
      end

    news_items
    |> Enum.map(fn
      %{object_id: nil} = result ->
        result

      %{type: :audio, object_id: object_id} = result ->
        [_podcast_id, episode_id] = String.split(object_id, ":")

        object =
          Enum.find(episode_data, fn episode -> Integer.to_string(episode.id) == episode_id end)

        %{result | object: object}

      result ->
        [_, slug] = String.split(result.object_id, ":")
        object = Enum.find(post_data, fn post -> post.slug == slug end)
        %{result | object: object}
    end)
  end

  def slug(item) do
    item.headline
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
    |> Kernel.<>("-#{hashid(item)}")
  end

  def load_object(item) do
    object =
      case item.type do
        :audio -> get_episode_object(item.object_id)
        _else -> get_post_object(item.object_id)
      end

    load_object(item, object)
  end

  def load_object(nil, _object), do: nil
  def load_object(item, object), do: Map.put(item, :object, object)

  def load_object_with_transcript(item = %{object_id: object_id}) do
    [_podcast_id, episode_id] = String.split(object_id, ":")

    episode =
      Episode
      |> Repo.get(episode_id)

    load_object(item, episode)
  end

  defp get_episode_object(object_id) when is_nil(object_id), do: nil

  defp get_episode_object(object_id) do
    [_podcast_id, episode_id] = String.split(object_id, ":")

    Episode
    |> Episode.exclude_transcript()
    |> Episode.preload_podcast()
    |> Episode.preload_guests()
    |> Repo.get(episode_id)
  end

  defp get_post_object(object_id) when is_nil(object_id), do: nil

  defp get_post_object(object_id) do
    [_, slug] = String.split(object_id, ":")

    Post.published()
    |> Post.preload_all()
    |> Repo.get_by!(slug: slug)
  end

  def comment_count(item) do
    if Ecto.assoc_loaded?(item.comments) do
      length(item.comments)
    else
      Repo.count(from(q in NewsItemComment, where: q.item_id == ^item.id))
    end
  end

  def participants(item) do
    item = preload_all(item)

    [
      item.author,
      item.submitter,
      item.logger
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def preload_all(query = %Ecto.Query{}) do
    query
    |> Ecto.Query.preload(:author)
    |> Ecto.Query.preload(:logger)
    |> Ecto.Query.preload(:submitter)
    |> preload_source()
    |> preload_topics()
  end

  def preload_all(item) do
    item
    |> Repo.preload(:author)
    |> Repo.preload(:logger)
    |> Repo.preload(:submitter)
    |> preload_source()
    |> preload_topics()
  end

  def preload_comments(query = %Ecto.Query{}) do
    Ecto.Query.preload(query, comments: ^NewsItemComment.newest_first())
  end

  def preload_comments(item) do
    Repo.preload(item, comments: {NewsItemComment.newest_first(), [:author]})
  end

  def preload_source(query = %Ecto.Query{}) do
    Ecto.Query.preload(query, :source)
  end

  def preload_source(item) do
    Repo.preload(item, :source)
  end

  def preload_topics(query = %Ecto.Query{}) do
    query
    |> Ecto.Query.preload(news_item_topics: ^NewsItemTopic.by_position())
    |> Ecto.Query.preload(:topics)
  end

  def preload_topics(item) do
    item
    |> Repo.preload(news_item_topics: {NewsItemTopic.by_position(), :topic})
    |> Repo.preload(:topics)
  end

  def decline!(item), do: item |> change(%{status: :declined}) |> Repo.update!()
  def decline!(item, ""), do: decline!(item)

  def decline!(item, message),
    do: item |> change(%{status: :declined, decline_message: message}) |> Repo.update!()

  def queue!(item), do: item |> change(%{status: :queued}) |> Repo.update!()

  def publish!(item),
    do:
      item
      |> change(%{
        status: :published,
        published_at: item.published_at || now_in_seconds(),
        refreshed_at: now_in_seconds()
      })
      |> Repo.update!()

  def unpublish!(item),
    do: item |> change(%{status: :draft, published_at: nil, refreshed_at: nil}) |> Repo.update!()

  def is_audio(item), do: item.type == :audio
  def is_non_audio(item), do: item.type != :audio
  def is_post(item), do: item.type == :link && !is_nil(item.object_id)
  def is_video(item), do: item.type == :video

  def is_draft(item), do: item.status == :draft
  def is_published(item), do: item.status == :published
  def is_queued(item), do: item.status == :queued

  def subscribe_participants(item = %{type: :audio}) do
    item
    |> load_object()
    |> Map.get(:object)
    |> Episode.participants()
    |> Enum.filter(& &1.settings.subscribe_to_participated_episodes)
    |> Enum.each(fn person ->
      Subscription.subscribe(person, item, "you were on this episode")
    end)
  end

  def subscribe_participants(item) do
    item
    |> participants()
    |> Enum.filter(& &1.settings.subscribe_to_contributed_news)
    |> Enum.each(fn person ->
      Subscription.subscribe(person, item, "you contributed to this news")
    end)
  end

  def track_click(item) do
    item
    |> change(%{click_count: item.click_count + 1})
    |> Repo.update!()
  end

  def track_impression(item) do
    item
    |> change(%{impression_count: item.impression_count + 1})
    |> Repo.update!()
  end

  def latest_news_items do
    __MODULE__
    |> published()
    |> newest_first()
    |> preload_all()
    |> limit(50)
    |> Repo.all()
    |> Enum.map(&load_object/1)
  end

  def recommend_podcasts(episode = %Episode{}, num_recommendations) do
    recommendation_query = "SELECT * FROM query_related_podcast($1::integer, $2::integer)"
    query_args = [episode.id, num_recommendations]

    ConCache.fetch_or_store(
      :news_item_recommendations,
      {:podcast, episode.id, num_recommendations},
      fn ->
        query_recommendations(recommendation_query, query_args)
      end
    )
  end

  def recommend_news_items(news_item = %__MODULE__{}, num_recommendations) do
    recommendation_query = "SELECT * FROM query_related_news_item($1::integer, $2::integer)"
    query_args = [news_item.id, num_recommendations]

    ConCache.fetch_or_store(
      :news_item_recommendations,
      {:news_item, news_item.id, num_recommendations},
      fn ->
        query_recommendations(recommendation_query, query_args)
      end
    )
  end

  def recommend_posts(news_item = %__MODULE__{}, num_recommendations) do
    recommendation_query = "SELECT * FROM query_related_post($1::integer, $2::integer)"
    query_args = [news_item.id, num_recommendations]

    ConCache.fetch_or_store(
      :news_item_recommendations,
      {:post, news_item.id, num_recommendations},
      fn ->
        query_recommendations(recommendation_query, query_args)
      end
    )
  end

  defp query_recommendations(query, args) do
    try do
      query
      |> Changelog.Repo.query(args)
      |> case do
        {:ok, %Postgrex.Result{columns: columns, rows: rows}} ->
          results =
            Enum.map(rows, fn row ->
              columns
              |> Enum.zip(row)
              |> Map.new()
            end)

          {:ok, results}

        error ->
          Logger.warn("Failed to fetch recommended items: #{inspect(error)}")
          {:error, error}
      end
    rescue
      error ->
        Logger.warn("Failed to fetch recommended items: #{inspect(error)}")
        {:error, error}
    end
  end
end
