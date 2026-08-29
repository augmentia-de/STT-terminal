# stt-terminject

Push-to-Talk Speech-to-Text daemon for Linux terminals. Transcribes voice input into any active tmux session or desktop clipboard.

## Features

- **Whisper.cpp local inference** — 100% offline, no cloud dependency
- **Global hotkey push-to-talk** — press and hold to record, release to transcribe
- **tmux injection** — inject transcripts directly into your terminal via `send-keys`
- **Desktop injection** — fallback to clipboard + Ctrl+V for non-tmux environments
- **Remote access** — HTTP REST API on localhost for Android phones, web browsers, Discord bots
- **WAV upload endpoint** — accept pre-recorded audio files from external devices

## Architecture

```
┌──────────────┐    ┌───────────────────┐    ┌───────────────────┐
│  Input        │    │  Bridge/Proxy     │    │  Terminal App     │
│  (Microphone) │───►│  (HTTP/Hotkey)   │───►│  (tmux/bash)      │
│               │    │                   │    │                   │
│ • Global Hotkey│    │ • REST API       │    │ • OpenCode        │
│ • Web Browser │    │ • tmux send-keys │    │ • Claude Code     │
│ • Android App │    │ • Clipboard+Ctrl │    │ • Shell           │
└──────────────┘    └───────────────────┘    └───────────────────┘
                        ▲
                  ┌──────┴──────┐
                  │  STT Core   │
                  │ whisper.cpp │
                  └─────────────┘
```

## Installation

### Prerequisites

Install system dependencies:

```bash
sudo apt install libasound2-dev libxdo-dev cmake gcc pkg-config clang
```

### Build

```bash
cd stt-terminject
cargo build --release
cp target/release/stt-terminject /usr/local/bin/
```

### Install Model

On first run, the daemon downloads `ggml-base.en.bin` (~142 MB) automatically. To install manually:

```bash
mkdir -p ~/.cache/ocw-stt/models
curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin \
  -o ~/.cache/ocw-stt/models/ggml-base.en.bin
```

## Configuration

Create `~/.config/stt-terminject/config.json`:

```json
{
  "model_dir": "~/.cache/ocw-stt/models",
  "tmux_session": null,
  "use_clipboard": true,
  "auto_enter": false,
  "listen_port": 3210,
  "hotkey": {
    "modifiers": ["ctrl", "alt"],
    "key": "space"
  }
}
```

| Field | Type | Default | Description |
|---|---|---|---|
| `model_dir` | string | `~/.cache/ocw-stt/models` | Path to Whisper model directory |
| `tmux_session` | string/null | `null` | tmux session name for injection; disables clipboard when set |
| `use_clipboard` | bool | `true` | Use clipboard+Ctrl+V instead of tmux |
| `auto_enter` | bool | `false` | Press Enter after injecting transcript |
| `listen_port` | number | `3210` | HTTP listen port |
| `hotkey` | object | See below | Push-to-talk hotkey configuration |

### Hotkey Keys

Supported key names: `a-z`, `0-9`, `space`, `enter`, `return`, `tab`, `backspace`, `escape`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `pause`, `insert`, `printscreen`, `scrolllock`, `capslock`, `numlock`, `f1-f24`.

### CLI Overrides

All config fields can be overridden from the command line:

```bash
stt-terminject \
  --model-dir ~/models \
  --tmux-session work \
  -p 8080 \
  --config ~/.config/stt-terminject/custom.json
```

## Usage

### Desktop Mode (Clipboard)

```bash
stt-terminject &
# Hold Ctrl+Alt+Space to dictate, release to submit
```

Transcripts are copied to clipboard and Ctrl+V is simulated into the active window.

### tmux Injection Mode

```bash
stt-terminject --tmux-session work --use-clipboard=false &
# Hold Ctrl+Alt+Space to dictate, release to submit into tmux
```

Text is injected via `tmux send-keys` with proper space escaping. Optionally followed by Enter if `auto_enter: true`.

### Remote Access via HTTP

Start the daemon without a hotkey (headless server):

```bash
stt-terminject --model-dir ~/.cache/ocw-stt/models --tmux-session work &
```

#### Push-to-Talk via curl

```bash
# Start recording
curl -X POST http://localhost:3210/dictate/start

# Stop recording + transcribe + inject
curl -X POST http://localhost:3210/dictate/stop
# → {"transcript":"refactor main.rs","error":null,"injected":true}
```

#### Upload WAV file for transcription

