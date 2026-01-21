{ dockerTools, lib, pkgs, ... }:
let
  DEFAULT_UID = 1000;
  DEFAULT_GID = 1000;

  CONFIG_DIR = "/var/lib/fava";
  USER_DIR = "${CONFIG_DIR}/user";

  image = { package ? pkgs.fava, bind ? "0.0.0.0", port ? 5000
    , extraPythonPackages ? (_ps: [ ]) }:
    dockerTools.streamLayeredImage (let
      defaultAccountsFile = pkgs.writeTextFile {
        name = "default_accounts.bean";
        text = ''
          1970-01-01 open Expenses:FIXME
        '';
      };

      defaultImporterConfig = pkgs.writeTextFile {
        name = "importer.py";
        text = ''
          CONFIG = []
          HOOKS = []
        '';
      };

      defaultCurrenciesConfig = pkgs.writeTextFile {
        name = "currencies.bean";
        text = ''
          option "operating_currency" "USD"
          option "inferred_tolerance_default" "*:0.00000001"
          option "inferred_tolerance_default" "USD:0.003"

          option "tolerance_multiplier" "1.2"
        '';
      };

      favaConfigContent = lib.strings.concatStringsSep "\n" ([
        ''
          1970-01-01 custom "fava-option" "import-config" "${USER_DIR}/importer.py"''
        ''1970-01-01 custom "fava-option" "import-dirs" "${USER_DIR}/ingested"''
      ]);

      favaConfigFile = pkgs.writeTextFile {
        name = "fava.bean";
        text = favaConfigContent;
      };

      rootLedgerContent = lib.strings.concatStringsSep "\n" ([
        ''option "plugin_processing_mode" "raw"''
        ''plugin "beancount.ops.pad"''
        ''plugin "beancount.ops.balance"''
        ''plugin "beancount.ops.documents"''
        ''option "documents" "user/documents"''
        ''plugin "beancount.plugins.implicit_prices"''
        "; default accounts - used by plugins"
        ''include "accounts.default.bean"''
        ''include "user/fava.bean"''
        ''include "user/main.bean"''
        ''include "user/accounts.bean"''
        ''include "user/currencies.bean"''
        ''include "user/commodities.bean"''
        ''include "user/manual.bean"''
      ]);

      rootLedgerFile = pkgs.writeTextFile {
        name = "root.bean";
        text = rootLedgerContent;
      };

      favaEnv = pkgs.python3.buildEnv.override {
        extraLibs = [ (pkgs.python3Packages.toPythonModule package) ]
          ++ (extraPythonPackages pkgs.python3Packages);
      };

      initScript = pkgs.writeShellApplication {
        name = "fava-entrypoint";
        runtimeInputs = [ pkgs.coreutils package ];
        text = ''
          cp --no-preserve=mode "${defaultAccountsFile}" "${CONFIG_DIR}/accounts.default.bean"
          cp --no-preserve=mode "${rootLedgerFile}" "${CONFIG_DIR}/root.bean"

          if [ "$(${pkgs.findutils}/bin/find '${USER_DIR}' | wc -l)" -eq "1" ]; then
            echo 'Creating user dir: ${USER_DIR}';

            mkdir -p '${USER_DIR}/ingested'
            mkdir -p '${USER_DIR}/documents'

            touch '${USER_DIR}/main.bean'
            touch '${USER_DIR}/accounts.bean'
            touch '${USER_DIR}/commodities.bean'
            touch '${USER_DIR}/manual.bean'

            cp --no-preserve=mode '${defaultCurrenciesConfig}' '${USER_DIR}/currencies.bean'
            cp --no-preserve=mode '${defaultImporterConfig}' '${USER_DIR}/importer.py'
            cp --no-preserve=mode '${favaConfigFile}' '${USER_DIR}/fava.bean'

            chmod u+rw '${USER_DIR}'
          fi

          echo 'Starting fava'
          ${favaEnv}/bin/fava "${CONFIG_DIR}/root.bean" --host ${bind} --port ${
            builtins.toString port
          }
        '';
      };

      hashParts = [ (toString bind) (toString port) ];
      configHash =
        builtins.hashString "md5" (lib.strings.concatStrings hashParts);

      name = "fava";
      tag = "${package.version}-${configHash}";
    in {
      inherit name tag;
      passthru = {
        inherit name tag;

        uid = DEFAULT_UID;
        gid = DEFAULT_GID;

        inherit port;
      };

      enableFakechroot = true;
      fakeRootCommands = ''
        mkdir -p tmp/matplotlib
        chown -R ${toString DEFAULT_UID}:${toString DEFAULT_GID} tmp

        mkdir -p "${USER_DIR}"
        chown -R ${toString DEFAULT_UID}:${toString DEFAULT_GID} ${CONFIG_DIR}
      '';

      config = {
        Env = [ "MPLCONFIGDIR=/tmp/matplotlib" ];
        ExposedPorts = { "${toString port}" = { }; };

        Volumes = { "${USER_DIR}" = { }; };

        Entrypoint = [ (pkgs.lib.meta.getExe initScript) ];
        User = "${toString DEFAULT_UID}:${toString DEFAULT_GID}";
      };
    });

in lib.makeOverridable image
