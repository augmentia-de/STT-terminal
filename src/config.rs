//! Configuration handling — loading from disk, CLI overrides, serialization
//! 
//! Config file format (JSON):
//! {
//!   "model_dir": "~/.cache/ocw-stt/models",
//!   "tmux_session": "work",
//!   "use_clipboard": true,
//!   "auto_enter": false,
//!   "listen_port": 3210,
//!   "hotkey": {
//!     "modifiers": ["ctrl", "alt"],
//!     "key": "space"
//!   }
//! }

use std::{
    collections::HashSet,
    env, fs,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};

/// Default port for HTTP API endpoints
pub const DEFAULT_LISTEN_PORT: u16 = 3210;

/// Default model directory under user's cache
pub fn default_model_dir() -> PathBuf {
    let home_dir = home_dir();
    home_dir.join(".cache/ocw-stt/models")
}

/// Resolve user's home directory
pub fn home_dir() -> PathBuf {
    if let Ok(path) = env::var("HOME") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    // Fallback for edge cases where HOME isn't set
    PathBuf::from("~")
}

/// Expand a leading `~` in a path to the actual home directory
pub fn expand_tilde(path: &Path) -> PathBuf {
    match path.to_string_lossy().as_ref() {
        s if s.starts_with("~/") => {
            let rest = &s[2..];
            home_dir().join(rest)
        }
        s if s == "~" => home_dir(),
        _ => path.to_path_buf(),
    }
}

/// Hotkey modifiers supported by the global_hotkey crate
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Modifier {
    Ctrl,
    Alt,
    Shift,
    Meta,
    Super,
}

/// Represents a configured push-to-talk hotkey
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotkeyConfig {
    /// Modifiers that must be held together with the key
    #[serde(default)]
    pub modifiers: Vec<Modifier>,

    /// The main key (e.g., 'q', 'space', 'f1'...)
    pub key: String,
}

impl Default for HotkeyConfig {
    fn default() -> Self {
        Self {
            modifiers: vec![Modifier::Ctrl, Modifier::Alt],
            key: "space".to_owned(),
        }
    }
}

/// Top-level daemon configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Directory containing the Whisper GGML model (ggml-base.en.bin)
    #[serde(default = "default_model_dir")]
    pub model_dir: PathBuf,

    /// If set, inject transcript into this tmux session using send-keys
    #[serde(default)]
    pub tmux_session: Option<String>,

    /// When true use clipboard + Ctrl+V instead of tmux send-keys
    #[serde(default = "default_true")]
    pub use_clipboard: bool,

    /// Press Enter automatically after injecting the transcript text
    #[serde(default)]
    pub auto_enter: bool,

    /// Port on which the REST API listens
    #[serde(default = "default_port")]
    pub listen_port: u16,

    /// Optional push-to-talk hotkey definition (Ctrl+Space by default)
    #[serde(default)]
    pub hotkey: Option<HotkeyConfig>,
}

fn default_true() -> bool {
    true
}

fn default_port() -> u16 {
    DEFAULT_LISTEN_PORT
}

impl Default for Config {
    fn default() -> Self {
        Self {
            model_dir: default_model_dir(),
            tmux_session: None,
            use_clipboard: true,
            auto_enter: false,
            listen_port: DEFAULT_LISTEN_PORT,
            hotkey: Some(HotkeyConfig::default()),
        }
    }
}

impl Config {
    /// Standard path for the config file under XDG config
    pub fn default_path() -> PathBuf {
        let home = home_dir();
        home.join(".config/stt-terminject/config.json")
    }

    /// Load config from the given path. Returns None if file doesn't exist.
    pub fn load(path: &Path) -> Result<Option<Self>, String> {
        if !path.exists() {
            return Ok(None);
        }
        let raw = fs::read_to_string(path)
            .map_err(|e| format!("Could not read config {}: {}", path.display(), e))?;
        let cfg: Config = serde_json::from_str(&raw)
            .map_err(|e| format!("Invalid JSON in config {}: {}", path.display(), e))?;
        Ok(Some(cfg))
    }

    /// Load config from path, falling back to defaults if missing or invalid
    pub fn load_or_default(path: &Path) -> Self {
        Self::load(path).ok().flatten().unwrap_or_default()
    }

    /// Save config atomically to the given path (create dirs if needed)
    #[allow(dead_code)]
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("Failed to create config dir {}: {}", parent.display(), e))?;
        }
        let serialized = serde_json::to_string_pretty(self)
            .map_err(|e| format!("Serialization error: {}", e))?;
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serialized)
            .map_err(|e| format!("Write error: {}", e))?;
        fs::rename(&tmp, path)
            .map_err(|e| format!("Rename error: {}", e))?;
        Ok(())
    }
}

/// Create a HashSet from a list of modifiers (for comparison purposes)
#[allow(dead_code)]
pub fn modifier_set(mods: &[Modifier]) -> HashSet<Modifier> {
    mods.iter().copied().collect()
}
