# Wav2Lip patches for the GuiAssert-Wav2Lip plugin

The `upstream/` directory is a checkout of `Rudrabha/Wav2Lip` pinned in
`COMMIT.txt`. The repo was last touched upstream in 2020 and pins very old
versions of numpy (1.17), torch (1.1), librosa (0.7) and opencv-python
(4.1). Those pins are unsatisfiable under modern Python 3.10 + PyTorch 2.x +
numpy 2.x on Apple Silicon. This document records every source patch the
install script applies after cloning upstream, so the install is
reproducible.

## Why we patched instead of pinning to legacy versions

We use PyTorch 2.x (the current stable) so MPS-backed GPU inference works
on Apple Silicon. PyTorch 2.x ships numpy 2.x by default. Numpy 2 removed
several deprecated aliases (`np.float`, `np.int`, etc.) that Wav2Lip's
source still uses. librosa 0.10 reshuffled APIs (`librosa.core.load` →
`librosa.load`, removed `librosa.output.write_wav`, made `sr` and `n_fft`
keyword-only in `librosa.filters.mel`, etc.). PyTorch 2.6 flipped the
`weights_only` default of `torch.load` to `True`, which breaks the
upstream's `torch.load(checkpoint_path)` call on the legacy
state-dict-only `.pth` files Wav2Lip ships.

## requirements-patched.txt

`upstream/requirements.txt` hard-pins:

    librosa==0.7.0
    numpy==1.17.1
    opencv-contrib-python>=4.2.0.34
    opencv-python==4.1.0.25
    torch==1.1.0
    torchvision==0.3.0
    tqdm==4.45.0
    numba==0.48

None of these install cleanly on Python 3.10 / Apple Silicon. We bypass it
via `requirements-patched.txt` (checked in alongside this file), which
unpins every conflicting line and lets pip pick compatible newer wheels.
PyTorch itself is installed by the install script ahead of this file via
`pip install torch torchvision torchaudio`, so users get whatever wheel
matches their host Python + accelerator.

Install with:

    pip install -r python/requirements-patched.txt

## Source patches applied to `upstream/`

These are applied directly to the checked-out copy by
`scripts/install.sh`. The patches are small and idempotent — re-running
the install script after a fresh re-clone re-applies them.

### 1. `audio.py` — `librosa.core.load` → `librosa.load`

librosa 0.10 removed the `librosa.core` shim. `librosa.load(path, sr=sr)`
is the replacement; it returns the same `(y, sr)` tuple.

    -    return librosa.core.load(path, sr=sr)[0]
    +    return librosa.load(path, sr=sr)[0]

### 2. `audio.py` — `librosa.filters.mel` keyword arguments

librosa 0.10 made `sr` and `n_fft` keyword-only on `mel`:

    -    return librosa.filters.mel(hp.sample_rate, hp.n_fft, n_mels=hp.num_mels,
    -                               fmin=hp.fmin, fmax=hp.fmax)
    +    return librosa.filters.mel(sr=hp.sample_rate, n_fft=hp.n_fft,
    +                               n_mels=hp.num_mels,
    +                               fmin=hp.fmin, fmax=hp.fmax)

### 3. `audio.py` — `librosa.output.write_wav` removed

The helper `save_wavenet_wav` is unused by inference but importing it
fails under modern librosa. We swap to `soundfile.write`, which is the
documented modern replacement and is pulled in by librosa itself:

    -def save_wavenet_wav(wav, path, sr):
    -    librosa.output.write_wav(path, wav, sr=sr)
    +def save_wavenet_wav(wav, path, sr):
    +    import soundfile as sf
    +    sf.write(path, wav, sr)

### 4. `face_detection/utils.py` — `np.int` removed in numpy 1.20+

Replaced with the built-in `int`:

    -        newDim = np.array([br[1] - ul[1], br[0] - ul[0]], dtype=np.int)
    +        newDim = np.array([br[1] - ul[1], br[0] - ul[0]], dtype=int)

