{
  description = "OCI images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs = { nixpkgs-lib.follows = "nixpkgs"; };
    };

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs = { nixpkgs.follows = "nixpkgs"; };
    };
  };

  outputs = inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.git-hooks-nix.flakeModule ];

      systems = [ "x86_64-linux" ];
      perSystem = { system, config, lib, pkgs, ... }: {
        pre-commit.settings.hooks = {
          deadnix.enable = true;
          nixfmt-classic.enable = true;
        };
        devShells.default = pkgs.mkShell {
          shellHook = ''
            ${config.pre-commit.installationScript}
          '';
        };

        packages = import ./images { inherit pkgs; };

        apps = let imageNames = builtins.attrNames self.packages."${system}";
        in {
          docker-size-summary = {
            type = "app";
            program = (pkgs.writeShellScript "" (let
              name = "temporary";
              tag = "analysis";
            in ''
              declare -i FAILED=0

              FILTER="$1"

              ${lib.strings.concatStringsSep "\n" (map (val: ''
                if [[ -x "$FILTER" || "${val}" =~ $FILTER ]]; then
                  # Build image
                  IMAGE_STREAM=$(nix build --print-out-paths --no-link .#packages.${system}.${val})

                  # Load image to registry
                  $IMAGE_STREAM --repo_tag "${name}:${tag}" 2>/dev/null | docker image load -q > /dev/null

                  # Fetch size
                  SIZE=$(docker inspect -f "{{ .Size }}" ${name}:${tag} | ${pkgs.coreutils}/bin/numfmt --to=si)
                  if [[ $? -ne 0 ]]; then
                      ((++FAILED))
                  fi

                  # Cleanup
                  docker image rm ${name}:${tag} > /dev/null
                  nix store delete $IMAGE_STREAM > /dev/null 2>&1

                  echo "${val}" - $SIZE
                fi
              '') imageNames)}

              if [[ $FAILED -ne 0 ]]; then
                exit 1
              fi
            '')).outPath;
          };
        };
      };
    };
}
