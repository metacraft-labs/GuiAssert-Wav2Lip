# Test fixtures

## `portrait.png` — Albert Einstein head shot

400x400 PNG, downscaled + cropped from the Wikimedia Commons file
[`Albert_Einstein_Head.jpg`](https://commons.wikimedia.org/wiki/File:Albert_Einstein_Head.jpg),
which is in the **public domain** worldwide (the underlying photograph
was published before 1929 and its copyright has expired in the United
States; the file is tagged `PD-US-expired` on Wikimedia Commons).

The crop + downscale was applied with:

```
ffmpeg -i Albert_Einstein_Head.jpg \
    -vf "scale=400:-1,crop=400:400:0:60" portrait.png
```

This fixture is the default subject of the `-d:wav2lipLive` test in
`tests/twav2lip.nim`. The test honours `$GUI_ASSERT_WAV2LIP_TEST_AVATAR`
as an override; supply any portrait PNG/JPG with a recognisable face.
