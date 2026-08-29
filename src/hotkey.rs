//! Global hotkey registration and event handling for push-to-talk functionality
//! 
/// Uses the `global_hotkey` crate which transparently supports X11 and Wayland through
/// OS-level grab protocols (XGrabKey / wlroots portal). On X11 it will work as expected;
/// on Wayland support depends on compositor-specific implementations.

use std::sync::{Arc, Mutex};

use global_hotkey::{
    hotkey::{Code, HotKey, Modifiers},
    GlobalHotKeyEvent, GlobalHotKeyManager,
};

use crate::config::{HotkeyConfig, Modifier};

/// State of a registered push-to-talk hotkey
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyState {
    /// Physical button/switch was pressed down
    Pressed,

    /// Physical button/switch was released back up
    Released,
}

/// Holds the reference to a registered global hotkey instance together with internal state.
/// Dropping this will unregister the associated hotkey from the system.
pub struct HotkeyListener {
    #[allow(dead_code)]
    manager: Arc<Mutex<GlobalHotKeyManager>>,
    hotkey: HotKey,
}

impl HotkeyListener {
    /// Register a global hotkey described by configuration.
    /// Returns error if registration fails (e.g., key already grabbed elsewhere).
    pub fn register(config: &HotkeyConfig) -> Result<Self, String> {
        let manager = Arc::new(Mutex::new(
            GlobalHotKeyManager::new()
                .map_err(|e| format!("Failed to create global hotkey manager: {}", e))?
        ));

        let modifiers = map_modifiers(&config.modifiers);
        let code = map_code(&config.key)
            .ok_or_else(|| format!("Unsupported key in hotkey config: '{}'", config.key))?;

        let hk = HotKey::new(Some(modifiers), code);
        manager.lock().unwrap()
            .register(hk.clone())
            .map_err(|e| format!("Failed to register global hotkey: {}", e))?;

        Ok(Self { manager, hotkey: hk })
    }

    /// Non-blocking check for a new hotkey event. Returns None if no new events available.
    #[allow(dead_code)]
    pub fn poll(&self, last_state: HotkeyState) -> Option<HotkeyState> {
        if let Ok(event) = GlobalHotKeyEvent::receiver().try_recv() {
            if event.id() == self.hotkey.id() {
                // Toggle between states since many backends only fire once per press/release cycle
                let next = match last_state {
                    HotkeyState::Released => HotkeyState::Pressed,
                    HotkeyState::Pressed => HotkeyState::Released,
                };
                return Some(next);
            }
        }
        None
    }

    /// Blocking wait until the next hotkey event for this key arrives.
    /// Used by the background loop to block efficiently until user presses/releases.
    pub fn recv(&self, last_state: HotkeyState) -> HotkeyState {
        let receiver = GlobalHotKeyEvent::receiver();
        loop {
            let event = match receiver.recv() {
                Ok(ev) => ev,
                Err(_) => continue, // ignore closed channel errors gracefully
            };
            if event.id() == self.hotkey.id() {
                let next = match last_state {
                    HotkeyState::Released => HotkeyState::Pressed,
                    HotkeyState::Pressed => HotkeyState::Released,
                };
                return next;
            }
        }
    }
}

// --- Helper functions for mapping config strings → global_hotkey types ------

fn map_modifiers(mods: &[Modifier]) -> Modifiers {
    let mut out = Modifiers::empty();
    for m in mods {
        match m {
            Modifier::Ctrl => out |= Modifiers::CONTROL,
            Modifier::Alt => out |= Modifiers::ALT,
            Modifier::Shift => out |= Modifiers::SHIFT,
            Modifier::Meta | Modifier::Super => out |= Modifiers::SUPER,
        }
    }
    out
}

/// Map a textual key name (like "space", "enter", 'q') to a global_hotkey Code variant
fn map_code(key: &str) -> Option<Code> {
    use Code::*;
    let normalized = key.trim().to_lowercase();

    match normalized.as_str() {
        // Common keys
        "space" | "spacebar" => Some(Space),
        "enter" | "return" => Some(Enter),
        "tab" => Some(Tab),
        "backspace" => Some(Backspace),
        "delete" => Some(Delete),
        "escape" | "esc" => Some(Escape),
        "up" => Some(ArrowUp),
        "down" => Some(ArrowDown),
        "left" => Some(ArrowLeft),
        "right" => Some(ArrowRight),
        "home" => Some(Home),
        "end" => Some(End),
        "pageup" => Some(PageUp),
        "pagedown" => Some(PageDown),
        "pause" => Some(Pause),
        "insert" => Some(Insert),
        "printscreen" | "print" => Some(PrintScreen),
        "scrolllock" => Some(ScrollLock),
        "capslock" => Some(CapsLock),
        "numlock" => Some(NumLock),

        // Function keys F1–F24
        "f1" => Some(F1), "f2" => Some(F2), "f3" => Some(F3), "f4" => Some(F4),
        "f5" => Some(F5), "f6" => Some(F6), "f7" => Some(F7), "f8" => Some(F8),
        "f9" => Some(F9), "f10" => Some(F10), "f11" => Some(F11), "f12" => Some(F12),
        "f13" => Some(F13), "f14" => Some(F14), "f15" => Some(F15), "f16" => Some(F16),
        "f17" => Some(F17), "f18" => Some(F18), "f19" => Some(F19), "f20" => Some(F20),
        "f21" => Some(F21), "f22" => Some(F22), "f23" => Some(F23), "f24" => Some(F24),

        // Single letters A-Z
        _ if normalized.len() == 1 => {
            let c = normalized.chars().next()?;
            match c {
                'a'..='z' => Some(match c {
                    'a' => KeyA, 'b' => KeyB, 'c' => KeyC, 'd' => KeyD,
                    'e' => KeyE, 'f' => KeyF, 'g' => KeyG, 'h' => KeyH,
                    'i' => KeyI, 'j' => KeyJ, 'k' => KeyK, 'l' => KeyL,
                    'm' => KeyM, 'n' => KeyN, 'o' => KeyO, 'p' => KeyP,
                    'q' => KeyQ, 'r' => KeyR, 's' => KeyS, 't' => KeyT,
                    'u' => KeyU, 'v' => KeyV, 'w' => KeyW, 'x' => KeyX,
                    'y' => KeyY, 'z' => KeyZ, _ => return None,
                }),
                '0'..='9' => Some(match c {
                    '0' => Digit0, '1' => Digit1, '2' => Digit2, '3' => Digit3,
                    '4' => Digit4, '5' => Digit5, '6' => Digit6, '7' => Digit7,
                    '8' => Digit8, '9' => Digit9, _ => return None,
                }),
                _ => None,
            }
        }
        _ => None,
    }
}
