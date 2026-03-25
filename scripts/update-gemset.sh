#!/usr/bin/env bash
# update-gemset.sh — Regenerate Gemfile, Gemfile.lock, .ruby-version, gemset.nix,
# and update the src hash in package.nix for a given Sure version.
#
# Usage: ./scripts/update-gemset.sh [VERSION]
# Example: ./scripts/update-gemset.sh 0.6.8
#
# Requires: nix (with flakes), git, perl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$SCRIPT_DIR")"

VERSION="${1:-0.6.8}"
OWNER="we-promise"
REPO="sure"

echo "==> Fetching Sure v${VERSION} source..."
CLONEDIR="$(mktemp -d)"
trap 'rm -rf "$CLONEDIR"' EXIT

git clone --depth=1 --branch "v${VERSION}" \
  "https://github.com/${OWNER}/${REPO}.git" "$CLONEDIR/sure"

echo "==> Copying Gemfile, Gemfile.lock, and .ruby-version..."
cp "$CLONEDIR/sure/Gemfile"        "$FLAKE_DIR/Gemfile"
cp "$CLONEDIR/sure/Gemfile.lock"   "$FLAKE_DIR/Gemfile.lock"
cp "$CLONEDIR/sure/.ruby-version"  "$FLAKE_DIR/.ruby-version"

echo "==> Running bundix (with nil-fix) to generate gemset.nix..."

# Resolve bundix from the system nix store (fast — uses cached build).
BUNDIX_STORE="$(nix build --print-out-paths --no-link 'nixpkgs#bundix' 2>/dev/null)"
WRAPPER="$BUNDIX_STORE/bin/.bundix-wrapped"

# Create a patched wrapper: copy the original, then inject our nil-fix module
# between gem activation and the final `load`.
# The original ends with: load Gem.activate_bin_path("bundix", "bundix", "2.5.0")
# We split that into: activate → require bundix → prepend nil-fix → load binary.
RUNSCRIPT="$(mktemp --suffix=.rb)"
trap 'rm -f "$RUNSCRIPT"' RETURN
sed 's|^load Gem\.activate_bin_path\(.*\)$|BUNDIX_BIN__ = Gem.activate_bin_path\1; require "bundix"; Bundix::Nixer.prepend(Module.new { def serialize; obj.nil? ? "null" : super; end }); ENV["BUNDLE_FORCE_RUBY_PLATFORM"] = "1"; load BUNDIX_BIN__|' \
  "$WRAPPER" > "$RUNSCRIPT"
chmod +x "$RUNSCRIPT"

(cd "$FLAKE_DIR" && "$RUNSCRIPT")

echo "==> Fixing platform-specific gem hashes in gemset.nix..."
# bundix on aarch64 hashes platform gems (e.g. ffi-1.17.2-aarch64-linux-gnu.gem)
# but bundlerEnv downloads and verifies the source gem (ffi-1.17.2.gem).
# Post-process gemset.nix: replace each platform gem's hash with the source gem hash.
while IFS= read -r line; do
  GEM="$(echo "$line" | grep -oP '^\s+\K[a-zA-Z0-9_-]+')"
  [ -z "$GEM" ] && continue
  # Get version from gemset.nix (the source/non-platform entry)
  GEM_VERSION="$(grep -A6 "^  ${GEM} = {" "$FLAKE_DIR/gemset.nix" | grep 'version =' | grep -oP '"[^"]+"' | tr -d '"')"
  [ -z "$GEM_VERSION" ] && continue
  CORRECT_HASH="$(nix-prefetch-url --type sha256 "https://rubygems.org/gems/${GEM}-${GEM_VERSION}.gem" 2>/dev/null)"
  [ -z "$CORRECT_HASH" ] && continue
  # Replace the sha256 in the gem's block
  OLD_HASH="$(grep -A6 "^  ${GEM} = {" "$FLAKE_DIR/gemset.nix" | grep 'sha256 =' | grep -oP '"[^"]+"' | tr -d '"')"
  [ -z "$OLD_HASH" ] || [ "$OLD_HASH" = "$CORRECT_HASH" ] && continue
  echo "    ${GEM} ${GEM_VERSION}: ${OLD_HASH} → ${CORRECT_HASH}"
  sed -i "s/${OLD_HASH}/${CORRECT_HASH}/" "$FLAKE_DIR/gemset.nix"
done < <(grep "aarch64-linux-gnu\|aarch64-linux-musl" "$FLAKE_DIR/Gemfile.lock" | grep -oP '^\s+\K[a-zA-Z0-9_-]+' | sort -u)

echo "==> Computing src hash for package.nix..."
HASH="$(nix run nixpkgs#nix-prefetch-github -- \
  --rev "v${VERSION}" "$OWNER" "$REPO" 2>/dev/null | \
  nix run nixpkgs#jq -- -r '.hash')"

echo "==> Patching hash and version in package.nix..."
sed -i "s|version = \"[^\"]*\";|version = \"${VERSION}\";|" "$FLAKE_DIR/package.nix"
sed -i "s|hash  = \"[^\"]*\";|hash  = \"${HASH}\";|"       "$FLAKE_DIR/package.nix"

echo ""
echo "Done. Files updated:"
echo "  Gemfile, Gemfile.lock, .ruby-version, gemset.nix, package.nix"
echo ""
echo "Commit with:"
echo "  git add Gemfile Gemfile.lock .ruby-version gemset.nix package.nix"
echo "  git commit -m 'chore: update Sure to v${VERSION}'"
