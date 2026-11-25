# unico.quest

Arsh's personal site: plain HTML and one stylesheet, built from Markdown with
[Zola](https://www.getzola.org/). No JavaScript, no trackers, no cookies.

## Write a post

Add a file to `content/posts/`, e.g. `content/posts/my-post.md`:

```md
+++
title = "My post"
date = 2026-12-01
description = "One sentence for the post list, search engines and the feed."
[taxonomies]
tags = ["bitcoin", "freedom"]
+++

Text in **Markdown**. Links, lists, `code`, > quotes, tables, footnotes[^1].

[^1]: Like this.
```

Open a PR. CI builds the site and attaches a `site-preview` download to the
run. Merge it, and it is live within about two minutes.

The file name becomes the URL (`/posts/my-post/`). Every post needs a `date`.
Images go next to the post: make a folder `content/posts/my-post/` with an
`index.md` and the images, then link them as `![alt](photo.jpg)`.

## Preview locally

```sh
zola serve        # http://127.0.0.1:1111, rebuilds on save
```

## Layout

| Path | What |
|---|---|
| `templates/index.html` | The home page (hand-written HTML) |
| `templates/base.html` | Shared head, header and colophon |
| `templates/post.html`, `posts.html`, `tags/` | Post page, post list, tag pages |
| `templates/404.html` | Not-found page |
| `static/` | Copied as is: `style.css`, fonts |
| `content/posts/` | The posts |
| `config.toml` | Zola settings |
| `deploy/` | How the server publishes the site (see `deploy/README.md`) |

Rules the build enforces (it fails otherwise): no `<script>`, no `on…=`
attributes, no `javascript:` URLs, only static file types.
