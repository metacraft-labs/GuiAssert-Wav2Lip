{
  description = "GuiAssert-Wav2Lip - Wav2Lip lip-sync plugin for GuiAssert";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        {
          devShells.default = pkgs.mkShell {
            # PyTorch is intentionally NOT in this list — its wheel ecosystem
            # works better via pip into the local .venv (so MPS-enabled
            # builds on Apple Silicon and CUDA builds on Linux compose
            # naturally without rebuilding the Nix closure). The system
            # packages below cover the build/runtime toolchain that
            # `scripts/install.sh` and the plugin's Nim subprocess rely on.
            #
            # We deliberately do NOT request `python310` here: the workspace's
            # nixpkgs pin no longer ships that attribute, so resolving it
            # would fail the dev-shell entirely. Instead we pull the default
            # `python3` (used for utility scripts) and let
            # `scripts/install.sh` locate a real Python 3.10 interpreter on
            # the host. The shellHook below verifies one exists and emits a
            # clear remediation message otherwise.
            packages = with pkgs; [
              python3
              nim
              nimble
              just
              git
              curl
              ffmpeg-full
              pkg-config
              cmake
            ];
            shellHook = ''
              # Wav2Lip on Apple Silicon: PyTorch's MPS backend still
              # has gaps for some ops; this env var instructs PyTorch
              # to silently fall back to CPU for unsupported kernels.
              export PYTORCH_ENABLE_MPS_FALLBACK=1
              # Once weights are local we don't need Hugging Face hub
              # at inference time; keeping this off avoids surprise
              # network calls from face-alignment / Wav2Lip deps.
              export HF_HUB_OFFLINE=1
              export TRANSFORMERS_OFFLINE=1
              echo "GuiAssert-Wav2Lip dev shell ready."
              echo "  python:   $(python3 --version)"
              echo "  nim:      $(nim --version | head -1)"
              echo "  ffmpeg:   $(ffmpeg -version | head -1)"
              echo
              # The install script needs Python 3.10 specifically (Wav2Lip's
              # dep tree resolves cleanly there). Warn early if the host
              # doesn't have it on PATH.
              if ! command -v python3.10 >/dev/null 2>&1; then
                echo "WARNING: python3.10 not found on PATH." >&2
                echo "         scripts/install.sh requires it. Install via:" >&2
                echo "             brew install python@3.10" >&2
                echo "         (macOS) or your distro's python3.10 package," >&2
                echo "         then re-enter this shell." >&2
                echo
              else
                echo "  python3.10: $(python3.10 --version)"
                echo
              fi
              echo "Next steps:"
              echo "  ./scripts/install.sh           # create .venv + clone upstream + apply patches + download weights"
              echo "  ./scripts/verify-install.sh    # smoke-test the install"
            '';
          };
        };
    };
}
