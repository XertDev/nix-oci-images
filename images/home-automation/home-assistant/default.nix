{ dockerTools, lib, pkgs, ... }: let
  DEFAULT_UID = 1000;
  DEFAULT_GID = 1000;

  CONFIG_DIR = "/var/lib/hass";
  MANUAL_CONFIG = "${CONFIG_DIR}/manual_config.yaml";

  image = {
    package ? pkgs.home-assistant.overrideAttrs (_: { doInstallCheck = false; }),
    bind ? "0.0.0.0",
    port ? 5000,
    extraPackages ? (_: [ ]),
    customLovelaceModules ? [],
    defaultComponents ? [],
    customComponents ? []
  }: dockerTools.streamLayeredImage (let
    format = pkgs.formats.yaml { };

    #https://github.com/NixOS/nixpkgs/blob/105b791fa9c300b8fd992ba15269932c9a8532a2/nixos/modules/services/home-automation/home-assistant.nix#L55C1-L68C10
    # Post-process YAML output to add support for YAML functions, like
    # secrets or includes, by naively unquoting strings with leading bangs
    # and at least one space-separated parameter.
    # https://www.home-assistant.io/docs/configuration/secrets/
    renderYAMLFile = fn: yaml:
      pkgs.runCommand fn { preferLocalBuilds = true; } ''
        cp ${format.generate fn yaml} $out
        sed -i -e "s/'\!\([a-z_]\+\) \(.*\)'/\!\1 \2/;s/^\!\!/\!/;" $out
      '';

    defaultConfig = {
      http = {
        server_host = bind;
        server_port = port;
      };
    };

    lovelaceResourcesConfig = let
      resourceRegistryFormat = pkgs.formats.json { };

      indexToEntryId = index:
        let
          entryIdAlphabet = [
            "0"
            "1"
            "2"
            "3"
            "4"
            "5"
            "6"
            "7"
            "8"
            "9"
            "A"
            "B"
            "C"
            "D"
            "E"
            "F"
            "G"
            "H"
            "J"
            "K"
            "M"
            "N"
            "P"
            "Q"
            "R"
            "S"
            "T"
            "V"
            "W"
            "X"
            "Y"
            "Z"
          ];
          entryIdAlphabetLength = lib.length entryIdAlphabet;

          entryIdLength = 26;
          toEntryId' = v: following:
            if v > 0 then
              (toEntryId' (v / entryIdAlphabetLength) (toString
                (builtins.elemAt entryIdAlphabet
                  (lib.mod v entryIdAlphabetLength)) + following))
            else
              following;
        in lib.strings.fixedWidthString entryIdLength "0"
          (toEntryId' index "");

        data = {
          version = 1;
          minor_version = 1;
          key = "lovelace_resources";
          autogenerted = true;
          data = {
            items = lib.lists.imap1 (index: card: {
              id = indexToEntryId index;
              url = "/local/nixos-lovelace-modules/${
                  card.entrypoint or (card.pname + ".js")
                }?${card.version}";
              type = "module";
            }) customLovelaceModules;
          };
        };
      in pkgs.runCommandLocal "lovelace_resources" { } ''
        cp ${resourceRegistryFormat.generate "lovelace_resources" data} $out
      '';

      configFile = renderYAMLFile "configuration.yaml" defaultConfig;

      requiredDefaultComponents = [
        "default_config"
        "met"
        "application_credentials"
        "frontend"
        "hardware"
        "logger"
        "network"
        "system_health"

        # key features
        "automation"
        "person"
        "scene"
        "script"
        "tag"
        "zone"

        # built-in helpers
        "counter"
        "input_boolean"
        "input_button"
        "input_datetime"
        "input_number"
        "input_select"
        "input_text"
        "schedule"
        "timer"

        # non-supervisor
        "backup"
      ];

      availableComponents = package.availableComponents;
      finalDefaultComponents = requiredDefaultComponents
        ++ package.extraComponents ++ defaultComponents;

      components =
        builtins.filter (comp: builtins.elem comp finalDefaultComponents)
        availableComponents;

      finalPackage = (package.override (old: {
        extraComponents = components;
        extraPackages = ps:
          (old.extraPackages or (_: [ ]) ps)
          ++ (lib.concatMap (comp: comp.propagatedBuildInputs or [ ])
            customComponents) ++ (extraPackages ps);
      }));

        customLovelaceModulesDir = pkgs.buildEnv {
          name = "home-assistant-custom-lovelace-modules";
          paths = customLovelaceModules;
        };

        initScript = pkgs.writeShellApplication {
          name = "home-assistant-entrypoint";
          runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.bash package ];
          text = ''
            mkdir -p "${CONFIG_DIR}"
            #configuration
            rm -f "${CONFIG_DIR}/configuration.yaml"
            cp  ${configFile} "${CONFIG_DIR}/configuration.yaml"

            chmod u+w "${CONFIG_DIR}/configuration.yaml"
            cat "${MANUAL_CONFIG}" >> "${CONFIG_DIR}/configuration.yaml"
            chmod u-w "${CONFIG_DIR}/configuration.yaml"

            #customLovelaceModules
            mkdir -p "${CONFIG_DIR}/www"
            ln -fns ${customLovelaceModulesDir} "${CONFIG_DIR}/www/nixos-lovelace-modules"

            #customComponents
            mkdir -p '${CONFIG_DIR}/custom_components/'
            ${lib.strings.concatStringsSep "\n" (lib.lists.flatten (map
              (component: [
                ""
                "#component ${component.name}"
                ''
                  find "${component}" -name manifest.json -exec sh -c 'ln -fns "$(dirname $1)" "${CONFIG_DIR}/custom_components/" ''
                "' sh {} ';'"
              ]) customComponents))}

            mkdir -p '${CONFIG_DIR}/.storage'
            cp --no-preserve=mode ${lovelaceResourcesConfig} '${CONFIG_DIR}/.storage/lovelace_resources'

            hass --config ${CONFIG_DIR}
          '';
        };

        hashParts = [ (toString bind) (toString port) ]
          ++ components ++ ((finalPackage.extraPackages or (_: [ ]))
            finalPackage.python.pkgs) ++ [ configFile.outPath ]
          ++ customLovelaceModules
          ++ [ (toString lovelaceResourcesConfig) ];
        configHash =
          builtins.hashString "md5" (lib.strings.concatStrings hashParts);
  in {
    name = "home-assistant";
    tag = "${package.version}-${configHash}";

    enableFakechroot = true;
    fakeRootCommands = ''
      mkdir -p tmp
      chown -R ${toString DEFAULT_UID}:${toString DEFAULT_GID} ./tmp

      mkdir -p "${CONFIG_DIR}"
      touch  "${MANUAL_CONFIG}"
      chown -R ${toString DEFAULT_UID}:${toString DEFAULT_GID} "${CONFIG_DIR}"
    '';

    config = {
      Env = [ "PYTHONPATH=${finalPackage.pythonPath}" ];

      Entrypoint = [ (pkgs.lib.meta.getExe initScript) ];
      User = "${toString DEFAULT_UID}:${toString DEFAULT_GID}";
    };
  });
in lib.makeOverridable image