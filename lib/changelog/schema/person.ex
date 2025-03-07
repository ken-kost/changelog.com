defmodule Changelog.Person do
  use Changelog.Schema

  alias Changelog.{
    Episode,
    EpisodeHost,
    EpisodeGuest,
    EpisodeRequest,
    Faker,
    Files,
    NewsItem,
    NewsItemComment,
    PodcastHost,
    Post,
    Regexp,
    Subscription
  }

  defmodule Settings do
    use Changelog.Schema

    @primary_key false
    embedded_schema do
      field :subscribe_to_contributed_news, :boolean, default: true
      field :subscribe_to_participated_episodes, :boolean, default: true
      field :email_on_authored_news, :boolean, default: true
      field :email_on_submitted_news, :boolean, default: true
      field :email_on_comment_replies, :boolean, default: true
      field :email_on_comment_mentions, :boolean, default: true
    end

    def changeset(struct, attrs) do
      cast(struct, attrs, __MODULE__.__schema__(:fields))
    end

    def is_valid(name) when is_binary(name) do
      __MODULE__.__schema__(:fields)
      |> Enum.map(&Atom.to_string/1)
      |> Enum.any?(&(&1 == name))
    end

    def is_valid(_), do: false
  end

  schema "people" do
    field :name, :string
    field :email, :string
    field :handle, :string
    field :github_handle, :string
    field :linkedin_handle, :string
    field :mastodon_handle, :string
    field :twitter_handle, :string
    field :slack_id, :string
    field :website, :string
    field :bio, :string
    field :location, :string
    field :auth_token, :string
    field :auth_token_expires_at, :utc_datetime
    field :joined_at, :utc_datetime
    field :signed_in_at, :utc_datetime
    field :approved, :boolean, default: false
    field :avatar, Files.Avatar.Type

    field :admin, :boolean, default: false
    field :host, :boolean, default: false
    field :editor, :boolean, default: false

    field :public_profile, :boolean, default: true

    embeds_one :settings, Settings, on_replace: :update

    has_many :podcast_hosts, PodcastHost, on_delete: :delete_all

    has_many :episode_hosts, EpisodeHost, on_delete: :delete_all
    has_many :host_episodes, through: [:episode_hosts, :episode]

    has_many :episode_guests, EpisodeGuest, on_delete: :delete_all
    has_many :guest_episodes, through: [:episode_guests, :episode]

    has_many :authored_posts, Post, foreign_key: :author_id, on_delete: :delete_all

    has_many :authored_news_items, NewsItem, foreign_key: :author_id, on_delete: :nilify_all
    has_many :logged_news_items, NewsItem, foreign_key: :logger_id, on_delete: :nilify_all
    has_many :submitted_news_items, NewsItem, foreign_key: :submitter_id, on_delete: :nilify_all

    has_many :comments, NewsItemComment, foreign_key: :author_id
    has_many :subscriptions, Subscription, where: [unsubscribed_at: nil], on_delete: :delete_all
    has_many :episode_requests, EpisodeRequest, foreign_key: :submitter_id, on_delete: :delete_all

    timestamps()
  end

  def admins(query \\ __MODULE__), do: from(q in query, where: q.admin)
  def editors(query \\ __MODULE__), do: from(q in query, where: q.editor)
  def hosts(query \\ __MODULE__), do: from(q in query, where: q.host)

  def spammy(query \\ __MODULE__) do
    from(q in query, where: not is_nil(q.bio) or not is_nil(q.website))
    |> joined()
    |> not_in_slack()
    |> no_subs()
    |> not_a_guest()
  end

  def in_slack(query \\ __MODULE__), do: from(q in query, where: not is_nil(q.slack_id))
  def not_in_slack(query \\ __MODULE__), do: from(q in query, where: is_nil(q.slack_id))

  def joined(query \\ __MODULE__), do: from(a in query, where: not is_nil(a.joined_at))
  def never_signed_in(query \\ __MODULE__), do: from(q in query, where: is_nil(q.signed_in_at))

  def not_a_guest(query \\ __MODULE__) do
    from(q in query,
      left_join: g in EpisodeGuest,
      on: [person_id: q.id],
      where: is_nil(g.id)
    )
  end

  def no_subs(query \\ __MODULE__) do
    from(q in query,
      left_join: s in Subscription,
      on: [person_id: q.id],
      where: is_nil(s.id)
    )
  end

  def faked(query \\ __MODULE__), do: from(q in query, where: q.name in ^Changelog.Faker.names())

  def with_avatar(query \\ __MODULE__), do: from(q in query, where: not is_nil(q.avatar))

  def with_handles(query \\ __MODULE__, handles),
    do: from(q in query, where: q.handle in ^handles)

  def with_public_profile(query \\ __MODULE__),
    do: from(q in query, where: q.public_profile, where: q.name not in ^Changelog.Faker.names())

  def with_email(query \\ __MODULE__, email)
  def with_email(query, email) when is_list(email), do: from(q in query, where: q.email in ^email)
  def with_email(query, email), do: from(q in query, where: q.email == ^email)

  def joined_today(query \\ __MODULE__) do
    today = Timex.subtract(Timex.now(), Timex.Duration.from_days(1))
    from(p in query, where: p.joined_at > ^today)
  end

  def get_by_encoded_auth(token) do
    case __MODULE__.decoded_data(token) do
      {:ok, [email, auth_token]} -> Repo.get_by(__MODULE__, email: email, auth_token: auth_token)
      _else -> nil
    end
  end

  def get_by_encoded_id(token) do
    case __MODULE__.decoded_data(token) do
      {:ok, [id, email]} -> Repo.get_by(__MODULE__, id: id, email: email)
      _else -> nil
    end
  end

  def get_by_ueberauth(%{provider: :twitter, info: %{nickname: handle}}) do
    Repo.get_by(__MODULE__, twitter_handle: handle)
  end

  def get_by_ueberauth(%{provider: :github, info: %{nickname: handle}}) do
    Repo.get_by(__MODULE__, github_handle: handle)
  end

  def get_by_ueberauth(_), do: nil

  def get_by_website(url) do
    try do
      from(q in __MODULE__, where: fragment("? ~* website", ^url))
      |> Repo.all()
      |> List.first()
    rescue
      Postgrex.Error -> nil
    end
  end

  def auth_changeset(person, attrs \\ %{}),
    do: cast(person, attrs, ~w(auth_token auth_token_expires_at)a)

  def admin_insert_changeset(person, attrs \\ %{}) do
    allowed =
      ~w(name email handle github_handle linkedin_handle mastodon_handle twitter_handle bio website location admin host editor public_profile approved)a

    changeset_with_allowed_attrs(person, attrs, allowed)
  end

  def admin_update_changeset(person, attrs \\ %{}) do
    person
    |> admin_insert_changeset(attrs)
    |> file_changeset(attrs)
  end

  def file_changeset(person, attrs \\ %{}),
    do: cast_attachments(person, attrs, [:avatar], allow_urls: true)

  def insert_changeset(person, attrs \\ %{}) do
    allowed =
      ~w(name email handle github_handle linkedin_handle mastodon_handle twitter_handle bio website location public_profile)a

    changeset_with_allowed_attrs(person, attrs, allowed)
  end

  def update_changeset(person, attrs \\ %{}) do
    person
    |> insert_changeset(attrs)
    |> file_changeset(attrs)
  end

  def approve_commenter_changeset(person) do
    change(person, approved: true)
  end

  def revoke_commenter_changeset(person) do
    change(person, approved: false)
  end

  defp changeset_with_allowed_attrs(person, attrs, allowed) do
    person
    |> cast(attrs, allowed)
    |> cast_embed(:settings)
    |> validate_required([:name, :email, :handle])
    |> validate_format(:email, Regexp.email(), message: Regexp.email_message())
    |> validate_format(:website, Regexp.http(), message: Regexp.http_message())
    |> validate_format(:handle, Regexp.slug(), message: Regexp.slug_message())
    |> validate_length(:handle, max: 40, message: "max 40 chars")
    |> validate_format(:github_handle, Regexp.social(), message: Regexp.social_message())
    |> validate_format(:linkedin_handle, Regexp.social(), message: Regexp.social_message())
    |> validate_format(:mastodon_handle, Regexp.email(), message: Regexp.email_message())
    |> validate_format(:twitter_handle, Regexp.social(), message: Regexp.social_message())
    |> validate_handle_allowed()
    |> unique_constraint(:email)
    |> unique_constraint(:handle)
    |> unique_constraint(:github_handle)
    |> unique_constraint(:linkedin_handle)
    |> unique_constraint(:mastodon_handle)
    |> unique_constraint(:twitter_handle)
  end

  defp validate_handle_allowed(changeset) do
    handle = get_field(changeset, :handle)

    if Enum.member?(Changelog.BlockKit.handles(), handle) do
      add_error(changeset, :handle, "not allowed")
    else
      changeset
    end
  end

  def sign_in_changes(person) do
    change(person, %{
      auth_token: nil,
      auth_token_expires_at: nil,
      signed_in_at: now_in_seconds(),
      joined_at: person.joined_at || now_in_seconds()
    })
  end

  def slack_changes(person, slack_id) do
    change(person, %{slack_id: slack_id})
  end

  def refresh_auth_token(person, expires_in \\ 60 * 24) do
    auth_token = Base.encode16(:crypto.strong_rand_bytes(8))
    expires_at = Timex.add(Timex.now(), Timex.Duration.from_minutes(expires_in))

    changeset =
      auth_changeset(person, %{auth_token: auth_token, auth_token_expires_at: expires_at})

    {:ok, person} = Repo.update(changeset)
    person
  end

  def encoded_auth(person), do: {:ok, Base.encode16("#{person.email}|#{person.auth_token}")}
  def encoded_id(person), do: {:ok, Base.encode16("#{person.id}|#{person.email}")}

  def decoded_data(encoded) do
    case Base.decode16(encoded) do
      {:ok, decoded} -> {:ok, String.split(decoded, "|")}
      :error -> {:error, ["", ""]}
    end
  end

  def post_count(person) do
    person
    |> Post.authored_by()
    |> Post.published()
    |> Repo.count()
  end

  def episode_count(person) do
    person
    |> participating_episode_ids()
    |> Episode.with_ids()
    |> Episode.published()
    |> Repo.count()
  end

  def news_item_count(person) do
    person
    |> NewsItem.with_person()
    |> NewsItem.published()
    |> Repo.count()
  end

  def participating_episode_ids(person) do
    hostings =
      person
      |> Repo.preload(:episode_hosts)
      |> Map.get(:episode_hosts)
      |> Enum.map(& &1.episode_id)

    guestings =
      person
      |> Repo.preload(:episode_guests)
      |> Map.get(:episode_guests)
      |> Enum.map(& &1.episode_id)

    hostings ++ guestings
  end

  def podcast_subscription_count(person) do
    Subscription
    |> Subscription.for_person(person)
    |> Subscription.to_podcast()
    |> Repo.count()
  end

  def preload_subscriptions(query = %Ecto.Query{}), do: Ecto.Query.preload(query, :subscriptions)
  def preload_subscriptions(person), do: Repo.preload(person, :subscriptions)

  def with_fake_data(person \\ %__MODULE__{}) do
    fake_name = Faker.name()
    fake_handle = Faker.handle(fake_name)
    %{person | name: fake_name, handle: fake_handle, public_profile: false}
  end

  def sans_fake_data(person) do
    if Faker.name_fake?(person.name) do
      %{person | name: nil, handle: nil}
    else
      person
    end
  end
end
