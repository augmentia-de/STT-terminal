# ocw-stt (vendored)

**Local, offline speech-to-text engine** for STT Terminal Injection.

This directory contains a **vendored copy** of the `ocw-stt` crate so that this
repository is fully self-contained (no external git checkout or absolute path
is required to build).

## Provenance

- **Upstream:** `stt` directory of [`andrewyng/openworker`](https://github.com/andrewyng/openworker)
- **Base version:** tag `v0.2.1` (commit `7fc3ee6`)
- **License:** MIT

## Differences vs. upstream v0.2.1

Identical to upstream **except** three items were made `pub` (upstream keeps
them private) so the daemon can re-use them for the WAV-upload HTTP endpoint:

| Item | Upstream | Vendored |
|------|----------|----------|
| `resample_mono` | `fn` (private) | `pub fn` |
| `transcribe` | `fn` (private) | `pub fn` |
| `WHISPER_SAMPLE_RATE` | `const` (private) | `pub const` |

Everything else matches upstream at `v0.2.1`.

## Why vendored instead of git dependency

The public `v0.2.1` exposes these helpers only internally (used by
`Dictation::stop_and_transcribe`). This project additionally transcribes
uploaded WAV files, which requires standalone access to `transcribe` and
`resample_mono`. A git/registry dependency cannot provide that, so we vendor a
lightly-patched copy.

## Updating

To refresh this vendored copy after an upstream change, re-apply the 3 `pub`
modifiers from the table above onto the new upstream `src/lib.rs`.
