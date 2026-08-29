//! Terminal injection — getting transcribed text into active prompt line.
//! 
/// Two strategies depending on config:
/// - **tmux `send-keys`** — works headless, no display required.
/// - **Clipboard + simulated Ctrl+V** — for desktop environments (via [`arboard`]
///   for the clipboard and [`enigo`] for key simulation).

use std::process::Command;

use arboard::Clipboard;
use enigo::{Direction, Enigo, Key, Keyboard, Settings};

use crate::config::Config;

/// Outcome type describing where/how the transcript was injected
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InjectOutcome {
    /// Injected via tmux and then pressed Enter (auto_enter mode)
    TmuxWithEnter,

    /// Injected via tmux, no Enter press afterward
    Tmux,

    /// Injected via clipboard + simulated Ctrl+V, followed by Enter
    ClipboardWithEnter,

    /// Injected via clipboard + simulated Ctrl+V only (no Enter)
    Clipboard,
}

/// High-level injection function delegating to appropriate backend based on config.
/// Returns Ok(outcome) on success, Err(message) describing what went wrong.
pub fn inject(config: &Config, text: &str) -> Result<InjectOutcome, String> {
    if text.is_empty() {
        return Err("Refusing to inject empty transcript".to_owned());
    }

    if let Some(session) = &config.tmux_session {
        inject_tmux(session, text, config.auto_enter)
    } else {
        inject_desktop(text, config.auto_enter)
    }
}

fn inject_tmux(session: &str, text: &str, auto_enter: bool) -> Result<InjectOutcome, String> {
    // Spaces must be escaped for tmux otherwise it splits arguments
    let escaped = text.replace(' ', "\\ ");
    
    let output = Command::new("tmux")
        .arg("send-keys")
        .arg("-t")
        .arg(session)
        .arg(&escaped)
        .output()
        .map_err(|e| format!("tmux not found or not running: {}", e))?;
        
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("tmux send-keys failed: {}", stderr.trim()));
    }

    if auto_enter {
        // Also press Enter after injecting text
        let output = Command::new("tmux")
            .args(["send-keys", "-t", session, "Enter"])
            .output()
            .map_err(|e| format!("tmux send-keys for Enter failed: {}", e))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("tmux send-keys Enter failed: {}", stderr.trim()));
        }
        Ok(InjectOutcome::TmuxWithEnter)
    } else {
        Ok(InjectOutcome::Tmux)
    }
}

fn inject_desktop(text: &str, auto_enter: bool) -> Result<InjectOutcome, String> {
    // Write text to system clipboard first (fast operation even for long strings)
    let mut clipboard = Clipboard::new()
        .map_err(|e| format!("Could not open system clipboard: {}", e))?;
    clipboard.set_text(text.to_owned())
        .map_err(|e| format!("Could not write to system clipboard: {}", e))?;

    // Small delay to ensure clipboard content is fully set
    std::thread::sleep(std::time::Duration::from_millis(50));

    // Simulate Ctrl+V (bracketed paste) — the universal paste shortcut in
    // terminals and browsers. Ctrl+Shift+V is GNOME/GTK-specific and only
    // works in some apps, so we default to the broader Ctrl+V.
    let mut enigo = Enigo::new(&Settings::default())
        .map_err(|e| format!("Could not initialize input simulation: {:?}", e))?;

    let chord: Vec<(Key, Direction)> = vec![
        (Key::Control, Direction::Press),
        (Key::Unicode('v'), Direction::Click),
        (Key::Control, Direction::Release),
    ];
    for (key, dir) in chord {
        enigo.key(key, dir)
            .map_err(|e| format!("Input error (Ctrl+V): {:?}", e))?;
    }

    if auto_enter {
        enigo.key(Key::Return, Direction::Click)
            .map_err(|e| format!("Input error: {:?}", e))?;
        Ok(InjectOutcome::ClipboardWithEnter)
    } else {
        Ok(InjectOutcome::Clipboard)
    }
}
