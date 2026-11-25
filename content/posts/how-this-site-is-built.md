+++
title = "How this site is built"
date = 2026-11-25
description = "Markdown in a public repo, built by Zola, pulled by my own server. No JavaScript anywhere."
[taxonomies]
tags = ["meta", "self-hosting"]
+++

This site is plain HTML and one stylesheet. There is no JavaScript, and the
page tells your browser to refuse any: look for `Content-Security-Policy` in
the source.

## Writing

Each post is a Markdown file in
[the repo](https://github.com/Arshia-r-m/arsh), under `content/posts/`.
[Zola](https://www.getzola.org/) turns them into HTML, along with the post
list, the tag pages and the [feed](/atom.xml).

## Publishing

1. A change goes in through a pull request. CI builds the site and rejects
   anything with scripts in it.
2. When the pull request is merged, CI builds again and pushes the HTML to a
   separate `site` branch.
3. My server checks that branch every two minutes, checks the files itself,
   and swaps the new version in atomically.

GitHub never logs in to the server. The server only reads a public repo.
