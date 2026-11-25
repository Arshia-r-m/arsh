#!/usr/bin/env bash
# deploy.sh: pull-based deployer for the arsh static site.
#
# The server pulls the public repo over HTTPS; GitHub never connects to the
# server and holds no secrets for it. See deploy/README.md.
#
# Usage:
#   deploy.sh deploy          Fetch main and deploy it now (even if unchanged).
#   deploy.sh poll            Fetch main; deploy only if main has moved.
#                             This is what the systemd timer runs.
#   deploy.sh rollback [SHA]  Serve an older release (default: the previous one).
#                             Sticks until main moves again.
#   deploy.sh status          Show what is live and what main points to.
#   deploy.sh check [REV]     Validate the site content of a git revision in the
#                             current checkout (default HEAD). Used by CI.
#
# Environment (all optional):
#   ARSH_REPO_URL  default https://github.com/Arshia-r-m/arsh.git
#   ARSH_BRANCH    default main
#   ARSH_ROOT      default $HOME/Services/arsh-site
#   ARSH_KEEP      releases to keep, default 5
#
# SECURITY: the server must run an installed copy of this script
# ($ARSH_ROOT/bin/deploy.sh), never the copy inside a fetched checkout.
# Otherwise anyone who can merge to main could run code on the server.

set -Eeuo pipefail
umask 022
export LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1

