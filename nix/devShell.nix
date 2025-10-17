{
    mkShell,
    zig,
    system,
    pkgs,
    zls,
}: let
  in
    mkShell {
      name = "gtk-zig-dev";
      packages =
        [
          zig
          zls
        ];

      shellHook = ''
        echo "Development environment loaded!"
        echo ""
        echo "  Zig: $(zig version)"
        echo ""

        echo "Ready for development!!"
      '';
    }
