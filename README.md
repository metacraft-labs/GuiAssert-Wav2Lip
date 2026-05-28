# GuiAssert-Wav2Lip

Wav2Lip lip-sync plugin for [GuiAssert]. Implements GuiAssert's
`TalkingHeadProvider` contract by shelling out to a local Wav2Lip
install (a Python 3.10 venv + the `Rudrabha/Wav2Lip` repo at a pinned
commit + ~960 MB of model weights).

Wav2Lip is a 2020 lip-sync model from IIIT Hyderabad. It is fast
(generates ~25 FPS on Apple Silicon MPS) and produces accurate
lip-sync, at the cost of static head motion — it overlays a lip-sync
patch onto an otherwise-still portrait or video. For free, open-source
lip-sync this is the strongest baseline available; for full
head-motion, look at the sibling `GuiAssert-SadTalker` plugin.

This repository is intentionally heavyweight. By keeping it separate
from GuiAssert, any caller that only wants the lightweight
`stock_avatar` placeholder avoids paying the Wav2Lip dependency cost.

[GuiAssert]: ../GuiAssert/

## Layout

```
GuiAssert-Wav2Lip/
├── flake.nix                          python3 + nim + git + curl + ffmpeg-full devShell
├── gui_assert_wav2lip.nimble          nimble package
├── src/
│   └── gui_assert_wav2lip.nim         plugin implementation (TalkingHeadProvider)
├── python/
│   ├── render_lipsync.py              Wav2Lip CLI wrapper
│   ├── requirements-patched.txt       deps relaxed for Python 3.10 + numpy 2.x + PyTorch 2.x
│   ├── PATCHES.md                     patch manifest applied to the upstream checkout
│   ├── COMMIT.txt                     pinned upstream SHA
│   └── upstream/                      (gitignored) Wav2Lip clone — populated by install.sh
├── scripts/
│   ├── install.sh                     create .venv, clone upstream, apply patches, fetch weights
│   └── verify-install.sh              smoke-test the install
└── tests/
    └── twav2lip.nim                   pure tests + `-d:wav2lipLive` gated live test
```

## Cost of setup

| Resource     | Approx.                                                |
| ------------ | ------------------------------------------------------ |
| Disk         | ~960 MB of weights + ~1.5 GB of Python deps in `.venv` |
| Network      | ~960 MB on first install (subsequent runs are offline) |
| Time         | ~5 min on a fresh checkout                             |
| Dollars      | Zero — Wav2Lip is open source (MIT)                    |
| API key      | None                                                   |

## Setup

```sh
nix develop                  # python3 + nim + ffmpeg-full + cmake + pkg-config
./scripts/install.sh         # ~5 min on a fresh checkout
./scripts/verify-install.sh  # quick smoke-test
```

The install script is idempotent. Re-running it skips already-done
steps and re-applies patches incrementally.

### Python 3.10 requirement

`scripts/install.sh` requires `python3.10` on `PATH`. The dev-shell's
`python3` is currently used only for utility scripts; the venv that
hosts Wav2Lip's deps is created from your host `python3.10`. On macOS:

```sh
brew install python@3.10
# (the install script picks up python3.10 from /opt/homebrew/bin)
```

On Linux, install your distribution's `python3.10` package
(`apt install python3.10` on Debian/Ubuntu, etc.).

### Apple Silicon notes

* Wav2Lip runs on the MPS backend with
  `PYTORCH_ENABLE_MPS_FALLBACK=1` (set automatically by the dev-shell
  and the wrapper script). A small number of `aten::*` ops fall back
  to CPU; the bulk of the model runs on the GPU.
* Typical render speed on an M-series Mac: ~25 it/s on the Wav2Lip
  generator, ~5 it/s on the s3fd face detector.
* Upstream Wav2Lip was last touched in 2020 and pins numpy 1.17,
  torch 1.1, librosa 0.7, opencv-python 4.1, none of which install
  under Python 3.10 on Apple Silicon. We patch the source for the
  small API changes that modern numpy 2.x / librosa 0.10 / PyTorch
  2.x require — see `python/PATCHES.md` for the full manifest.
* PyTorch 2.6+ flipped the default of `torch.load(weights_only=...)`
  to `True`, which breaks the pre-2.6 state-dict pickles Wav2Lip
  ships. Patch (5) in `PATCHES.md` flips it back.

## Wiring into a runner

```nim
import gui_assert/talking_head
import gui_assert_wav2lip

let reg = newRegistry()         # registry pre-populated with `stock_avatar`
registerWav2Lip(reg)            # now `wav2lip` is also registered

var opts = TalkingHeadOpts(
  avatarImagePath: some(avatarPng),
  device: "mps",
  cacheDir: some("/tmp/wav2lip-cache"),
)
generateTalkingHead(reg, "wav2lip", narrationWav, outputMp4, opts)
```

Path discovery uses three environment variables (each with a sensible
default):

| Variable | Default | Purpose |
| --- | --- | --- |
| `GUI_ASSERT_WAV2LIP_HOME` | this repo's root | Override the plugin install location. |
| `GUI_ASSERT_WAV2LIP_PYTHON` | `<home>/.venv/bin/python` | Override the Python interpreter. |
| `GUI_ASSERT_WAV2LIP_RENDER_SCRIPT` | `<home>/python/render_lipsync.py` | Override the wrapper script. |

## Tests

```sh
# Pure tests — always safe to run.
nim c -r --hints:off --path:src --path:../GuiAssert/src tests/twav2lip.nim

# Live end-to-end — requires the install to have completed.
nim c -d:wav2lipLive -r --hints:off --path:src --path:../GuiAssert/src tests/twav2lip.nim
```

The live test fails the run if Wav2Lip is not actually available —
it is not a graceful skip. CI that does not want to install Wav2Lip
simply compiles without `-d:wav2lipLive`.

The live test synthesises its own narration WAV (via macOS `say` +
ffmpeg resample to 16 kHz mono) and reads a small portrait fixture
from `tests/fixtures/portrait.png` (override either via
`$GUI_ASSERT_WAV2LIP_TEST_WAV` / `$GUI_ASSERT_WAV2LIP_TEST_AVATAR`).

## License

MIT — see `LICENSE`. Upstream Wav2Lip is also MIT-licensed; this
plugin does not redistribute it (the install script clones it
directly from GitHub).
