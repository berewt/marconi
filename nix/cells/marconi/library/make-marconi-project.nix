{ inputs, cell }:

# Whether to set the `defer-plugin-errors` flag on those packages that need
# it. If set to true, we will also build the haddocks for those packages.
{ deferPluginErrors ? false

, enableHaskellProfiling ? false
}:

let
  project = cell.library.pkgs.haskell-nix.cabalProject' ({ pkgs, config, lib, ... }: {

    compiler-nix-name = cell.library.ghc-compiler-nix-name;

    src = cell.library.pkgs.haskell-nix.haskellLib.cleanSourceWith {
      src = inputs.self.outPath;
      name = "marconi";
    };

    shell.withHoogle = false;

    #  source-repository-packages
    sha256map = {
      "https://github.com/input-output-hk/cardano-node"."a158a679690ed8b003ee06e1216ac8acd5ab823d" = "sha256-uY7wPyCgKuIZcGu0+vGacjGw2kox8H5ZsVGsfTNtU0c=";
    };

    inputMap = {
      "https://input-output-hk.github.io/cardano-haskell-packages" = inputs.CHaP;
    };

    # Configuration settings needed for cabal configure to work when cross compiling
    # for windows. We can't use `modules` for these as `modules` are only applied
    # after cabal has been configured.
    cabalProjectLocal = lib.optionalString pkgs.stdenv.hostPlatform.isWindows ''
      -- When cross compiling for windows we don't have a `ghc` package, so use
      -- the `plutus-ghc-stub` package instead.
      package plutus-tx-plugin
        flags: +use-ghc-stub

      -- Exlcude test that use `doctest`.  They will not work for windows
      -- cross compilation and `cabal` will not be able to make a plan.
      package prettyprinter-configurable
        tests: False
    '';
    modules =
      let
        inherit (config) src;
      in
      [
        ({ pkgs, ... }: lib.mkIf (pkgs.stdenv.hostPlatform != pkgs.stdenv.buildPlatform) {
          packages = {
            # Things that need plutus-tx-plugin
            cardano-node-emulator.package.buildable = false;
            cardano-streaming.package.buildable = false;
            marconi-chain-index.package.buildable = false;
            marconi-core.package.buildable = false;
            marconi-sidechain.package.buildable = false;
            # These need R
            plutus-core.components.benchmarks.cost-model-test.buildable = lib.mkForce false;
            plutus-core.components.benchmarks.update-cost-model.buildable = lib.mkForce false;
          };
        })
        ({ pkgs, ... }:
          let
            # Add symlinks to the DLLs used by executable code to the `bin` directory
            # of the components with we are going to run.
            # We should try to find a way to automate this will in haskell.nix.
            symlinkDlls = ''
              ln -s ${pkgs.libsodium-vrf}/bin/libsodium-23.dll $out/bin/libsodium-23.dll
              ln -s ${pkgs.buildPackages.gcc.cc}/x86_64-w64-mingw32/lib/libgcc_s_seh-1.dll $out/bin/libgcc_s_seh-1.dll
              ln -s ${pkgs.buildPackages.gcc.cc}/x86_64-w64-mingw32/lib/libstdc++-6.dll $out/bin/libstdc++-6.dll
              ln -s ${pkgs.windows.mcfgthreads}/bin/mcfgthread-12.dll $out/bin/mcfgthread-12.dll
            '';
          in
          lib.mkIf (pkgs.stdenv.hostPlatform.isWindows) { }
        )
        ({ pkgs, config, ... }: {
          packages = {
            marconi-core.doHaddock = deferPluginErrors;
            marconi-core.flags.defer-plugin-errors = deferPluginErrors;

            marconi-chain-index.doHaddock = deferPluginErrors;
            marconi-chain-index.flags.defer-plugin-errors = deferPluginErrors;

            # The lines `export CARDANO_NODE=...` and `export CARDANO_CLI=...`
            # is necessary to prevent the error
            # `../dist-newstyle/cache/plan.json: openBinaryFile: does not exist (No such file or directory)`.
            # See https://github.com/input-output-hk/cardano-node/issues/4194.
            #
            # The line 'export CARDANO_NODE_SRC=...' is used to specify the
            # root folder used to fetch the `configuration.yaml` file (in
            # marconi, it's currently in the
            # `configuration/defaults/byron-mainnet` directory.
            # Else, we'll get the error
            # `/nix/store/ls0ky8x6zi3fkxrv7n4vs4x9czcqh1pb-marconi/marconi/test/configuration.yaml: openFile: does not exist (No such file or directory)`
            marconi-chain-index.preCheck = "
              export CARDANO_CLI=${config.hsPkgs.cardano-cli.components.exes.cardano-cli}/bin/cardano-cli${pkgs.stdenv.hostPlatform.extensions.executable}
              export CARDANO_NODE=${config.hsPkgs.cardano-node.components.exes.cardano-node}/bin/cardano-node${pkgs.stdenv.hostPlatform.extensions.executable}
              export CARDANO_NODE_SRC=${src}
            ";

            marconi-sidechain.doHaddock = deferPluginErrors;
            marconi-sidechain.flags.defer-plugin-errors = deferPluginErrors;
            # FIXME: Haddock mysteriously gives a spurious missing-home-modules warning
            plutus-tx-plugin.doHaddock = false;

            # Relies on cabal-doctest, just turn it off in the Nix build
            prettyprinter-configurable.components.tests.prettyprinter-configurable-doctest.buildable = lib.mkForce false;

            # Broken due to warnings, unclear why the setting that fixes this for the build doesn't work here.
            iohk-monitoring.doHaddock = false;

            # Werror everything. This is a pain, see https://github.com/input-output-hk/haskell.nix/issues/519
            cardano-streaming.ghcOptions = [ "-Werror" ];
            marconi-chain-index.ghcOptions = [ "-Werror" ];
            marconi-core.ghcOptions = [ "-Werror" ];
            marconi-sidechain.ghcOptions = [ "-Werror" ];

            # Honestly not sure why we need this, it has a mysterious unused dependency on "m"
            # This will go away when we upgrade nixpkgs and things use ieee754 anyway.
            ieee.components.library.libs = lib.mkForce [ ];

            # See https://github.com/input-output-hk/iohk-nix/pull/488
            cardano-crypto-praos.components.library.pkgconfig = lib.mkForce [ [ pkgs.libsodium-vrf ] ];
            cardano-crypto-class.components.library.pkgconfig = lib.mkForce [ [ pkgs.libsodium-vrf pkgs.secp256k1 ] ];
          };
        })
      ] ++ lib.optional enableHaskellProfiling {
        enableLibraryProfiling = true;
        enableProfiling = true;
      };
  });

in
project
