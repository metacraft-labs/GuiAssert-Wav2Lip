# GuiAssert-Wav2Lip
#
# `just test`              - run the pure tests (no Wav2Lip install needed).
# `just test-live`         - run the gated live test (-d:wav2lipLive).
# `just install`           - install / refresh the local Wav2Lip setup.
# `just verify`            - smoke-test the install.
# `just lint`              - placeholder; required by the workspace pre-commit hook.

default: test

# Pure unit tests for the plugin.  Compiles against the sibling
# GuiAssert checkout via --path:../GuiAssert/src.
test:
    nim c -r --hints:off --path:src tests/tnimcache_is_worktree_local.nim
    nim c -r --hints:off --path:src --path:../GuiAssert/src tests/twav2lip.nim

# End-to-end live test.  Requires a completed install (.venv + upstream
# checkout + model weights) under this repo.
test-live:
    nim c -d:wav2lipLive -r --hints:off --path:src --path:../GuiAssert/src tests/twav2lip.nim

# Install / refresh the local Wav2Lip setup.
install:
    ./scripts/install.sh

# Smoke-test the install.
verify:
    ./scripts/verify-install.sh

# Required by the workspace's pre-commit hook (`just lint`).  Add real
# linters here as they come online (e.g. `nim check`).
lint:
    @echo "[lint] no linters configured yet for GuiAssert-Wav2Lip."
