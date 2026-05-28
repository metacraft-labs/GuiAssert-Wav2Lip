#!/usr/bin/env bash
# Install / refresh the Wav2Lip plugin.
#
# Steps (each idempotent — re-running the script is safe):
#   1. create a Python 3.10 venv under .venv/ if missing,
#   2. install PyTorch + python/requirements-patched.txt,
#   3. clone Wav2Lip upstream at the pinned commit from python/COMMIT.txt,
#   4. apply the source patches documented in python/PATCHES.md,
#   5. download Wav2Lip's pretrained model weights and the s3fd face
#      detector weights.
#
# Run from inside `nix develop` (the flake exposes python3, git, curl,
# ffmpeg-full).  The script makes no assumption about the dev-shell
# Python version — it requires `python3.10` on PATH (Homebrew's
# `python@3.10` on macOS, or the distro's `python3.10` on Linux).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PY=${PYTHON_BIN:-${PYTHON:-python3.10}}
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "ERROR: $PY not on PATH." >&2
  echo "       Install Python 3.10 first:" >&2
  echo "         macOS:   brew install python@3.10" >&2
  echo "         Linux:   use your distro's python3.10 package" >&2
  exit 1
fi
echo "[install] using $($PY --version) at $(command -v "$PY")"

# ---------------------------------------------------------------------
# 1. venv
# ---------------------------------------------------------------------
if [ ! -d .venv ]; then
  echo "[install] creating Python venv under .venv/ ..."
  "$PY" -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

# Refresh pip + wheel ahead of installing scientific deps.
pip install --upgrade pip wheel setuptools

# ---------------------------------------------------------------------
# 2. requirements
# ---------------------------------------------------------------------
echo "[install] installing PyTorch (CPU+MPS wheel on macOS, CPU on Linux)..."
# We do NOT pin a CUDA wheel here. Users wanting CUDA acceleration
# should pre-install their preferred torch wheel before re-running
# this script (we don't reinstall when torch is already importable).
if ! python -c "import torch" >/dev/null 2>&1; then
  pip install torch torchvision torchaudio
fi
echo "[install] installing patched requirements ..."
pip install -r python/requirements-patched.txt

# ---------------------------------------------------------------------
# 3. clone upstream at the pinned commit
# ---------------------------------------------------------------------
PINNED_SHA="$(tr -d '[:space:]' < python/COMMIT.txt)"
UPSTREAM_DIR="python/upstream"
if [ ! -d "$UPSTREAM_DIR/.git" ]; then
  echo "[install] cloning Wav2Lip upstream at $PINNED_SHA ..."
  git clone https://github.com/Rudrabha/Wav2Lip.git "$UPSTREAM_DIR"
fi
( cd "$UPSTREAM_DIR" && git fetch --tags && git checkout "$PINNED_SHA" )

# ---------------------------------------------------------------------
# 4. apply patches (see python/PATCHES.md for the manifest)
# ---------------------------------------------------------------------
echo "[install] applying numpy2 / librosa-0.10 / torch-2.x / MPS patches ..."

# Each apply_patch invocation is idempotent: it only rewrites the file
# when the legacy needle is still present. The Python helper below
# does a literal string replace.
apply_patch() {
  local file="$1"
  local needle="$2"
  local replacement="$3"
  if [ ! -f "$file" ]; then
    echo "  WARN: skipping $file (not found)" >&2
    return 0
  fi
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    echo "  patching $file (needle: $(echo "$needle" | head -c 60)...)"
    python - "$file" "$needle" "$replacement" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
needle = sys.argv[2]
replacement = sys.argv[3]
data = path.read_text()
data = data.replace(needle, replacement)
path.write_text(data)
PY
  fi
}

# (1) audio.py: librosa.core.load -> librosa.load
apply_patch "$UPSTREAM_DIR/audio.py" \
  "librosa.core.load(path, sr=sr)" \
  "librosa.load(path, sr=sr)"

# (2) audio.py: librosa.filters.mel positional args -> keyword args
apply_patch "$UPSTREAM_DIR/audio.py" \
  "librosa.filters.mel(hp.sample_rate, hp.n_fft, n_mels=hp.num_mels," \
  "librosa.filters.mel(sr=hp.sample_rate, n_fft=hp.n_fft, n_mels=hp.num_mels,"

# (3) audio.py: librosa.output.write_wav -> soundfile.write
apply_patch "$UPSTREAM_DIR/audio.py" \
  "    librosa.output.write_wav(path, wav, sr=sr)" \
  "    import soundfile as sf
    sf.write(path, wav, sr)"

# (4) face_detection/utils.py: np.int -> int
apply_patch "$UPSTREAM_DIR/face_detection/utils.py" \
  "dtype=np.int)" \
  "dtype=int)"

# (5) inference.py: torch.load weights_only=False
apply_patch "$UPSTREAM_DIR/inference.py" \
  "		checkpoint = torch.load(checkpoint_path)" \
  "		checkpoint = torch.load(checkpoint_path, weights_only=False)"

