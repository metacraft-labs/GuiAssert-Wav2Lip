#!/usr/bin/env bash
# Quick smoke-test that the Wav2Lip plugin is wired up.
#
# Verifies:
#   * .venv/bin/python exists and imports torch + librosa + opencv
#     without raising,
#   * the wrapper script's --help runs cleanly,
#   * the checkpoint files exist and are plausibly-sized,
#   * the s3fd face detector weights are in place.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PY=".venv/bin/python"
SCRIPT="python/render_lipsync.py"
UPSTREAM_DIR="python/upstream"

if [ ! -x "$PY" ]; then
  echo "FAIL: $PY not found. Run ./scripts/install.sh first." >&2
  exit 1
fi
if [ ! -f "$SCRIPT" ]; then
  echo "FAIL: wrapper script missing at $SCRIPT" >&2
  exit 1
fi
for weight in \
  "$UPSTREAM_DIR/checkpoints/wav2lip.pth" \
  "$UPSTREAM_DIR/checkpoints/wav2lip_gan.pth" \
  "$UPSTREAM_DIR/face_detection/detection/sfd/s3fd.pth"; do
  if [ ! -s "$weight" ]; then
    echo "FAIL: $weight missing or empty. Run ./scripts/install.sh." >&2
    exit 1
  fi
done

echo "[verify] importing torch ..."
"$PY" -c "import torch; print('  torch', torch.__version__, 'mps_available=', torch.backends.mps.is_available())"

echo "[verify] importing librosa + cv2 + numpy ..."
"$PY" -c "import librosa, cv2, numpy; print('  librosa', librosa.__version__, 'cv2', cv2.__version__, 'numpy', numpy.__version__)"

echo "[verify] wrapper --help ..."
"$PY" "$SCRIPT" --help >/dev/null

echo "[verify] DONE — Wav2Lip plugin is wired up."
