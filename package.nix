# Sure — self-hosted personal finance manager
# Derivation for the Sure Rails application (we-promise/sure).
#
# Prerequisites (run scripts/update-gemset.sh after changing versions):
#   Gemfile, Gemfile.lock, gemset.nix — all must be present in this directory.
#   They are generated from the upstream source at the target version; see
#   scripts/update-gemset.sh for instructions.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  ruby_3_4,       # Sure requires Ruby 3.4.x (.ruby-version: 3.4.7; nixpkgs provides 3.4.8)
  bundlerEnv,
  defaultGemConfig,
  nodejs,
  makeWrapper,
  # Native build deps for gems with C extensions
  pkg-config,
  libxml2,
  libxslt,
  libffi,
  zlib,
  openssl,
  postgresql,
  # For patching the prebuilt tailwindcss binary to use NixOS glibc paths
  patchelf,
  glibc,
}:

let
  ruby = ruby_3_4;
  pname = "sure";
  version = "0.6.9";

  # tailwindcss-ruby (source gem) ships no binary; it looks for the Tailwind CLI
  # in its exe/ dir, falling back to TAILWINDCSS_INSTALL_DIR.  Fetch the matching
  # platform gem to extract the Bun-bundled binary for asset precompilation.
  # To update: nix-prefetch-url https://rubygems.org/gems/tailwindcss-ruby-<VER>-<PLATFORM>.gem
  twVersion = "4.1.8";

  twPlatformInfo = {
    "aarch64-linux" = {
      gemPlatform = "aarch64-linux-gnu";
      sha256      = "17b983ag5ffvsmsrvdaqmy4z6w9zrdvqj73fxpsbdmrdfshfbc5k";
      ldSo        = "ld-linux-aarch64.so.1";
    };
    "x86_64-linux" = {
      gemPlatform = "x86_64-linux-gnu";
      sha256      = "048k95b39v6iy519xxs2jm3k272ry1cmx58vq5fx55qf2vkb5324";
      ldSo        = "ld-linux-x86-64.so.2";
    };
  }.${stdenv.hostPlatform.system};

  tailwindcssGem = fetchurl {
    url    = "https://rubygems.org/gems/tailwindcss-ruby-${twVersion}-${twPlatformInfo.gemPlatform}.gem";
    sha256 = twPlatformInfo.sha256;
  };

  # Sure's Gemfile uses `ruby file: ".ruby-version"` which requires the file to
  # be co-located with the Gemfile.  Since bundlerEnv's gemfile-and-lockfile
  # derivation only copies Gemfile + Gemfile.lock, we remove the ruby-version
  # directive entirely.  nixpkgs provides ruby_3_4 = 3.4.8 but upstream pins
  # 3.4.7; the two-way mismatch (validate_ruby! vs frozen-mode lockfile check)
  # means neither patching to 3.4.7 nor 3.4.8 works — removing the directive
  # tells Bundler to skip the version check altogether.
  patchedGemfile = builtins.toFile "Gemfile"
    (lib.replaceStrings
      [ "ruby file: \".ruby-version\"\n" ]
      [ "" ]
      (builtins.readFile ./Gemfile));

  # bundlerEnv reads Gemfile, Gemfile.lock, and gemset.nix from gemdir.
  # These files must be co-located with package.nix in this flake.
  gems = bundlerEnv {
    name = "${pname}-${version}-gems";
    inherit ruby;
    gemfile  = patchedGemfile;
    lockfile = ./Gemfile.lock;
    gemset   = ./gemset.nix;
    # Gems with native extensions need their build inputs declared here.
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ libxml2 libxslt libffi zlib openssl postgresql ];
    # Use nixpkgs default gem config for common C-extension gems (nokogiri, ffi, etc.)
    gemConfig = defaultGemConfig;
  };

