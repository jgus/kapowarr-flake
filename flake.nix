{
  description = "Kapowarr: comic book library manager (Casvt/Kapowarr).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-lib = {
      url = "github:jgus/flake-lib/v1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    bencoding = {
      url = "github:jgus/bencoding-flake/v0.2";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
      inputs.flake-lib.follows = "flake-lib";
    };
  };

  outputs = { self, nixpkgs, flake-utils, flake-lib, bencoding }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pin = import ./pin.nix;
        inherit (pin) version sourceRev sourceHash;
        pkgs = import nixpkgs { inherit system; };
        source = { type = "github"; owner = "Casvt"; repo = "Kapowarr"; };
        bencoding-pkg = bencoding.packages.${system}.bencoding;
        python = pkgs.python3.withPackages (ps: with ps; [
          typing-extensions
          requests
          pysocks
          beautifulsoup4
          flask
          waitress
          cryptography
          bencoding-pkg
          aiohttp
          flask-socketio
          simple-websocket
          websocket-client
        ]);
        kapowarr = pkgs.stdenv.mkDerivation {
          pname = "kapowarr";
          inherit version;
          src = pkgs.fetchFromGitHub {
            owner = "Casvt";
            repo = "Kapowarr";
            rev = sourceRev;
            hash = sourceHash;
          };
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib/kapowarr $out/bin
            cp -r . $out/lib/kapowarr/
            makeWrapper ${python}/bin/python3 $out/bin/kapowarr \
              --add-flags "$out/lib/kapowarr/Kapowarr.py"
            runHook postInstall
          '';
          meta.mainProgram = "kapowarr";
        };
      in
      {
        packages = {
          inherit kapowarr;
          default = kapowarr;
          update-version = flake-lib.lib.mkUpdateVersion {
            inherit pkgs source;
            buildAttr = "kapowarr";
            # Upstream requirements.txt pins bencoding with a range; resolve to the matching bencoding-flake aggregate.
            siblings = [{
              reqName = "bencoding";
              pypiName = "bencoding";
              flakeRepo = "jgus/bencoding-flake";
              mode = "resolve";
            }];
          };
          update-branches = flake-lib.lib.mkUpdateBranches {
            inherit pkgs source;
            pinSchema = "github";
            # flake.nix is branch-owned because the cascade rewrites the bencoding URL.
            branchOwnedFiles = [ "pin.nix" "flake.lock" "flake.nix" ];
          };
        };
      });
}
