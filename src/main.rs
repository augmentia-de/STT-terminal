//! STT Terminal Injection Daemon — Push-to-Talk via Global Hotkeys
//! 
//! Ein einzelner Prozess der:
//! 1. Global Hotkeys registriert (Alt+Q standardmäßig) für Push-to-Talk
//! 2. Ein Microphon streamt, bei Sprachende transkribiert und in das aktive Terminal injiziert
//! 3. Eine REST-API bereitstellt für Remote-Zugriff (Android/Browser/Discord-Bot)
//! 4. Das Whisper-Modell automatisch lädt und verwaltet
//!
//! Keine Python-Skripte, kein Bash - nur eine Binary.

mod config;
mod daemon;
mod hotkey;
mod inject;

use std::{
    path::PathBuf,
    sync::Arc,
};

use clap::Parser;
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

use crate::{
    config::Config,
    daemon::{AppState, Recorder},
    hotkey::{HotkeyListener, HotkeyState},
};

/// CLI argument parser
#[derive(Debug, Parser)]
#[command(name = "stt-terminject", version, about)]
struct Cli {
    /// Path to configuration file (~/.config/stt-terminject/config.json by default)
    #[arg(long, global = true)]
    config: Option<PathBuf>,

    /// Override model directory
    #[arg(long, global = true)]
    model_dir: Option<PathBuf>,

    /// Override model file within model_dir (e.g. ggml-small.bin for German)
    #[arg(long, global = true)]
    model_file: Option<String>,

    /// Override tmux session name for injection (disables clipboard mode)
    #[arg(long, global = true)]
    tmux_session: Option<String>,

    /// Force clipboard injection even if tmux session is set
    #[arg(long, global = true, short = 'c')]
    use_clipboard: bool,

    /// Set auto-enter behavior after injection (presses Enter after injected text)
    #[arg(long, global = true)]
    auto_enter: bool,

    /// HTTP listen port (default: 3210)
    #[arg(short = 'p', long, global = true)]
    listen_port: Option<u16>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Parse CLI args first
    let cli = Cli::parse();

    // Setup logging with env filter support
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("stt_terminject=info")),
        )
        .init();

    // Load configuration from disk or defaults
    let config_path = cli
        .config
        .clone()
        .unwrap_or_else(Config::default_path);
    let mut cfg = Config::load_or_default(&config_path);

    // Apply CLI overrides (they take precedence over config file)
    if let Some(dir) = cli.model_dir {
        cfg.model_dir = config::expand_tilde(&dir);
    }
    if let Some(file) = cli.model_file {
        cfg.model_file = file;
    }
    if let Some(session) = cli.tmux_session {
        cfg.tmux_session = Some(session);
        // If tmux session specified explicitly, disable clipboard unless user asked for it
        if !cli.use_clipboard {
            cfg.use_clipboard = false;
        }
    }
    if let Some(port) = cli.listen_port {
        cfg.listen_port = port;
    }
    // Handle the auto-enter flag separately since it's not in the CLI struct yet
    if cli.auto_enter {
        cfg.auto_enter = true;
    }

    let model_dir = config::expand_tilde(&cfg.model_dir);
    info!("STT Terminal Inject Daemon starting up");
    info!(
        "Configuration loaded from: {}",
        config_path.display()
    );
    info!(
        "Injection method: {}",
        if cfg.tmux_session.is_some() {
            format!("tmux send-keys -> {:?}", cfg.tmux_session)
        } else {
            "Clipboard + Ctrl+V".to_owned()
        }
    );
    info!(
        "HTTP API listening on: {}:{}",
        "127.0.0.1", cfg.listen_port
    );

    // Ensure model is installed & verified before proceeding
    ensure_model(&model_dir, &cfg.model_file)?;

    // Build shared application state containing recorder + config
    let state = AppState::new(cfg.clone());
    let recorder = state.recorder.clone();
    
    // Clone config early so we can pass it to hotkey thread AND use state in server
    let hotkey_config_clone = state.config.clone();

    // Register global hotkey if configured in config (e.g., Ctrl+Space or Alt+Q)
    // This runs in a separate background thread so it doesn't block the HTTP server
    if let Some(hotkey_cfg) = hotkey_config_clone.hotkey.as_ref() {
        match HotkeyListener::register(hotkey_cfg) {
            Ok(listener) => {
                let rec = recorder.clone();
                std::thread::Builder::new()
                    .name("stt-hotkey-loop".into())
                    .spawn(move || push_to_talk_loop(listener, rec, hotkey_config_clone))
                    .expect("Failed to spawn hotkey thread");
            }
            Err(e) => {
                warn!("Could not register global hotkey: {}. Running in server-only mode.", e);
            }
        }
    } else {
        warn!("No hotkey configured. The daemon will only respond to HTTP requests.");
    }

    // Run the HTTP server (blocks until process exits or errors out)
    let port = cfg.listen_port;
    info!("Starting HTTP API server on 127.0.0.1:{}", port);

    let rt = tokio::runtime::Runtime::new()?;
    let addr = format!("127.0.0.1:{}", port);
    
    rt.block_on(async {
        let listener = tokio::net::TcpListener::bind(addr).await?;
        axum::serve(listener, daemon::build_router(state)).await
    })?;

    Ok(())
}

