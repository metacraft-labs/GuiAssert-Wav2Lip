## Wav2Lip lip-sync plugin for GuiAssert.
##
## Implements GuiAssert's `TalkingHeadProvider` contract on top of a
## local Wav2Lip install: a Python 3.10 venv under `.venv/` and a clone
## of `Rudrabha/Wav2Lip` pinned in `python/COMMIT.txt`.
##
## Wire shape:
##
##   * `wav2lipProvider()` builds a `TalkingHeadProvider` value with
##     `name = "wav2lip"`, an `isAvailable` check (does the venv +
##     wrapper script exist?), and a `generate` proc that shells out
##     to the wrapper.
##   * `registerWav2Lip(reg)` is the one-liner plugin registration
##     entry point.
##
## ## Path discovery
##
## The plugin needs two paths at runtime:
##
##   * `<plugin-root>/.venv/bin/python` — the Python interpreter.
##   * `<plugin-root>/python/render_lipsync.py` — the wrapper script.
##
## `pluginRoot()` resolves to the directory containing this `src/`
## folder.  The `GUI_ASSERT_WAV2LIP_HOME` environment variable lets a
## user pin a non-standard layout (for example a Nix flake build that
## places the plugin elsewhere on disk).

import std/[options, os, osproc, streams, strformat, times]

import gui_assert/talking_head

const
  ProviderName* = "wav2lip"
  DefaultPythonRelPath* = ".venv" / "bin" / "python"
  DefaultRenderScriptRelPath* = "python" / "render_lipsync.py"
  PluginRootEnvVar* = "GUI_ASSERT_WAV2LIP_HOME"
  PythonOverrideEnvVar* = "GUI_ASSERT_WAV2LIP_PYTHON"
  ScriptOverrideEnvVar* = "GUI_ASSERT_WAV2LIP_RENDER_SCRIPT"

proc pluginRoot*(): string =
  ## Returns the on-disk location of the GuiAssert-Wav2Lip checkout.
  ## Resolution order:
  ##   1. `$GUI_ASSERT_WAV2LIP_HOME` env var.
  ##   2. The directory two levels up from this source file
  ##      (`<repo>/src/gui_assert_wav2lip.nim` -> `<repo>`).
  let env = getEnv(PluginRootEnvVar)
  if env.len > 0:
    return env
  result = currentSourcePath().parentDir().parentDir()

proc resolvedPython*(): string =
  ## Returns the path of the Python interpreter the plugin will use.
  ## Honours `$GUI_ASSERT_WAV2LIP_PYTHON` for tests / non-standard
  ## layouts; otherwise points at `<pluginRoot>/.venv/bin/python`.
  let env = getEnv(PythonOverrideEnvVar)
  if env.len > 0:
    return env
  result = pluginRoot() / DefaultPythonRelPath

proc resolvedRenderScript*(): string =
  ## Returns the path of the Wav2Lip wrapper script the plugin will
  ## invoke.  Honours `$GUI_ASSERT_WAV2LIP_RENDER_SCRIPT`; otherwise
  ## points at `<pluginRoot>/python/render_lipsync.py`.
  let env = getEnv(ScriptOverrideEnvVar)
  if env.len > 0:
    return env
  result = pluginRoot() / DefaultRenderScriptRelPath

proc wav2lipIsAvailable*(): bool {.gcsafe.} =
  ## True iff the Python interpreter and wrapper script both exist on
  ## disk.  We deliberately do NOT exec Python here — `isAvailable` is
  ## a cheap-call probe; a non-functional venv that fails at import
  ## time surfaces during `generate`.
  let py = resolvedPython()
  let scr = resolvedRenderScript()
  py.len > 0 and fileExists(py) and scr.len > 0 and fileExists(scr)

proc runWav2Lip(py, script, narrationWav, sourceImage, outputMp4, device,
                logPath: string,
                extraArgs: seq[string]): tuple[exitCode: int, tail: string,
                                                 elapsed: float] =
  ## Spawn the Wav2Lip wrapper.  Captures combined stdout/stderr into
  ## `logPath` and keeps the trailing 8 KB in memory so callers can
  ## include it in error messages.
  if not fileExists(narrationWav):
    raise newException(TalkingHeadError,
      "Wav2Lip: narration WAV not found: " & narrationWav)
  if not fileExists(sourceImage):
    raise newException(TalkingHeadError,
      "Wav2Lip: source image not found: " & sourceImage)
  let outParent = outputMp4.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  var argv: seq[string] = @[
    script,
    "--audio", narrationWav,
    "--source-image", sourceImage,
    "--output", outputMp4,
    "--device", device,
  ]
  for extra in extraArgs:
    argv.add extra

  let logFile = open(logPath, fmWrite)
  var tail = ""
  var exitCode = -1
  let started = epochTime()
  try:
    let p = startProcess(
      command = py,
      args = argv,
      options = {poStdErrToStdOut}
    )
    try:
      let s = p.outputStream
      while not s.atEnd:
        let line =
          try: s.readLine()
          except IOError: break
        logFile.writeLine(line)
        logFile.flushFile()
        if tail.len < 8192:
          tail.add(line)
          tail.add('\n')
        else:
          tail = tail[tail.len - 6144 .. ^1] & line & "\n"
      exitCode = p.waitForExit()
    finally:
      p.close()
  finally:
    logFile.close()
  let elapsed = epochTime() - started
  result = (exitCode: exitCode, tail: tail, elapsed: elapsed)

