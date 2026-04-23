{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.scoville;
in {
  options.services.scoville = {
    enable = lib.mkEnableOption "Scoville VMware clipboard bridge for Wayland";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.scoville or (throw "scoville package not found; add the overlay or set services.scoville.package");
      description = "The scoville package to use.";
    };

    waylandDisplay = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Wayland display name. Null uses the WAYLAND_DISPLAY environment variable.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional command-line arguments passed to scoville.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isx86_64 && pkgs.stdenv.isLinux;
        message = "scoville requires x86_64-linux (VMware backdoor uses I/O port 0x5658)";
      }
    ];

    systemd.user.services.scovilled = {
      description = "Scoville VMware clipboard bridge for Wayland";
      after = ["graphical-session.target"];
      partOf = ["graphical-session.target"];
      wantedBy = ["graphical-session.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = let
          args = lib.concatStringsSep " " cfg.extraArgs;
        in "${cfg.package}/bin/scoville${lib.optionalString (args != "") " ${args}"}";
        Restart = "on-failure";
        RestartSec = 5;
      };

      environment = lib.mkIf (cfg.waylandDisplay != null) {
        WAYLAND_DISPLAY = cfg.waylandDisplay;
      };
    };
  };
}