/// Download (if necessary) and verify the Whisper GGML model
fn ensure_model(model_dir: &PathBuf, model_file: &str) -> Result<(), Box<dyn std::error::Error>> {
    let spec = ocw_stt::model_spec_for_file(model_file)
        .unwrap_or(ocw_stt::MODEL_BASE_EN);
    let dictation = ocw_stt::Dictation::with_spec(model_dir, spec);
    let status = dictation.status();

    if status.model_verified {
        info!(
            "Voice model present and verified: {} ({})",
            spec.file, spec.label
        );
        return Ok(());
    }

    if status.model_installed {
        // File is present but not yet verified (e.g. freshly downloaded by the user).
        // Verify in place instead of re-downloading the whole model.
        info!("Voice model present but not verified. Verifying {} ...", spec.file);
        dictation.verify_default_model()?;
        dictation.mark_test_passed()?;
        info!("Voice model verified successfully");
        return Ok(());
    }

    if status.download_in_progress {
        warn!("Model download already in progress elsewhere");
        return Err("Model download already in progress".into());
    }

    info!(
        "Voice model not found locally. Starting download of {} ({:.0} MB)...",
        spec.file,
        spec.bytes as f64 / 1_000_000f64
    );

    dictation.install_default_model_with_progress(|progress| {
        let pct = 100.0 * progress.downloaded_bytes as f64 / progress.total_bytes as f64;
        info!(
            "Downloading voice model: {:.1}% ({:.0} MB / {:.0} MB)",
            pct,
            progress.downloaded_bytes as f64 / 1e6,
            progress.total_bytes as f64 / 1e6
        );
    })?;

    dictation.verify_default_model()?;
    dictation.mark_test_passed()?;
    info!("Voice model installed and verified successfully");
    Ok(())
}

/// Blocking loop that handles push-to-talk via global hotkey events
/// Runs continuously in background waiting for hotkey presses/releases
fn push_to_talk_loop(
    listener: HotkeyListener,
    recorder: Arc<Recorder>,
    config: Arc<Config>,
) {
    let mut current_state = HotkeyState::Released;
    info!("Push-to-Talk loop started. Press registered hotkey to dictate...");

    loop {
        let next = listener.recv(current_state);
        current_state = next;

        match current_state {
            HotkeyState::Pressed => {
                // User just pressed the hotkey — start recording if not already doing so
                if !recorder.is_recording() {
                    match recorder.start() {
                        Ok(_) => info!("Recording started"),
                        Err(e) => warn!("Could not start recording: {}", e),
                    }
                }
            }
            HotkeyState::Released => {
                // User released the hotkey — stop recording, transcribe, inject
                if recorder.is_recording() {
                    match recorder.stop_and_transcribe() {
                        Ok(transcript) if !transcript.is_empty() => {
                            info!("Transcription completed: '{}'", transcript);
                            // Attempt to inject into terminal (tmux or clipboard depending on config)
                            match inject::inject(&config, &transcript) {
                                Ok(_) => info!("Injected transcript into target"),
                                Err(e) => warn!("Failed to inject transcript: {}", e),
                            }
                        }
                        Ok(_) => info!("Recording was silent; discarded"),
                        Err(e) => warn!("Transcription failed: {}", e),
                    }
                }
            }
        }
    }
}
