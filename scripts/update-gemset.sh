#!/usr/bin/env bash
# update-gemset.sh — Regenerate Gemfile, Gemfile.lock, and gemset.nix
# from the upstream Sure source at a given version tag.
#
# Run this whenever upgrading Sure or when gemset.nix is missing.
# Requires: nix (with bundix), git, nix-prefetch-github

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$SCRIPT_DIR")"

VERSION="${1:-0.6.8}"
OWNER="we-promise"
REPO="sure"

echo "==> Fetching Sure v${VERSION} source..."
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

git clone --depth=1 --branch "v${VERSION}" \
  "https://github.com/${OWNER}/${REPO}.git" "$TMPDIR/sure"

echo "==> Copying Gemfile and Gemfile.lock..."
cp "$TMPDIR/sure/Gemfile"      "$FLAKE_DIR/Gemfile"
cp "$TMPDIR/sure/Gemfile.lock" "$FLAKE_DIR/Gemfile.lock"

echo "==> Running bundix to generate gemset.nix..."
(cd "$FLAKE_DIR" && nix run nixpkgs#bundix)

echo "==> Computing src hash for package.nix..."
HASH="$(nix run nixpkgs#nix-prefetch-github -- \
  --rev "v${VERSION}" "$OWNER" "$REPO" 2>/dev/null | \
  nix run nixpkgs#jq -- -r '.hash')"

echo ""
echo "Update package.nix src.hash to:"
echo "  hash = \"${HASH}\";"
echo ""
echo "Done. Commit Gemfile, Gemfile.lock, gemset.nix, and the updated package.nix."
