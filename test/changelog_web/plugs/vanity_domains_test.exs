defmodule ChangelogWeb.VanityDomainsTest do
  use ChangelogWeb.ConnCase

  alias ChangelogWeb.Plug.VanityDomains

  @jsparty %{
    vanity_domain: "https://jsparty.fm",
    slug: "jsparty",
    apple_url: "https://podcasts.apple.com/us/podcast/js-party/id1209616598",
    name: "JS Party",
    riverside_url: "https://riverside.fm/studio/js-to-the-party"
  }
  @gotime %{
    vanity_domain: "https://gotime.fm",
    slug: "gotime",
    spotify_url: "https://spotify.com",
    name: "Go Time"
  }

  def assert_vanity_redirect(conn, path_or_url_or_regex) do
    location = conn |> get_resp_header("location") |> List.first()
    assert conn.status == 302

    cond do
      # regex case
      !is_binary(path_or_url_or_regex) -> assert String.match?(location, path_or_url_or_regex)
      # path case
      String.starts_with?(path_or_url_or_regex, "http") -> assert location == path_or_url_or_regex
      # url case
      true -> assert location == "https://#{ChangelogWeb.Endpoint.host()}#{path_or_url_or_regex}"
    end
  end

  def build_conn_with_host_and_path(host, path) do
    conn = build_conn(:get, path)
    %Plug.Conn{conn | host: host}
  end

  def assign_podcasts(conn, podcasts) do
    assign(conn, :podcasts, podcasts)
  end

  test "vanity redirects for root path" do
    conn =
      build_conn_with_host_and_path("jsparty.fm", "/")
      |> assign_podcasts([@jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, "/jsparty")
  end

  test "vanity redirects for episode sub-paths" do
    conn =
      build_conn_with_host_and_path("gotime.fm", "/102")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, "/gotime/102")
  end

  test "vanity redirects for ++ URL" do
    conn =
      build_conn_with_host_and_path("jsparty.fm", "/++")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, Application.get_env(:changelog, :plusplus_url))
  end

  test "vanity redirects for apple URL" do
    conn =
      build_conn_with_host_and_path("jsparty.fm", "/apple")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, @jsparty.apple_url)
  end

  test "vanity redirects for spotify URL" do
    conn =
      build_conn_with_host_and_path("gotime.fm", "/spotify")
      |> assign_podcasts([@gotime, @gotime])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, @gotime.spotify_url)
  end

  test "vanity redirects for overcast URL" do
    conn =
      build_conn_with_host_and_path("jsparty.fm", "/overcast")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, "https://overcast.fm/itunes1209616598/js-party")
  end

  test "vanity redirects for RSS URL" do
    conn =
      build_conn_with_host_and_path("gotime.fm", "/rss")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, "/gotime/feed")
  end

  test "vanity redirects for email URL" do
    conn =
      build_conn_with_host_and_path("jsparty.fm", "/email")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, "/subscribe/jsparty")
  end

  test "vanity redirects for request URL" do
    conn =
      build_conn_with_host_and_path("gotime.fm", "/request")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, "/request/gotime")
  end

  test "vanity redirects for community URL" do
    conn =
      build_conn_with_host_and_path("jsparty.fm", "/community")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, "/community")
  end

  test "vanity redirect for studio URL" do
    conn =
      build_conn_with_host_and_path("jsparty.fm", "/studio")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, @jsparty.riverside_url)
  end

  test "vanity redirects for guest guide" do
    conn =
      build_conn_with_host_and_path("jsparty.fm", "/guest")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, "/guest/jsparty")
  end

  test "vanity redirects for typeforms" do
    conn =
      build_conn_with_host_and_path("jsparty.fm", "/ff")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, ~r/changelog\.typeform\.com\/.*/)

    conn =
      build_conn_with_host_and_path("gotime.fm", "/gs")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, ~r/changelog\.typeform\.com\/.*/)
  end

  test "vanity redirects for merch" do
    conn =
      build_conn_with_host_and_path("gotime.fm", "/merch")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    assert_vanity_redirect(conn, "https://merch.changelog.com")
  end

  test "it does not vanity redirect for default host" do
    conn =
      build_conn_with_host_and_path(ChangelogWeb.Endpoint.host(), "/")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    vanity_redirect = conn |> get_resp_header("x-changelog-vanity-redirect")
    assert vanity_redirect == ["false"]
  end

  test "it does not vanity redirect for default host subdomain" do
    conn =
      build_conn_with_host_and_path("21.#{ChangelogWeb.Endpoint.host()}", "/")
      |> assign_podcasts([@gotime, @jsparty])
      |> VanityDomains.call([])

    vanity_redirect = conn |> get_resp_header("x-changelog-vanity-redirect")
    assert vanity_redirect == ["false"]
  end

  test "it no-ops for other hosts" do
    conn =
      :get
      |> build_conn("")
      |> VanityDomains.call([])

    assert conn.status == nil
  end
end
