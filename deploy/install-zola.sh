#!/usr/bin/env bash
# Download a pinned Zola release, verify its SHA-256, and put it on PATH.
# Used by CI only (the server never builds). To upgrade: change both values,
# taking the digest from the release page or:
#   gh api repos/getzola/zola/releases/tags/<version> --jq '.assets[].digest'
set -euo pipefail

ZOLA_VERSION=v0.23.6
ZOLA_SHA256=8f5132b3522412d04e395e0b25f6d68613ad272a873e54a2b3ebf664873024a4

dest=${RUNNER_TEMP:-/tmp}/zola-bin
tarball="$dest/zola.tar.gz"
mkdir -p "$dest"
curl -fsSL --proto '=https' --tlsv1.2 -o "$tarball" \
  "https://github.com/getzola/zola/releases/download/${ZOLA_VERSION}/zola-${ZOLA_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
echo "${ZOLA_SHA256}  ${tarball}" | sha256sum -c -
tar -xzf "$tarball" -C "$dest" zola
"$dest/zola" --version
if [[ -n "${GITHUB_PATH:-}" ]]; then echo "$dest" >> "$GITHUB_PATH"; fi
