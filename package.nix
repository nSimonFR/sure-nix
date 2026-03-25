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
  ruby,
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
}:

let
  pname = "sure";
  version = "0.6.8";

  # bundlerEnv reads Gemfile, Gemfile.lock, and gemset.nix from gemdir.
  # These files must be co-located with package.nix in this flake.
  gems = bundlerEnv {
    name = "${pname}-${version}-gems";
    inherit ruby;
    gemdir = ./.;
    # .ruby-version must be co-located with Gemfile; Sure's Gemfile has `ruby file: ".ruby-version"`
    extraConfigPaths = [ ./.ruby-version ];
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
    # Run: nix-prefetch-github we-promise sure --rev v0.6.8
    # then paste the sha256 here.
    hash  = "sha256-CvvZnCdB/l6xwMD+SrhA594/95jBoQ9uxsJwpwYlVgc=";
  };

  nativeBuildInputs = [ makeWrapper nodejs ];
  buildInputs = [ gems ruby ];

  # Rails 7+ requires SECRET_KEY_BASE for asset precompilation.
  # A dummy value is safe here; the real one is only needed at runtime.
  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR
    export RAILS_ENV=production
    export SECRET_KEY_BASE=build-placeholder-not-used-at-runtime
    export DATABASE_URL=postgresql:///placeholder

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

    makeWrapper ${gems}/bin/bundle $out/bin/sure-web \
      --add-flags "exec puma" \
      --set    RAILS_ENV production \
      --set    BUNDLE_GEMFILE "$appDir/Gemfile" \
      --chdir  "$appDir"

    makeWrapper ${gems}/bin/bundle $out/bin/sure-worker \
      --add-flags "exec sidekiq" \
      --set    RAILS_ENV production \
      --set    BUNDLE_GEMFILE "$appDir/Gemfile" \
      --chdir  "$appDir"

    makeWrapper ${gems}/bin/bundle $out/bin/sure-rails \
      --add-flags "exec rails" \
      --set    RAILS_ENV production \
      --set    BUNDLE_GEMFILE "$appDir/Gemfile" \
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
