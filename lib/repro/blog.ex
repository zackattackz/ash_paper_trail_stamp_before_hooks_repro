defmodule Repro.Blog do
  use Ash.Domain, otp_app: :repro

  resources do
    resource Repro.Blog.Post
    resource Repro.Blog.Post.Version
    resource Repro.Blog.Page
    resource Repro.Blog.Page.Version
  end
end
