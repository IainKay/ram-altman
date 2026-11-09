{
  description = "Track RAM usage and, at most once a day, tell Sam Altman when this PC has RAM to spare";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # The script reads /proc/meminfo, so it only runs on Linux.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkRamAltman =
        pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "ram-altman";
          version = "unstable";

          src = ./.;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            install -Dm755 ram-altman.sh "$out/bin/ram-altman"

            # The script calls awk, coreutils and flock. Keep the caller's PATH
            # too, so sendmail/msmtp/mail can still be found.
            wrapProgram "$out/bin/ram-altman" \
              --prefix PATH : ${
                pkgs.lib.makeBinPath [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gawk
                  pkgs.util-linux
                ]
              }

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Track RAM usage and tell Sam Altman when this PC has RAM to spare";
            homepage = "https://ram-altman.lol";
            license = licenses.unlicense;
            mainProgram = "ram-altman";
            platforms = platforms.linux;
          };
        };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          ram-altman = mkRamAltman pkgs;
        in
        {
          inherit ram-altman;
          default = ram-altman;
        }
      );

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${mkRamAltman pkgs}/bin/ram-altman";
          meta.description = "Track RAM usage and tell Sam Altman when this PC has RAM to spare";
        };
        ram-altman = {
          type = "app";
          program = "${mkRamAltman pkgs}/bin/ram-altman";
          meta.description = "Track RAM usage and tell Sam Altman when this PC has RAM to spare";
        };
      });

      checks = forAllSystems (pkgs: {
        ram-altman = pkgs.runCommand "ram-altman-tests" {
          nativeBuildInputs = [
            pkgs.bash
            pkgs.coreutils
            pkgs.gawk
            pkgs.util-linux
          ];
        } ''
          cp ${./ram-altman.sh} ram-altman.sh
          cp ${./test-ram-altman.sh} test-ram-altman.sh

          # There is no /usr/bin/env in the build sandbox, and the test writes
          # its fake sendmail with a #!/usr/bin/env bash shebang.
          substituteInPlace ram-altman.sh test-ram-altman.sh \
            --replace-fail '#!/usr/bin/env bash' '#!${pkgs.bash}/bin/bash'

          chmod +x ram-altman.sh test-ram-altman.sh
          bash test-ram-altman.sh
          touch "$out"
        '';
      });
    };
}