apply_patch "$UPSTREAM_DIR/inference.py" \
  "		checkpoint = torch.load(checkpoint_path,
								map_location=lambda storage, loc: storage)" \
  "		checkpoint = torch.load(checkpoint_path,
								map_location=lambda storage, loc: storage,
								weights_only=False)"

# (6) sfd_detector.py: torch.load weights_only=False
apply_patch "$UPSTREAM_DIR/face_detection/detection/sfd/sfd_detector.py" \
  "            model_weights = torch.load(path_to_detector)" \
  "            model_weights = torch.load(path_to_detector, weights_only=False)"

# (6b) face_detection/detection/core.py: accept 'mps' as a valid device.
# Upstream's FaceDetector.__init__ allow-lists {cpu, cuda} and raises
# ValueError otherwise. The s3fd convolutions run fine on MPS under
# PYTORCH_ENABLE_MPS_FALLBACK=1, so we just add 'mps' to the allow-list.
apply_patch "$UPSTREAM_DIR/face_detection/detection/core.py" \
  "        if 'cpu' not in device and 'cuda' not in device:" \
  "        if 'cpu' not in device and 'cuda' not in device and 'mps' not in device:"

# (7) inference.py: device selection honours WAV2LIP_DEVICE_OVERRIDE
apply_patch "$UPSTREAM_DIR/inference.py" \
  "device = 'cuda' if torch.cuda.is_available() else 'cpu'" \
  "import os as _w2l_os
_w2l_dev = _w2l_os.environ.get('WAV2LIP_DEVICE_OVERRIDE', '').strip()
if _w2l_dev in ('mps', 'cpu', 'cuda'):
    device = _w2l_dev
else:
    device = 'cuda' if torch.cuda.is_available() else 'cpu'"

echo "[install] patch pass complete."

# ---------------------------------------------------------------------
# 5. weights
# ---------------------------------------------------------------------
mkdir -p "$UPSTREAM_DIR/checkpoints"
mkdir -p "$UPSTREAM_DIR/face_detection/detection/sfd"

# wav2lip.pth (~436 MB) — non-GAN checkpoint.
# Source: numz/wav2lip_studio Hugging Face mirror (canonical upstream
# host iiit.ac.in URLs from 2020 are dead).
WAV2LIP_PTH="$UPSTREAM_DIR/checkpoints/wav2lip.pth"
if [ ! -s "$WAV2LIP_PTH" ]; then
  echo "[install] downloading wav2lip.pth (~436 MB) ..."
  curl -fL --retry 3 --retry-delay 2 -o "$WAV2LIP_PTH" \
    "https://huggingface.co/numz/wav2lip_studio/resolve/main/Wav2lip/wav2lip.pth"
fi

# wav2lip_gan.pth (~436 MB) — GAN-quality checkpoint.
WAV2LIP_GAN_PTH="$UPSTREAM_DIR/checkpoints/wav2lip_gan.pth"
if [ ! -s "$WAV2LIP_GAN_PTH" ]; then
  echo "[install] downloading wav2lip_gan.pth (~436 MB) ..."
  curl -fL --retry 3 --retry-delay 2 -o "$WAV2LIP_GAN_PTH" \
    "https://huggingface.co/numz/wav2lip_studio/resolve/main/Wav2lip/wav2lip_gan.pth"
fi

# s3fd.pth (~89 MB) — face detector weights. The upstream
# `sfd_detector.py` references the canonical adrianbulat.com URL.
S3FD_PTH="$UPSTREAM_DIR/face_detection/detection/sfd/s3fd.pth"
if [ ! -s "$S3FD_PTH" ]; then
  echo "[install] downloading s3fd.pth (~89 MB) ..."
  if ! curl -fL --retry 3 --retry-delay 2 -o "$S3FD_PTH" \
       "https://www.adrianbulat.com/downloads/python-fan/s3fd-619a316812.pth"; then
    echo "[install]   adrianbulat.com mirror failed; falling back to HF mirror ..."
    curl -fL --retry 3 --retry-delay 2 -o "$S3FD_PTH" \
      "https://huggingface.co/ByteDance/LatentSync/resolve/main/auxiliary/s3fd-619a316812.pth"
  fi
fi

# Sanity-check weight sizes — anything dramatically smaller than
# expected indicates a partial download or an HTML error page saved
# as .pth.
check_weight_size() {
  local path="$1"
  local min_bytes="$2"
  if [ ! -s "$path" ]; then
    echo "[install] FAIL: $path is empty" >&2
    return 1
  fi
  local sz
  sz="$(wc -c < "$path" | tr -d '[:space:]')"
  if [ "$sz" -lt "$min_bytes" ]; then
    echo "[install] FAIL: $path is only $sz bytes (expected >= $min_bytes)" >&2
    return 1
  fi
}
check_weight_size "$WAV2LIP_PTH"     400000000
check_weight_size "$WAV2LIP_GAN_PTH" 400000000
check_weight_size "$S3FD_PTH"         80000000

echo
echo "[install] DONE. Sanity-check with: ./scripts/verify-install.sh"