### 5. `inference.py` — `torch.load` `weights_only` default

PyTorch 2.6 flipped the default of `torch.load(..., weights_only=...)`
from `False` to `True` to harden against arbitrary-code execution from
malicious pickle files. The upstream `.pth` files are pre-2.6 state-dict
pickles; loading them with `weights_only=True` raises
`_pickle.UnpicklingError`. We force `weights_only=False`:

    -        checkpoint = torch.load(checkpoint_path)
    +        checkpoint = torch.load(checkpoint_path, weights_only=False)
    ...
    -        checkpoint = torch.load(checkpoint_path,
    -                                map_location=lambda storage, loc: storage)
    +        checkpoint = torch.load(checkpoint_path,
    +                                map_location=lambda storage, loc: storage,
    +                                weights_only=False)

### 6. `face_detection/detection/sfd/sfd_detector.py` — same `weights_only` flip

The s3fd detector loads its `.pth` the same way:

    -            model_weights = torch.load(path_to_detector)
    +            model_weights = torch.load(path_to_detector, weights_only=False)

### 6b. `face_detection/detection/core.py` — accept `mps` device

`FaceDetector.__init__` allow-lists `cpu` and `cuda` and raises
`ValueError` otherwise. The s3fd convolutions run fine on MPS under
`PYTORCH_ENABLE_MPS_FALLBACK=1`, so we extend the allow-list:

    -        if 'cpu' not in device and 'cuda' not in device:
    +        if 'cpu' not in device and 'cuda' not in device and 'mps' not in device:

### 7. `inference.py` — MPS device selection

Upstream picks `cuda` or `cpu` based on `torch.cuda.is_available()`.
We honour a `WAV2LIP_DEVICE_OVERRIDE` environment variable so the wrapper
script can force `mps` on Apple Silicon while keeping the upstream code
intact:

    -device = 'cuda' if torch.cuda.is_available() else 'cpu'
    +import os as _os
    +_dev_override = _os.environ.get('WAV2LIP_DEVICE_OVERRIDE', '').strip()
    +if _dev_override in ('mps', 'cpu', 'cuda'):
    +    device = _dev_override
    +else:
    +    device = 'cuda' if torch.cuda.is_available() else 'cpu'

`PYTORCH_ENABLE_MPS_FALLBACK=1` (set by the wrapper) covers the ops MPS
does not implement (notably a few `aten::*` kernels Wav2Lip's Wav2Lip
generator triggers).

### 8. `inference.py` / `audio.py` — guard the `image.split('.')[1]` extension check

Wav2Lip uses `args.face.split('.')[1]` to detect image vs. video input.
That breaks for any path with no extension. Not strictly needed for the
fixture we ship; left unpatched. Document the constraint instead.

## Re-applying the patches

If `python/upstream/` is wiped and re-cloned, the patches above must be
reapplied. `scripts/install.sh` does this automatically (and is
idempotent — re-running it skips already-patched files).

## Apple Silicon MPS notes

With these patches and `PYTORCH_ENABLE_MPS_FALLBACK=1`, Wav2Lip on MPS
renders ~10 s of narration in about 30 seconds wall-clock on an M-series
Mac (face detection runs at ~5 it/s; the Wav2Lip generator runs at ~25
it/s). The CPU path also works but is roughly 5× slower. Lip-sync remains
accurate because the audio → mel pipeline is numpy-only.

## Weights

The install script downloads:

  * `checkpoints/wav2lip.pth` (~436 MB) — non-GAN model.
  * `checkpoints/wav2lip_gan.pth` (~436 MB) — GAN-quality model.
  * `face_detection/detection/sfd/s3fd.pth` (~89 MB) — face detector.

Sources are documented inline in `scripts/install.sh`. The wav2lip
checkpoints come from the `numz/wav2lip_studio` Hugging Face mirror; the
s3fd detector comes from the original `adrianbulat.com` URL (which the
upstream still references) with a Hugging Face fallback.
