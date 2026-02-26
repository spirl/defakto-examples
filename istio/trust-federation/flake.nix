{
  description = "Istio Trust Federation Demo";

  # NOTE: This flake.nix is OPTIONAL
  # If you don't use Nix, just ensure you have the required tools installed:
  # - kubectl, kind, tilt, istioctl, spirlctl
  # See README.md for setup instructions

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            kubectl
            kubernetes-helm
            tilt
            ctlptl
            kind
            istioctl
          ];

          shellHook = ''
            echo "Istio Trust Federation Demo Environment"
            echo "========================================"
            echo ""
            echo "Available commands:"
            echo "  make env-up    - Start the demo environment"
            echo "  make env-down  - Stop the demo environment"
            echo "  make env-reset - Reset the demo environment"
            echo "  tilt up        - Start Tilt (after env-up)"
            echo ""
            echo "Prerequisites:"
            echo "  - spirlctl trust-domain create example.org"
            echo "  - spirlctl cluster add istio-trust-federation --trust-domain example.org --platform istio"
            echo ""
          '';
        };
      }
    );
}
