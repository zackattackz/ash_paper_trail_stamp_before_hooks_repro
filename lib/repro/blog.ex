defmodule Repro.Blog do
  use Ash.Domain, otp_app: :repro, extensions: [AshJsonApi.Domain]

  resources do
    resource Repro.Blog.Author
    resource Repro.Blog.Post
    resource Repro.Blog.Post.Version
    resource Repro.Blog.DiffPost
    resource Repro.Blog.DiffPost.Version
    resource Repro.Blog.Page
    resource Repro.Blog.Page.Version
  end
end