proc generateWav2Lip(narrationWav, outputMp4: string,
                     opts: TalkingHeadOpts) {.gcsafe.} =
  ## Validates the inputs, looks up a cached render under
  ## `opts.cacheDir` (default: GuiAssert's `defaultCacheDir`), and on a
  ## miss spawns the Python wrapper.  All errors surface as
  ## `TalkingHeadError`.
  if opts.avatarImagePath.isNone or opts.avatarImagePath.get.len == 0:
    raise newException(TalkingHeadError,
      "wav2lip provider requires avatarImagePath to be set " &
      "(a portrait PNG/JPG, or a short video file).")
  let avatar = opts.avatarImagePath.get
  if not fileExists(avatar):
    raise newException(TalkingHeadError,
      "wav2lip provider: avatar image not found: " & avatar)

  let py = resolvedPython()
  let script = resolvedRenderScript()
  if py.len == 0 or not fileExists(py):
    raise newException(TalkingHeadError,
      "wav2lip provider: python binary not found at " & py &
      " (run scripts/install.sh in the GuiAssert-Wav2Lip checkout or " &
      "set $GUI_ASSERT_WAV2LIP_PYTHON).")
  if script.len == 0 or not fileExists(script):
    raise newException(TalkingHeadError,
      "wav2lip provider: render script not found at " & script &
      " (set $GUI_ASSERT_WAV2LIP_RENDER_SCRIPT to override).")

  let device = effectiveDevice(opts)
  let cacheDir = effectiveCacheDir(opts)
  if not dirExists(cacheDir):
    createDir(cacheDir)
  let key = cacheKeyFor(avatar, narrationWav, ProviderName, device)
  let logPath = cacheDir / (key & ".log")

  # The avatar image is passed as `--source-image`. Any caller-supplied
  # extras (from YAML metadata, etc.) are appended verbatim.
  var extra: seq[string] = @[]
  for e in opts.extraArgs:
    extra.add e

  let generator = proc() =
    let res = runWav2Lip(py, script, narrationWav, avatar, outputMp4,
                         device, logPath, extra)
    if res.exitCode != 0:
      raise newException(TalkingHeadError,
        &"Wav2Lip failed (exit={res.exitCode}, elapsed={res.elapsed:.1f}s). " &
        "Log: " & logPath & "\nTail:\n" & res.tail)
    if not fileExists(outputMp4) or getFileSize(outputMp4) == 0:
      raise newException(TalkingHeadError,
        "Wav2Lip reported success but produced no MP4 at " & outputMp4 &
        ". See log: " & logPath)

  # applyCache takes a non-{.gcsafe.} closure for ergonomic test use,
  # but we call it from inside a `{.gcsafe.}` provider entry point.
  # The closure above captures only stack-local values from the
  # enclosing proc; the GC-unsafety comes from the indirect call. We
  # assert gcsafe at the call site.
  {.cast(gcsafe).}:
    discard applyCache(cacheDir, key, outputMp4, generator)

proc wav2lipProvider*(): TalkingHeadProvider =
  ## Build the Wav2Lip provider value.  Plugins of the same shape
  ## compose into the same registry — register multiple to expose
  ## both Wav2Lip and (say) SadTalker under one runner.
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: wav2lipIsAvailable,
    generate: generateWav2Lip,
  )

proc registerWav2Lip*(r: TalkingHeadRegistry) =
  ## One-liner plugin entry point.  Callers do:
  ##
  ## ```nim
  ## import gui_assert/talking_head
  ## import gui_assert_wav2lip
  ##
  ## let reg = newRegistry()
  ## registerWav2Lip(reg)
  ## generateTalkingHead(reg, "wav2lip", wav, mp4, opts)
  ## ```
  r.registerProvider(wav2lipProvider())