in
stdenv.mkDerivation {
  inherit pname version;

  src = fetchFromGitHub {
    owner = "we-promise";
    repo  = "sure";
    rev   = "v${version}";
    # Run: nix-prefetch-github we-promise sure --rev v0.6.9
    # then paste the sha256 here.
    hash  = "sha256-+X6rZutuh7esyTZLyaHATQtf8MDxE2BgdsAzWjV3HW8=";
  };

  nativeBuildInputs = [ makeWrapper nodejs patchelf ];
  buildInputs = [ gems ruby ];

  # Rails 7+ requires SECRET_KEY_BASE for asset precompilation.
  # A dummy value is safe here; the real one is only needed at runtime.
  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR
    export RAILS_ENV=production
    export SECRET_KEY_BASE=build-placeholder-not-used-at-runtime
    export DATABASE_URL=postgresql:///placeholder
    # The lockfile contains aarch64-linux-gnu platform entries (from upstream's
    # Docker-based release process) but bundlerEnv only installs source gems.
    # Force bundler to select the ruby-platform (source) variant at runtime.
    export BUNDLE_FORCE_RUBY_PLATFORM=1

    # tailwindcss-ruby source gem has no binary; extract from the platform gem
    # and point TAILWINDCSS_INSTALL_DIR at it for the asset compilation step.
    # Extract the platform gem and patch the Bun-bundled binary for NixOS.
    # The binary uses /lib/ld-linux-*.so.* which doesn't exist on NixOS;
    # patch the interpreter and supply glibc + libstdc++ via LD_LIBRARY_PATH.
    TWDIR=$TMPDIR/tailwindcss
    mkdir -p "$TWDIR"
    tar -xf ${tailwindcssGem} -C "$TWDIR"
    tar -xzf "$TWDIR/data.tar.gz" -C "$TWDIR"
    chmod +x "$TWDIR/exe/${twPlatformInfo.gemPlatform}/tailwindcss"
    patchelf \
      --set-interpreter "${glibc}/lib/${twPlatformInfo.ldSo}" \
      "$TWDIR/exe/${twPlatformInfo.gemPlatform}/tailwindcss"
    export LD_LIBRARY_PATH="${glibc}/lib:${stdenv.cc.cc.lib}/lib"
    export TAILWINDCSS_INSTALL_DIR="$TWDIR/exe/${twPlatformInfo.gemPlatform}"

    # Precompile assets into public/assets
    bundle exec rails assets:precompile

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    appDir=$out/share/sure
    mkdir -p $appDir

    # Copy app (precompiled assets included)
    cp -r . $appDir

    # Thin wrappers so systemd ExecStart lines stay short.
    # Each wrapper sets RAILS_ENV=production and switches to the app dir.
    # At runtime the module passes secrets via EnvironmentFile.
    mkdir -p $out/bin

    # Do NOT override BUNDLE_GEMFILE: the bundlerEnv bundle wrapper already
    # sets it to the nix-store gemfile-and-lockfile path (source gems only).
    # Overriding it with $appDir/Gemfile would point to the upstream lockfile
    # which contains aarch64-linux-gnu platform entries that bundler can't
    # satisfy in frozen mode.  BUNDLE_FORCE_RUBY_PLATFORM forces the ruby
    # (source) gem variant even when the lockfile lists platform variants.
    makeWrapper ${gems}/bin/bundle $out/bin/sure-web \
      --add-flags "exec puma" \
      --set    RAILS_ENV production \
      --set    BUNDLE_FORCE_RUBY_PLATFORM 1 \
      --chdir  "$appDir"

    makeWrapper ${gems}/bin/bundle $out/bin/sure-worker \
      --add-flags "exec sidekiq" \
      --set    RAILS_ENV production \
      --set    BUNDLE_FORCE_RUBY_PLATFORM 1 \
      --chdir  "$appDir"

    makeWrapper ${gems}/bin/bundle $out/bin/sure-rails \
      --add-flags "exec rails" \
      --set    RAILS_ENV production \
      --set    BUNDLE_FORCE_RUBY_PLATFORM 1 \
      --chdir  "$appDir"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Sure — self-hosted personal finance manager (we-promise/sure)";
    homepage    = "https://github.com/we-promise/sure";
    license     = licenses.agpl3Only;
    platforms   = [ "x86_64-linux" "aarch64-linux" ];
    maintainers = [];
  };
}
