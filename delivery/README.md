# STT Terminal Injection — Standalone Delivery

A fully deployable, dependency-light bundle of the STT Terminal Injection daemon.
**No Rust/cargo/libclang (build toolchain) is required** — the binary is pre-built.

Only normal Linux system libraries are used (ALSA, X11, libxdo). If any are missing,
`install-deps.sh` installs them via `apt` automatically.

## Contents

| File | Purpose |
|------|---------|
| `stt-terminject` | Pre-built Linux x86-64 daemon binary |
| `config.json` | Daemon configuration (model, hotkey, injection) |
| `stt.sh` | Lifecycle manager (setup/start/restart/stop/status/logs/...) |
| `install-deps.sh` | Installs missing libs (apt) + downloads/verifies the model |
| `README.md` | This file |

On first run on a new machine:

```bash
./stt.sh setup
```

This (1) installs any missing system libraries, (2) downloads and verifies the
Whisper model, (3) installs the daemon as a systemd user service (autostart at
login) and (4) starts it.

## Useful commands

```bash
./stt.sh start        # start daemon (systemd or direct fallback)
./stt.sh restart      # restart
./stt.sh stop         # stop
./stt.sh status       # status + health check
./stt.sh logs         # follow logs
./stt.sh config       # show/edit config.json
./stt.sh install-deps # only ensure libs + model
./stt.sh install      # install systemd user service (autostart)
./stt.sh uninstall    # remove service + stop
```

## Configuration (`config.json`)

Key options:

- `model_file` — Whisper model file. `ggml-base.en.bin` (English only) or
  `ggml-small.bin` (**multilingual, incl. German**, recommended).
- `hotkey` — push-to-talk global hotkey, e.g. `{"modifiers":["alt"],"key":"q"}`.
- `tmux_session` — inject into a tmux session via `send-keys`; leave `null` for
  clipboard + Ctrl+V injection.
- `use_clipboard` — `true` = clipboard + simulated Ctrl+V.
- `auto_enter` — press Enter after injecting text.
- `listen_port` — HTTP API port (default `3210`).

## Manual model download

If you prefer to download the model yourself:

```bash
mkdir -p ~/.cache/ocw-stt/models
cd ~/.cache/ocw-stt/models
# English only (~142 MB):
curl -L -O https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
# Multilingual incl. German (~466 MB):
curl -L -O https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

Then set `model_file` in `config.json` accordingly and run `./stt.sh restart`.

## HTTP API

- `GET  /health` → `ok`
- `POST /dictate/start`
- `POST /dictate/stop`
- `POST /dictate/cancel`
- `POST /agent/audio` (WAV upload → transcript)