```bash
curl -X POST -H "Content-Type: application/octet-stream" \
  --data-binary @recording.wav \
  http://localhost:3210/agent/audio
# → {"transcript":"hello world","stt_model":"whisper-base.en"}
```

#### Health check

```bash
curl http://localhost:3210/health
# → ok
```

### Systemd Service

Enable automatic startup on login:

```bash
cp stt-terminject.service ~/.config/systemd/user/stt-terminject.service
systemctl --user enable --now stt-terminject
journalctl --user -u stt-terminject -f
```

Stop/disable:

```bash
systemctl --user stop stt-terminject
systemctl --user disable stt-terminject
```

### Android / Mobile as Input Device

Use your phone's browser to reach `http://server.local:3210`:

```html
<!-- Simple push-to-talk page -->
<!DOCTYPE html>
<html>
<head><title>STT</title></head>
<body>
  <button ontouchstart="start()" ontouchend="stop()">Hold to Speak</button>
  <div id="result"></div>
  <script>
    let stream; async function start() {
      stream = await navigator.mediaDevices.getUserMedia({audio:true});
      const r = new MediaRecorder(stream);
      const chunks=[];
      r.ondataavailable=e=>chunks.push(e.data);
      r.onstop=async()=>{
        const blob=new Blob(chunks,{type:'audio/webm'});
        // Convert to WAV on server or use binary wav endpoint
        const resp=await fetch('http://server.local:3210/agent/audio',{
          method:'POST',body:blob
        });
        document.getElementById('result').textContent=(await resp.json()).transcript;
      };
      r.start();
    }
    function stop() { stream.getTracks().forEach(t=>t.stop()); }
  </script>
</body>
</html>
```

## API Reference

### Endpoints

| Endpoint | Method | Body | Returns |
|---|---|---|---|
| `/health` | GET | — | `string` |
| `/dictate/start` | POST | — | `string` (status) |
| `/dictate/stop` | POST | — | JSON `{ transcript, error?, injected }` |
| `/dictate/cancel` | POST | — | `string` (cancelled) |
| `/agent/audio` | POST | `application/octet-stream` (WAV) | JSON `{ transcript, stt_model, error? }` |

### Response Codes

| Code | Meaning |
|---|---|
| 200 | Success |
| 400 | Bad request (invalid WAV, empty transcript) |
| 409 | Already recording |
| 500 | Internal error (transcription failure, worker crash) |

## Project Structure

```
stt-terminject/
├── Cargo.toml              # Dependencies: ocw-stt, axum, tokio, enigo, arboard, global-hotkey
├── src/
│   ├── main.rs             # Entry point, CLI parsing, model init, hotkey loop
│   ├── config.rs           # Config loading/saving, tilde expansion, hotkey schema
│   ├── hotkey.rs           # Global hotkey registration (X11/Wayland), event polling
│   ├── inject.rs           # tmux send-keys or clipboard+Ctrl+V injection
│   └── daemon.rs           # HTTP server: /dictate/*, /agent/audio, WAV decoding
├── stt-terminject.service  # systemd user service unit
└── config.example.json     # Template configuration
```

## Troubleshooting

### "No microphone available"

```bash
arecord -l                    # List capture devices
cat /proc/asound/cards        # Verify sound card detection
```

Ensure PulseAudio/PipeWire is running. On Wayland, some compositors require explicit microphone permission grants.

### Hotkey doesn't respond

On X11, verify the key isn't already grabbed by another process:
```bash
xdotool getactivewindow key ctrl+alt+space  # Test injection
xev  # Inspect key events
```

On Wayland, compositor support varies. Some require installing the global-shortcuts portal or using specific extensions (KDE/KWin, GNOME extensions).

### No tmux session found

Verify tmux is running and the session exists:
```bash
tmux list-sessions
```

If `--tmux-session` points to a non-existent session, the daemon falls back to clipboard injection.

### Audio quality issues

- Whisper base.en is optimized for English speech
- Background noise affects accuracy; use a directional microphone
- For longer recordings (>30s), consider larger models (`medium`, `large-v3`)
- The daemon currently only supports the `base.en` model; custom models require modifying `ocw_stt::Dictation::new()` path

## License

MIT

## References

- [ocw-stt](https://github.com/openworker/stt) — Rust library wrapping whisper.cpp
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) —C/C++ inference engine
- [global-hotkey](https://crates.io/crates/global-hotkey) — Cross-platform global hotkeys
- [enigo](https://crates.io/crates/enigo) — Keyboard/mouse input simulation
- [arboard](https://crates.io/crates/arboard) — Cross-platform clipboard management
