let
  project = import ./default.nix;
in
  project.shellFor {
    # Builds a Hoogle documentation index of all dependencies,
    # and provides a "hoogle" command to search the index.
    withHoogle = true;

    # Some common tools can be added with the `tools` argument
    tools = {
      cabal = "latest";
      haskell-language-server = "latest";
      ghcid = "latest";
      fourmolu = "latest";
      cabal-fmt = "latest";
    };
    # See overlays/tools.nix for more details

    # Prevents cabal from choosing alternate plans, so that
    # *all* dependencies are provided by Nix.
    exactDeps = true;
  }
