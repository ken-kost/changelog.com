defmodule ChangelogWeb.HomeController do
  use ChangelogWeb, :controller

  alias Changelog.{Fastly, NewsItem, Person, Podcast, Slack, StringKit, Subscription}

  plug(RequireUser, "except from email links" when action not in [:opt_out])
  plug(:scrub_params, "person" when action in [:update])

  def show(conn, %{"subscribed" => id}),
    do: render(conn, :show, subscribed: id, unsubscribed: nil)

  def show(conn, %{"unsubscribed" => id}),
    do: render(conn, :show, subscribed: nil, unsubscribed: id)

  def show(conn, _params), do: render(conn, :show, subscribed: nil, unsubscribed: nil)

  def account(conn = %{assigns: %{current_user: me}}, _params) do
    render(conn, :account, changeset: Person.update_changeset(me))
  end

  def profile(conn = %{assigns: %{current_user: me}}, _params) do
    render(conn, :profile, changeset: Person.update_changeset(me))
  end

  def update(conn = %{assigns: %{current_user: me}}, %{"person" => person_params, "from" => from}) do
    changeset =
      if Changelog.Policies.Person.profile(me, me) do
        Person.update_changeset(me, person_params)
      else
        Person.update_changeset(me, Map.delete(person_params, "public_profile"))
      end

    case Repo.update(changeset) do
      {:ok, person} ->
        Fastly.purge(person)

        conn
        |> put_flash(:success, "Your #{from} has been updated! ✨")
        |> redirect(to: Routes.home_path(conn, :show))

      {:error, changeset} ->
        conn
        |> put_flash(:error, "The was a problem updating your #{from}. 😢")
        |> render(String.to_existing_atom(from), person: me, changeset: changeset)
    end
  end

  def subscribe(conn = %{assigns: %{current_user: me}}, %{"id" => id}) do
    if StringKit.is_integer(id) do
      podcast = Repo.get(Podcast, id)
      context = "you subscribed in your changelog.com settings"
      Subscription.subscribe(me, podcast, context)
    else
      Craisin.Subscriber.subscribe(id, Person.sans_fake_data(me))
    end

    conn
    |> put_flash(:success, "You're subscribed! You'll get the next issue in your inbox 📥")
    |> redirect(to: Routes.home_path(conn, :show, subscribed: id))
  end

  def subscribe(conn = %{assigns: %{current_user: me}}, %{"slug" => slug}) do
    podcast = Podcast.get_by_slug!(slug)
    context = "you enabled notifications in your changelog.com settings"
    Subscription.subscribe(me, podcast, context)
    send_resp(conn, 200, "")
  end

  def unsubscribe(conn = %{assigns: %{current_user: me}}, %{"id" => id}) do
    if StringKit.is_integer(id) do
      podcast = Repo.get(Podcast, id)
      Subscription.unsubscribe(me, podcast)
    else
      Craisin.Subscriber.unsubscribe(id, me.email)
    end

    conn
    |> put_flash(:success, "You're no longer subscribed. Resubscribe any time 🤗")
    |> redirect(to: Routes.home_path(conn, :show, unsubscribed: id))
  end

  def unsubscribe(conn = %{assigns: %{current_user: me}}, %{"slug" => slug}) do
    podcast = Podcast.get_by_slug!(slug)
    Subscription.unsubscribe(me, podcast)
    send_resp(conn, 200, "")
  end

  def slack(conn = %{assigns: %{current_user: me}}, _params) do
    {updated_user, flash} =
      case Slack.Client.invite(me.email) do
        %{"ok" => true} ->
          {set_slack_id(me), "Invite sent! Check your email 🎯"}

        %{"ok" => false, "error" => "already_in_team"} ->
          {set_slack_id(me), "You're on the team! We'll see you in there ✊"}

        %{"ok" => false, "error" => error} ->
          {me, "Hmm, Slack is saying '#{error}' 🤔"}
      end

    conn
    |> assign(:current_user, updated_user)
    |> put_flash(:success, flash)
    |> redirect(to: Routes.home_path(conn, :show))
  end

  def opt_out(conn = %{method: "GET"}, %{"token" => token, "type" => type, "id" => id}) do
    conn
    |> assign(:token, token)
    |> assign(:type, type)
    |> assign(:id, id)
    |> render(:opt_out)
  end

  def opt_out(conn, %{"token" => token, "type" => type, "id" => id}) do
    person = Person.get_by_encoded_id(token)

    case type do
      "news" -> opt_out_news(conn, person, id)
      "podcast" -> opt_out_podcast(conn, person, id)
      "setting" -> opt_out_setting(conn, person, id)
    end
  end

  defp opt_out_news(conn, person, id) do
    item = Repo.get!(NewsItem, id)
    Subscription.unsubscribe(person, item)

    conn
    |> put_flash(:success, "You've muted this discussion. 🤐")
    |> redirect(to: Routes.news_item_path(conn, :show, NewsItem.slug(item)))
  end

  defp opt_out_podcast(conn, person, slug) do
    podcast = Podcast.get_by_slug!(slug)
    Subscription.unsubscribe(person, podcast)

    conn
    |> put_flash(:success, "You're unsubscribed! Resubscribe any time 🤗")
    |> redirect(to: Routes.podcast_path(conn, :show, podcast.slug))
  end

  defp opt_out_setting(conn, person, setting) do
    if Person.Settings.is_valid(setting) do
      person
      |> Person.update_changeset(%{settings: %{setting => false}})
      |> Repo.update()
    end

    render(conn, :opted_out)
  end

  defp set_slack_id(person) do
    if person.slack_id do
      person
    else
      {:ok, person} = Repo.update(Person.slack_changes(person, "pending"))
      person
    end
  end
end
