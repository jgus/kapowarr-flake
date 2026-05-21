{
  description = "Kapowarr: comic book library manager (Casvt/Kapowarr).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    bencoding = {
      url = "github:jgus/bencoding-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, bencoding }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pin = import ./pin.nix;
        inherit (pin) version sourceRev sourceHash;
        pkgs = import nixpkgs { inherit system; };
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
        update-version = pkgs.writeShellApplication {
          name = "update-version";
          # python3.withPackages can't be expressed as a shebang flake spec
          runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.packaging ])) ];
          text = ''exec ${./update-version.sh} "$@"'';
        };
        update-branches = pkgs.writeShellApplication {
          name = "update-branches";
          text = ''exec ${./update-branches.sh} "$@"'';
        };
      in
      {
        packages = {
          inherit kapowarr update-version update-branches;
          default = kapowarr;
        };
      });
}
