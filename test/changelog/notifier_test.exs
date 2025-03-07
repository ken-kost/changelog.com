defmodule Changelog.NotifierTest do
  use Changelog.SchemaCase
  use Bamboo.Test
  use Oban.Testing, repo: Changelog.Repo

  import Mock

  alias Changelog.{Notifier, Slack, Subscription, NewsItem, EpisodeRequest}
  alias ChangelogWeb.Email

  describe "notify/1 with news item comment" do
    setup_with_mocks([
      {Slack.Client, [], [message: fn _, _ -> true end]}
    ]) do
      :ok
    end

    test "when comment is not approved" do
      admin = insert(:person, email: "jerod@changelog.com")
      comment = insert(:news_item_comment, approved: false)
      Notifier.notify(comment)
      assert_delivered_email(Email.comment_approval(admin, comment))
    end

    test "when comment has no parent or subscribers" do
      comment = insert(:news_item_comment)
      Notifier.notify(comment)
      assert_no_emails_delivered()
      assert called(Slack.Client.message("#news-comments", :_))
    end

    test "when comment has subscriber who is also commenter" do
      item = insert(:news_item)
      commenter = insert(:person)
      Subscription.subscribe(commenter, item)
      comment = insert(:news_item_comment, news_item: item, author: commenter)
      Notifier.notify(comment)
      assert_no_emails_delivered()
      assert called(Slack.Client.message("#news-comments", :_))
    end

    test "when comment has no parent but 2 subscribers" do
      item = insert(:news_item)
      sub1 = insert(:subscription_on_item, item: item)
      sub2 = insert(:subscription_on_item, item: item)
      comment = insert(:news_item_comment, news_item: item)
      Notifier.notify(comment)
      assert_delivered_email(Email.comment_subscription(sub1, comment))
      assert_delivered_email(Email.comment_subscription(sub2, comment))
      assert called(Slack.Client.message("#news-comments", :_))
    end

    test "when comment has no parents but 2 muted subscribers" do
      item = insert(:news_item)
      sub1 = insert(:subscription_on_item, item: item)
      sub2 = insert(:subscription_on_item, item: item)
      comment = insert(:news_item_comment, news_item: item)
      Subscription.unsubscribe(sub1.person, item)
      Subscription.unsubscribe(sub2.person, item)
      Notifier.notify(comment)
      assert_no_emails_delivered()
      assert called(Slack.Client.message("#news-comments", :_))
    end

    test "when a comment mentions 3 people, 1 of which has mention notifications disabled" do
      p1 = insert(:person, handle: "p1")
      p2 = insert(:person, handle: "p2")
      p3 = insert(:person, handle: "p3", settings: %{email_on_comment_mentions: false})
      comment = insert(:news_item_comment, content: "Yo @p1 @p2 and @p3 what up!")
      Notifier.notify(comment)
      assert_delivered_email(Email.comment_mention(p1, comment))
      assert_delivered_email(Email.comment_mention(p2, comment))
      refute_delivered_email(Email.comment_mention(p3, comment))
    end

    test "when comment is a reply and author has notifications enabled" do
      comment = insert(:news_item_comment)
      reply = insert(:news_item_comment, news_item: comment.news_item, parent: comment)
      Notifier.notify(reply)
      assert_delivered_email(Email.comment_reply(reply.parent.author, reply))
      assert called(Slack.Client.message("#news-comments", :_))
    end

    test "when comment is a reply and parent is also subscribed" do
      parent = insert(:person)
      item = insert(:news_item)
      sub = insert(:subscription_on_item, person: parent, item: item)
      comment = insert(:news_item_comment, news_item: item, author: parent)
      reply = insert(:news_item_comment, news_item: item, parent: comment)
      Notifier.notify(reply)
      assert_delivered_email(Email.comment_reply(parent, reply))
      refute_delivered_email(Email.comment_subscription(sub, reply))
      assert called(Slack.Client.message("#news-comments", :_))
    end

    test "when comment is a reply and parent is subscribed and 2 mentions" do
      parent = insert(:person, handle: "person1")
      mentioned = insert(:person, handle: "person2")
      item = insert(:news_item)
      sub = insert(:subscription_on_item, person: parent, item: item)
      comment = insert(:news_item_comment, news_item: item, author: parent)

      reply =
        insert(:news_item_comment,
          news_item: item,
          parent: comment,
          content: "Thanks @person1 @person2!"
        )

      Notifier.notify(reply)
      assert_delivered_email(Email.comment_reply(parent, reply))
      assert_delivered_email(Email.comment_mention(mentioned, reply))
      refute_delivered_email(Email.comment_mention(parent, reply))
      refute_delivered_email(Email.comment_subscription(sub, reply))
      assert called(Slack.Client.message("#news-comments", :_))
    end

    test "when comment is a reply and parent has notifications enabled but discussion muted" do
      parent = insert(:person)
      item = insert(:news_item)
      Subscription.unsubscribe(parent, item)
      comment = insert(:news_item_comment, news_item: item, author: parent)
      reply = insert(:news_item_comment, news_item: item, parent: comment)
      Notifier.notify(reply)
      assert_no_emails_delivered()
      assert called(Slack.Client.message("#news-comments", :_))
    end

    test "when comment is a reply and parent author has notifications disabled" do
      person = insert(:person, settings: %{email_on_comment_replies: false})
      comment = insert(:news_item_comment, author: person)
      reply = insert(:news_item_comment, news_item: comment.news_item, parent: comment)
      Notifier.notify(reply)
      assert_no_emails_delivered()
      assert called(Slack.Client.message("#news-comments", :_))
    end

    test "when comment is a reply to own comment" do
      person = insert(:person)
      comment = insert(:news_item_comment, author: person)

      reply =
        insert(:news_item_comment, news_item: comment.news_item, parent: comment, author: person)

      Notifier.notify(reply)
      assert_no_emails_delivered()
      assert called(Slack.Client.message("#news-comments", :_))
    end
  end

  describe "notify/1 with episode item" do
    setup_with_mocks([
      {Slack.Client, [], [message: fn _, _ -> true end]},
      {Changelog.PodPing, [], [overcast: fn _ -> true end]}
    ]) do
      :ok
    end

    test "when episode has no guests" do
      episode = insert(:published_episode)
      item = episode |> episode_news_item() |> insert()
      Notifier.notify(item)
      assert_no_emails_delivered()
      assert called(Slack.Client.message("#main", :_))
      assert called(Changelog.PodPing.overcast(:_))
    end

    test "when episode has guests but none of them have 'thanks' set" do
      g1 = insert(:person)
      g2 = insert(:person)
      episode = insert(:published_episode)
      insert(:episode_guest, episode: episode, person: g1, thanks: false)
      insert(:episode_guest, episode: episode, person: g2, thanks: false)
      item = episode |> episode_news_item() |> insert()

      Notifier.notify(item)
      assert_no_emails_delivered()
      assert called(Slack.Client.message("#main", :_))
      assert called(Changelog.PodPing.overcast(:_))
    end

    test "when episode has guests and some of them have 'thanks' set" do
      g1 = insert(:person)
      g2 = insert(:person)
      g3 = insert(:person)
      episode = insert(:published_episode)
      insert(:episode_guest, episode: episode, person: g1, thanks: false)
      eg1 = insert(:episode_guest, episode: episode, person: g2, thanks: true)
      eg2 = insert(:episode_guest, episode: episode, person: g3, thanks: true)
      item = episode |> episode_news_item() |> insert()

      Notifier.notify(item)
      assert_delivered_email(Email.guest_thanks(eg1))
      assert_delivered_email(Email.guest_thanks(eg2))
      assert called(Slack.Client.message("#main", :_))
      assert called(Changelog.PodPing.overcast(:_))
    end

    test "when episode was requested" do
      podcast = insert(:podcast)
      submitter = insert(:person)
      request = insert(:episode_request, podcast: podcast, submitter: submitter)
      episode = insert(:published_episode, podcast: podcast, episode_request: request)
      item = episode |> episode_news_item() |> insert()

      Notifier.notify(item)
      assert_delivered_email(Email.episode_request_published(request))
    end

    test "when episode was requested by a guest on the episode" do
      podcast = insert(:podcast)
      submitter = insert(:person)
      request = insert(:episode_request, podcast: podcast, submitter: submitter)
      episode = insert(:published_episode, podcast: podcast, episode_request: request)
      insert(:episode_guest, episode: episode, person: submitter, thanks: false)
      item = episode |> episode_news_item() |> insert()

      Notifier.notify(item)
      assert_no_emails_delivered()
    end

    test "when podcast has subscriptions" do
      podcast = insert(:podcast)
      s1 = insert(:subscription_on_podcast, podcast: podcast)
      s2 = insert(:subscription_on_podcast, podcast: podcast)
      s3 = insert(:unsubscribed_subscription_on_podcast, podcast: podcast)
      episode = insert(:published_episode, podcast: podcast)
      item = episode |> episode_news_item() |> insert()
      Notifier.notify(item)

      assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :email)

      assert_delivered_email(Email.episode_published(s1, episode))
      assert_delivered_email(Email.episode_published(s2, episode))
      refute_delivered_email(Email.episode_published(s3, episode))
    end
  end

  describe "notify/1 with regular item" do
    test "when item has no submitter or author" do
      item = insert(:news_item)
      Notifier.notify(item)
      assert_no_emails_delivered()
    end

    test "when submitter has email notifications enabled" do
      person = insert(:person, settings: %{email_on_submitted_news: true})
      item = insert(:news_item, submitter: person)
      Notifier.notify(item)
      assert_delivered_email(Email.submitted_news_published(item))
    end

    test "when submitter has email notifications disabled" do
      person = insert(:person, settings: %{email_on_submitted_news: false})
      item = insert(:news_item, submitter: person)
      Notifier.notify(item)
      assert_no_emails_delivered()
    end

    test "when submitter has news item declined with message" do
      person = insert(:person, settings: %{email_on_submitted_news: true})
      item = insert(:news_item, submitter: person)
      item = NewsItem.decline!(item, "decline reason")
      Notifier.notify(item)
      assert_delivered_email(Email.submitted_news_declined(item))
    end

    test "when submitter has news item declined sans message" do
      person = insert(:person, settings: %{email_on_submitted_news: true})
      item = insert(:news_item, submitter: person)
      item = NewsItem.decline!(item, "")
      Notifier.notify(item)
      assert_no_emails_delivered()
    end

    test "when submitter and author are same person, notifications enabled" do
      person = insert(:person, settings: %{email_on_submitted_news: true})
      item = insert(:news_item, submitter: person, author: person)
      Notifier.notify(item)
      assert_delivered_email(Email.submitted_news_published(item))
      refute_delivered_email(Email.authored_news_published(item))
    end

    test "when author has email notifications enabled" do
      person = insert(:person, settings: %{email_on_authored_news: true})
      item = insert(:news_item, author: person)
      Notifier.notify(item)
      assert_delivered_email(Email.authored_news_published(item))
    end

    test "when author has email notifications disabled" do
      person = insert(:person, settings: %{email_on_authored_news: false})
      item = insert(:news_item, author: person)
      Notifier.notify(item)
      assert_no_emails_delivered()
    end

    test "when submitter and author both have notifications enabled" do
      submitter = insert(:person, settings: %{email_on_submitted_news: true})
      author = insert(:person, settings: %{email_on_authored_news: true})
      item = insert(:news_item, author: author, submitter: submitter)
      Notifier.notify(item)
      assert_delivered_email(Email.authored_news_published(item))
      assert_delivered_email(Email.submitted_news_published(item))
    end
  end

  describe "notify/1 with feed-only item" do
    test "nobody is notified" do
      item = insert(:news_item, feed_only: true)
      Notifier.notify(item)
      assert_no_emails_delivered()
    end
  end

  describe "notify/1 with an episode" do
    test "when episode has no transcript subscriptions" do
      hardcoded = insert(:person, email: "jerod@changelog.com")
      episode = insert(:episode)
      Notifier.notify(episode)
      assert_delivered_email(Email.episode_transcribed(hardcoded, episode))
    end

    test "when episode has transcript subscriptions" do
      hardcoded = insert(:person, email: "adam@changelog.com")
      episode = insert(:episode)
      s1 = insert(:subscription_on_episode, episode: episode)
      s2 = insert(:subscription_on_episode, episode: episode)
      s3 = insert(:unsubscribed_subscription_on_episode, episode: episode)
      Notifier.notify(episode)
      assert_delivered_email(Email.episode_transcribed(hardcoded, episode))
      assert_delivered_email(Email.episode_transcribed(s1.person, episode))
      assert_delivered_email(Email.episode_transcribed(s2.person, episode))
      refute_delivered_email(Email.episode_transcribed(s3.person, episode))
    end
  end

  describe "notify/1 with an episode request" do
    test "when episode request is declined with a message" do
      person = insert(:person, settings: %{email_on_submitted_news: true})
      request = insert(:episode_request, submitter: person)
      request = EpisodeRequest.decline!(request, "decline reason")
      Notifier.notify(request)
      assert_delivered_email(Email.episode_request_declined(request))
    end

    test "when episode request is declined without a message" do
      person = insert(:person, settings: %{email_on_submitted_news: true})
      item = insert(:episode_request, submitter: person)
      item = EpisodeRequest.decline!(item, "")
      Notifier.notify(item)
      assert_no_emails_delivered()
    end

    test "when episode request is failed with a message" do
      person = insert(:person, settings: %{email_on_submitted_news: true})
      request = insert(:episode_request, submitter: person)
      request = EpisodeRequest.fail!(request, "fail reason")
      Notifier.notify(request)
      assert_delivered_email(Email.episode_request_failed(request))
    end

    test "when episode request is failed without a message" do
      person = insert(:person, settings: %{email_on_submitted_news: true})
      item = insert(:episode_request, submitter: person)
      item = EpisodeRequest.fail!(item, "")
      Notifier.notify(item)
      assert_no_emails_delivered()
    end
  end
end