REPO_URL=${ARSH_REPO_URL:-https://github.com/Arshia-r-m/arsh.git}
BRANCH=${ARSH_BRANCH:-main}
ROOT=${ARSH_ROOT:-$HOME/Services/arsh-site}
KEEP=${ARSH_KEEP:-5}

GIT_DIR_PATH="$ROOT/repo.git"   # bare mirror, not served
STATE="$ROOT/state"             # last-main, history; not served
SITE="$ROOT/site"               # the only directory Caddy mounts (read-only)
RELEASES="$SITE/releases"
CURRENT="$SITE/current"         # relative symlink -> releases/<sha>

# Repo paths that are never published.
EXCLUDES=(.github deploy README.md LICENSE .gitignore .gitattributes)

# Validation limits.
ALLOWED_EXT='html|css|txt|xml|png|jpg|jpeg|gif|webp|avif|svg|ico|woff|woff2'
MAX_FILE_BYTES=$((10 * 1024 * 1024))
MAX_TOTAL_BYTES=$((100 * 1024 * 1024))

TMP_PATHS=()
cleanup() { (( ${#TMP_PATHS[@]} )) && rm -rf -- "${TMP_PATHS[@]}"; return 0; }
trap cleanup EXIT

log() { printf '%s [arsh-deploy] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

git_() { git --git-dir="$GIT_DIR_PATH" -c protocol.allow=never -c protocol.https.allow=always "$@"; }

# --- validation -------------------------------------------------------------

# validate_dir DIR: reject anything that is not plain, small, script-free
# static content. Runs in CI and again on the server before going live.
validate_dir() {
  local dir=$1 bad total
  [[ -f "$dir/index.html" ]] || die "index.html missing"

  bad=$(find "$dir" -mindepth 1 ! -type f ! -type d -printf '%P\n')
  [[ -z "$bad" ]] || die "symlinks or special files are not allowed:"$'\n'"$bad"

  bad=$(find "$dir" -mindepth 1 -printf '%P\n' | grep -Ev '^[A-Za-z0-9_][A-Za-z0-9._/-]*$' ; \
        find "$dir" -mindepth 1 -printf '%P\n' | grep -E '(^|/)\.' ; true)
  [[ -z "$bad" ]] || die "bad or hidden file names:"$'\n'"$bad"

  bad=$(find "$dir" -type f -printf '%P\n' | grep -Eiv "\.($ALLOWED_EXT)$" || true)
  [[ -z "$bad" ]] || die "file types not allowed:"$'\n'"$bad"

  bad=$(find "$dir" -type f -size +"${MAX_FILE_BYTES}"c -printf '%P\n')
  [[ -z "$bad" ]] || die "files over $MAX_FILE_BYTES bytes:"$'\n'"$bad"

  total=$(find "$dir" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
  (( total <= MAX_TOTAL_BYTES )) || die "site is $total bytes, limit $MAX_TOTAL_BYTES"

  # No JavaScript: script tags, inline event handlers, javascript: URLs.
  bad=$(find "$dir" -type f \( -iname '*.html' -o -iname '*.svg' -o -iname '*.xml' \) -print0 |
        xargs -0 -r grep -EilI '<script|<[^>]*[[:space:]]on[a-z]+[[:space:]]*=|javascript:' || true)
  [[ -z "$bad" ]] || die "JavaScript found in:"$'\n'"${bad//$dir\//}"

  log "validation passed ($total bytes)"
}

# export_rev REV DEST: write the publishable tree of REV into DEST.
export_rev() {
  local rev=$1 dest=$2 spec=(.) e
  for e in "${EXCLUDES[@]}"; do spec+=(":(exclude,top)$e"); done
  "${@:3}" archive --format=tar "$rev" -- "${spec[@]}" |
    tar -x --no-same-owner --no-same-permissions -C "$dest"
}

# --- server side -------------------------------------------------------------

init_dirs() {
  mkdir -p "$STATE" "$RELEASES"
  if [[ ! -d "$GIT_DIR_PATH" ]]; then
    git init --quiet --bare "$GIT_DIR_PATH"
    git_ remote add origin "$REPO_URL"
  fi
  [[ $(git_ remote get-url origin) == "$REPO_URL" ]] || git_ remote set-url origin "$REPO_URL"
  [[ "$REPO_URL" == https://* ]] || die "ARSH_REPO_URL must be https://"
}

fetch_main() {
  git_ fetch --quiet --no-tags --prune origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" \
    || die "git fetch failed"
  git_ rev-parse --verify --quiet "refs/remotes/origin/$BRANCH^{commit}" || die "branch $BRANCH not found"
}

live_sha() { [[ -L "$CURRENT" ]] && basename "$(readlink "$CURRENT")" || true; }

# activate SHA: atomically point current at releases/SHA.
activate() {
  local sha=$1 tmp="$SITE/.current.$$"
  ln -sfn "releases/$sha" "$tmp"
  mv -Tf "$tmp" "$CURRENT"
  echo "$(date '+%F %T') $sha" >> "$STATE/history"
  log "live: $sha"
}

# build SHA: export, validate, and store as releases/SHA (immutable per SHA).
build() {
  local sha=$1 tmp
  if [[ -d "$RELEASES/$sha" ]]; then
    log "release $sha already built"
    return
  fi
  tmp=$(mktemp -d "$RELEASES/.build.XXXXXX")
  TMP_PATHS+=("$tmp")
  export_rev "$sha" "$tmp" git_
  validate_dir "$tmp"
  find "$tmp" -type d -exec chmod 755 {} + ; find "$tmp" -type f -exec chmod 644 {} +
  chmod 755 "$tmp"
  mv -T "$tmp" "$RELEASES/$sha"
  log "built release $sha"
}

prune() {
  local live keep_n=0 d
  live=$(live_sha)
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    keep_n=$((keep_n + 1))
    if (( keep_n > KEEP )) && [[ "$d" != "$live" ]]; then
      rm -rf -- "${RELEASES:?}/$d"
      log "pruned $d"
    fi
  done < <(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %f\n' | sort -rn | cut -d' ' -f2)
}

with_lock() {
  local mode=$1; shift
  mkdir -p "$ROOT"
  exec 9>"$ROOT/.lock"
  if [[ $mode == wait ]]; then
    flock -w 120 9 || die "another deploy is still running"
  else
    flock -n 9 || { log "another deploy is running, skipping"; exit 0; }
  fi
  "$@"
}

do_deploy() {
  local force=$1 sha last
  init_dirs
  sha=$(fetch_main)
  last=$(cat "$STATE/last-main" 2>/dev/null || true)
  if [[ $force == no && "$sha" == "$last" ]]; then
    return 0   # main has not moved: nothing to do, stay quiet
  fi
  log "$BRANCH: ${last:-none} -> $sha"
  build "$sha"
  activate "$sha"
  echo "$sha" > "$STATE/last-main"
  prune
}

do_rollback() {
  local target=${1:-} live
  live=$(live_sha)
  if [[ -z "$target" ]]; then
    target=$(awk '{print $3}' "$STATE/history" 2>/dev/null | grep -vx "$live" | tail -n1 || true)
    [[ -n "$target" ]] || die "no previous release to roll back to"
  fi
  [[ "$target" =~ ^[0-9a-f]{40}$ ]] || die "rollback needs a full 40-char SHA"
  [[ -d "$RELEASES/$target" ]] || die "release $target is not on disk (see: ls $RELEASES)"
  activate "$target"
  log "rolled back; stays until $BRANCH moves again"
}

do_status() {
  echo "live:      $(live_sha || true)"
  echo "last-main: $(cat "$STATE/last-main" 2>/dev/null || echo none)"
  if [[ -d "$GIT_DIR_PATH" ]]; then
    echo "$BRANCH now: $(git_ ls-remote origin "refs/heads/$BRANCH" | cut -f1)"
  fi
  echo "releases:"; ls -1t "$RELEASES" 2>/dev/null | sed 's/^/  /'
}

do_check() {
  local rev=${1:-HEAD} tmp
  tmp=$(mktemp -d)
  TMP_PATHS+=("$tmp")
  export_rev "$rev" "$tmp" git
  validate_dir "$tmp"
}

case ${1:-} in
  deploy)   with_lock wait do_deploy yes ;;
  poll)     with_lock nowait do_deploy no ;;
  rollback) with_lock wait do_rollback "${2:-}" ;;
  status)   do_status ;;
  check)    do_check "${2:-}" ;;
  *)        sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
