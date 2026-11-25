# Deploying unico.quest

The site is deployed by **pulling**: a timer on the server checks GitHub's
`main` every 2 minutes and, if `main` has moved, publishes the new commit.
GitHub never connects to the server and holds no secrets for it. The repo is
public, so fetching needs no credentials either.

```
PR ──► CI "validate" ──► merge to main (ruleset) ──► timer on server
                                                         │ git fetch (HTTPS, read-only)
                                                         ▼
                                     validate again ─► releases/<sha>/ ─► current ─► Caddy
```

## Commands

Run as the normal user (no root needed):

| Command | What it does |
|---|---|
| `~/Services/arsh-site/bin/deploy.sh deploy` | Fetch `main` and deploy it **now** |
| `~/Services/arsh-site/bin/deploy.sh poll` | Deploy only if `main` moved (what the timer runs) |
| `~/Services/arsh-site/bin/deploy.sh status` | What is live vs. what `main` is |
| `~/Services/arsh-site/bin/deploy.sh rollback [SHA]` | Serve the previous (or given) release until `main` moves again |
| `systemctl --user start arsh-deploy.service` | Trigger a poll right now through systemd |
| `journalctl --user -u arsh-deploy.service` | Deploy logs |

## How it works

- **`deploy/deploy.sh`** keeps a bare copy of the repo in
  `~/Services/arsh-site/repo.git` and fetches `main` over HTTPS. It compares the
  commit with `state/last-main`. If they match, `poll` exits quietly. If they
  differ (or you ran `deploy`), it:
  1. exports the commit with `git archive`, leaving out `deploy/`, `.github/`,
     `README.md` and other repo-only files, and never `.git`;
  2. **validates** it: `index.html` must exist; only static file types are
     allowed; no symlinks, hidden files, oversized files, `<script>`, `on…=`
     handlers or `javascript:` URLs;
  3. stores it as `site/releases/<sha>/` (files 644, dirs 755);
  4. atomically repoints the symlink `site/current` to it, so visitors never
     see a half-copied site;
  5. keeps the newest 5 releases for rollback.

  If any step fails, the old site stays live and the error goes to the journal.
  A lock file stops two deploys from overlapping.
- **systemd** is the program that starts and supervises services on Debian.
  `arsh-deploy.timer` starts `arsh-deploy.service` 1 min after boot and then
  every 2 minutes. These are *user* units in `~/.config/systemd/user/`: they
  run as you, not root, and keep running while you are logged out because
  lingering is enabled (`loginctl show-user $USER -p Linger`). The service is
  sandboxed: it can write only to `~/Services/arsh-site`.
- **Caddy** (in Docker, `~/Services/caddy`) mounts `~/Services/arsh-site/site`
  **read-only** at `/srv/arsh` and serves `/srv/arsh/current` for
  `unico.quest`, with automatic HTTPS and a strict CSP header
  (`deploy/caddy/arsh.Caddyfile`). It mounts the parent directory, not the
  symlink, because Docker resolves a mounted symlink once, at container start.
- **CI** (`.github/workflows/validate.yml`) runs the same `check` on every PR.
  Make it a required status check in the `main` ruleset.

### Security notes

- The server runs an **installed copy** of the script
  (`~/Services/arsh-site/bin/deploy.sh`), never the copy from a fetched commit.
  A merged PR can change the site but cannot run code on the server. When
  `deploy/` changes in this repo, review it and re-install it by hand (below).
- The server re-validates every commit itself, so a weakened check in a PR
  cannot get scripts published.
- Only `https://` fetches are allowed. Commit signatures are not checked: trust
  comes from the `main` ruleset.

## Install / update on the server

```sh
# 1. Install the reviewed script (repeat whenever deploy/ changes)
install -D -m 755 deploy/deploy.sh ~/Services/arsh-site/bin/deploy.sh

# 2. First deploy
~/Services/arsh-site/bin/deploy.sh deploy

# 3. Caddy: add the volume to ~/Services/caddy/compose.yml
#      - ../arsh-site/site:/srv/arsh:ro
#    append deploy/caddy/arsh.Caddyfile to ~/Services/caddy/Caddyfile, then
cd ~/Services/caddy && docker compose up -d   # recreates caddy with the new mount

# 4. Timer
install -D -m 644 deploy/systemd/arsh-deploy.{service,timer} -t ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now arsh-deploy.timer
```

DNS: `unico.quest` must point at the server (same address as `vault.unico.quest`).

## Roll back the whole setup

```sh
systemctl --user disable --now arsh-deploy.timer
rm ~/.config/systemd/user/arsh-deploy.{service,timer}; systemctl --user daemon-reload
# remove the unico.quest block and the /srv/arsh volume from ~/Services/caddy, then:
cd ~/Services/caddy && docker compose up -d
rm -r ~/Services/arsh-site
```
