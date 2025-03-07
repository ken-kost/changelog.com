defmodule ChangelogWeb.Admin.PageController do
  use ChangelogWeb, :controller

  alias Changelog.{
    Cache,
    Episode,
    EpisodeRequest,
    EpisodeStat,
    Person,
    Podcast,
    Subscription
  }

  plug Authorize, Policies.Admin.Page

  def index(conn = %{assigns: %{current_user: %{admin: true}}}, _params) do
    conn
    |> assign(:email_lists, email_lists())
    |> assign(:episode_drafts, episode_drafts())
    |> assign(:episode_requests, episode_requests(EpisodeRequest.limit(5)))
    |> assign(:members, members())
    |> assign(:podcasts, Cache.podcasts())
    |> assign(:downloads, downloads())
    |> render(:index)
  end

  def index(conn = %{assigns: %{current_user: %{host: true}}}, _params) do
    redirect(conn, to: Routes.admin_podcast_path(conn, :index))
  end

  def index(conn = %{assigns: %{current_user: %{editor: true}}}, _params) do
    redirect(conn, to: Routes.admin_news_item_path(conn, :index))
  end

  def fresh_requests(conn, _params) do
    conn
    |> assign(:episode_requests, episode_requests())
    |> render(:fresh_requests)
  end

  def purge(conn, _params) do
    Cache.delete_all()

    conn
    |> put_flash(:result, "success")
    |> redirect(to: Routes.admin_page_path(conn, :index))
  end

  def downloads(conn, params) do
    podcast = Repo.get_by(Podcast, slug: Map.get(params, "podcast", "nope"))
    range = params |> Map.get("range", "now_7") |> String.to_existing_atom()
    dates = EpisodeStat.download_dates(range)
    minimum = Map.get(params, "min", "10") |> String.to_integer()

    episodes =
      if podcast do
        EpisodeStat.date_range_episode_downloads(podcast, dates, minimum)
      else
        EpisodeStat.date_range_episode_downloads(dates, minimum)
      end
      |> Enum.map(fn stat ->
        Episode
        |> Repo.get(stat.episode_id)
        |> Episode.preload_podcast()
        |> Map.put(:focused, stat.downloads)
      end)

    conn
    |> assign(:podcast, podcast)
    |> assign(:dates, dates)
    |> assign(:episodes, episodes)
    |> render(:downloads)
  end

  defp email_lists do
    now = Timex.now()
    today_start = Timex.subtract(now, Timex.Duration.from_days(1))
    week_start = Timex.subtract(now, Timex.Duration.from_days(7))
    month_start = Timex.subtract(now, Timex.Duration.from_days(28))

    Enum.map(Cache.podcasts(), fn pod ->
      {
        pod,
        {Subscription.subscribed_count(pod, now, today_start), Subscription.unsubscribed_count(pod, now, today_start)},
        {Subscription.subscribed_count(pod, now, week_start), Subscription.unsubscribed_count(pod, now, week_start)},
        {Subscription.subscribed_count(pod, now, month_start), Subscription.unsubscribed_count(pod, now, month_start)},
        Subscription.subscribed_count(pod)
      }
    end)
    |> Enum.sort_by(fn {_pod, _day, _week, {up, down}, _total} -> up - down end, :desc)
  end

  defp episode_drafts do
    Episode.unpublished()
    |> Episode.newest_last(:recorded_at)
    |> Episode.distinct_podcast()
    |> Episode.preload_episode_request()
    |> Episode.preload_podcast()
    |> Repo.all()
  end

  defp episode_requests(query \\ EpisodeRequest) do
    query
    |> EpisodeRequest.fresh()
    |> EpisodeRequest.sans_episode()
    |> EpisodeRequest.newest_first()
    |> EpisodeRequest.preload_all()
    |> Repo.all()
  end

  defp members do
    %{
      today: Repo.count(Person.joined_today()),
      slack: Repo.count(Person.in_slack()),
      spam: Repo.count(Person.spammy()),
      total: Repo.count(Person.joined())
    }
  end

  def downloads do
    now = Timex.today() |> Timex.shift(days: -1)

    Cache.get_or_store("stats-downloads-#{now}", fn ->
      %{
        as_of: Timex.now(),
        now_7: EpisodeStat.date_range_downloads(:now_7),
        now_30: EpisodeStat.date_range_downloads(:now_30),
        now_90: EpisodeStat.date_range_downloads(:now_90),
        now_year: EpisodeStat.date_range_downloads(:now_year),
        prev_7: EpisodeStat.date_range_downloads(:prev_7),
        prev_30: EpisodeStat.date_range_downloads(:prev_30),
        prev_90: EpisodeStat.date_range_downloads(:prev_90),
        prev_year: EpisodeStat.date_range_downloads(:prev_year),
        then_7: EpisodeStat.date_range_downloads(:then_7),
        then_30: EpisodeStat.date_range_downloads(:then_30),
        then_90: EpisodeStat.date_range_downloads(:then_90)
      }
    end)
  end
end
