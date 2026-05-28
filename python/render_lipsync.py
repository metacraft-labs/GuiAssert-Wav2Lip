#!/usr/bin/env python3
"""Wav2Lip CLI wrapper for the GuiAssert-Wav2Lip plugin.

Invokes the upstream `inference.py` against a portrait image (or short
video) + WAV narration, and produces a single MP4 at the requested
output path.

Used by GuiAssert's `talking_head` module via subprocess. Exits 0 on
success, non-zero with a diagnostic message on failure.

Usage:
    python render_lipsync.py \\
        --audio /path/to/narration.wav \\
        --source-image /path/to/portrait.png \\
        --output /path/to/lipsync.mp4 \\
        [--device mps|cpu|auto] [--model wav2lip|wav2lip_gan]

Design choices:
  * The produced MP4 INCLUDES the narration audio track muxed in.
    The GuiAssert compose pipeline does its own narration mixing via
    a separate `narration.wav` input, so the audio in the lip-sync
    MP4 is effectively ignored by the final composition — but we keep
    it for stand-alone playback debugging.
  * `--device auto` picks MPS if available, otherwise CPU. Wav2Lip's
    upstream `inference.py` only knows about `cuda` / `cpu`; we patch
    it to honour `WAV2LIP_DEVICE_OVERRIDE` so we can force `mps`. The
    `PYTORCH_ENABLE_MPS_FALLBACK=1` env var (set below) covers any ops
    MPS does not implement.
  * Wav2Lip writes intermediate state into `temp/` *inside its source
    tree*. We mkdir that path before invoking so a fresh checkout
    doesn't crash on `[Errno 2] No such file or directory: 'temp/...'`.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


def resolve_device(requested: str) -> str:
    """Pick the actual device string."""
    if requested in ("cpu",):
        return "cpu"
    if requested in ("mps",):
        return "mps"
    if requested in ("cuda",):
        return "cuda"
    # auto
    try:
        import torch  # local import — keeps the script importable for --help
        if torch.backends.mps.is_available():
            return "mps"
        if torch.cuda.is_available():
            return "cuda"
    except Exception:
        pass
    return "cpu"


def main() -> int:
    parser = argparse.ArgumentParser(description="Wav2Lip CLI wrapper.")
    parser.add_argument("--audio", required=True, help="Narration WAV path")
    parser.add_argument("--source-image", required=True,
                        help="Portrait PNG/JPG (or a short video file)")
    parser.add_argument("--output", required=True, help="Destination MP4 path")
    parser.add_argument("--device", default="auto",
                        choices=["auto", "mps", "cpu", "cuda"])
    parser.add_argument("--model", default="wav2lip",
                        choices=["wav2lip", "wav2lip_gan"],
                        help="Which checkpoint to use under upstream/checkpoints/")
    parser.add_argument("--pads", default=None,
                        help="Optional face padding 'top bottom left right' — "
                             "default lets upstream pick (0 10 0 0).")
    parser.add_argument("--resize-factor", type=int, default=1,
                        help="Reduce the source resolution by this factor "
                             "for face detection.")
    parser.add_argument("--no-smooth", action="store_true",
                        help="Disable Wav2Lip's temporal box-smoothing.")
    args = parser.parse_args()

    audio = Path(args.audio).resolve()
    source = Path(args.source_image).resolve()
    output = Path(args.output).resolve()

    if not audio.exists():
        print(f"ERROR: audio not found: {audio}", file=sys.stderr)
        return 2
    if not source.exists():
        print(f"ERROR: source image not found: {source}", file=sys.stderr)
        return 2
    output.parent.mkdir(parents=True, exist_ok=True)

    # The wrapper lives at python/render_lipsync.py inside the
    # GuiAssert-Wav2Lip checkout; Wav2Lip upstream is the sibling
    # `upstream/` folder.
    here = Path(__file__).resolve().parent
    upstream = here / "upstream"
    inference = upstream / "inference.py"
    if not inference.exists():
        print(f"ERROR: Wav2Lip upstream not found at {upstream}",
              file=sys.stderr)
        return 3

    checkpoint = upstream / "checkpoints" / f"{args.model}.pth"
    if not checkpoint.exists():
        print(f"ERROR: checkpoint missing at {checkpoint}", file=sys.stderr)
        return 3

    device = resolve_device(args.device)
    print(f"[render_lipsync] device={device} model={args.model} "
          f"resize_factor={args.resize_factor} no_smooth={args.no_smooth}")

    # Wav2Lip writes intermediate state into temp/result.avi and
    # (when given non-wav audio) temp/temp.wav, *relative to its own
    # source dir*. Make sure that directory exists.
    (upstream / "temp").mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable, str(inference),
        "--checkpoint_path", str(checkpoint),
        "--face", str(source),
        "--audio", str(audio),
        "--outfile", str(output),
        "--resize_factor", str(args.resize_factor),
    ]
    if args.pads:
        cmd.append("--pads")
        cmd.extend(args.pads.split())
    if args.no_smooth:
        cmd.append("--nosmooth")

    env = os.environ.copy()
    # Stop Hugging Face downloads from spinning up: Wav2Lip doesn't
    # need them at inference time once weights are local.
    env.setdefault("HF_HUB_OFFLINE", "1")
    env.setdefault("TRANSFORMERS_OFFLINE", "1")
    env.setdefault("PYTHONUNBUFFERED", "1")
    # Apple Silicon MPS — fall back to CPU on ops the MPS backend
    # doesn't implement. Without this PyTorch raises NotImplementedError
    # for a handful of aten kernels Wav2Lip touches.
    env.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    # Patch (7) in PATCHES.md teaches the upstream inference.py to
    # honour this env var. Without it, upstream only knows cuda / cpu.
    env["WAV2LIP_DEVICE_OVERRIDE"] = device

    print(f"[render_lipsync] running: {' '.join(cmd)}")
    started = time.time()
    try:
        proc = subprocess.run(
            cmd, cwd=str(upstream), env=env, check=False)
    except FileNotFoundError as e:
        print(f"ERROR: failed to invoke python: {e}", file=sys.stderr)
        return 4
    elapsed = time.time() - started
    print(f"[render_lipsync] wav2lip exit={proc.returncode} "
          f"elapsed={elapsed:.1f}s")
    if proc.returncode != 0:
        print(f"ERROR: Wav2Lip inference failed with exit code "
              f"{proc.returncode}", file=sys.stderr)
        return proc.returncode

    if not output.exists() or output.stat().st_size == 0:
        print(f"ERROR: output missing or empty at {output}", file=sys.stderr)
        return 5
    print(f"[render_lipsync] produced: {output} "
          f"({output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
