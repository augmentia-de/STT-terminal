//! HTTP daemon exposing the STT core to remote/terminal triggers via REST API.
//! 
/// Endpoints:
/// - `GET  /health`             → Returns string "ok"
/// - `POST /dictate/start`      → Begin microphone capture (push-to-talk)
/// - `POST /dictate/stop`       → Stop capture, transcribe, optionally forward to LLM
/// - `POST /agent/audio`        → Accept uploaded WAV audio and return JSON transcript
///
/// The daemon is intentionally thin: all recording/inference is delegated to
/// the [`ocw_stt`] crate's Dictation struct, and terminal injection to [`crate::inject`].

use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};

use ocw_stt::{resample_mono, Dictation};
use serde::Serialize;
use tracing::{error, warn};

use crate::{config::Config, config::expand_tilde, inject};

/// Shared, thread-safe recorder wrapping the [`ocw_stt::Dictation`] core with an atomic flag
/// tracking whether a session is currently active. The inner mutex serializes access to
/// Dictation because only one recording can happen at any given moment.
pub struct Recorder {
    inner: Mutex<Dictation>,
    is_recording: AtomicBool,
}

impl Recorder {
    /// Create a new recorder backed by Dictation at the given model directory.
    pub fn new(model_dir: &std::path::Path) -> Self {
        Self {
            inner: Mutex::new(Dictation::new(model_dir)),
            is_recording: AtomicBool::new(false),
        }
    }

    /// Check if currently in a recording session
    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::SeqCst)
    }

    /// Start microphone capture. Returns error if already recording or no verified model present.
    pub fn start(&self) -> Result<(), String> {
        if self.is_recording() {
            return Err("Already recording".to_owned());
        }

        let dict = self.inner.lock().map_err(|_| "Recorder mutex poisoned".to_string())?;
        dict.start()?;
        self.is_recording.store(true, Ordering::SeqCst);
        Ok(())
    }

    /// Stop capture and run final transcription on buffered samples
    pub fn stop_and_transcribe(&self) -> Result<String, String> {
        if !self.is_recording() {
            return Err("Not currently recording".to_owned());
        }

        self.is_recording.store(false, Ordering::SeqCst);
        let dict = self.inner.lock().map_err(|_| "Recorder mutex poisoned".to_string())?;
        dict.stop_and_transcribe()
    }

    /// Discard the current in-memory recording without processing further.
    pub fn cancel(&self) {
        self.is_recording.store(false, Ordering::SeqCst);
        if let Ok(dict) = self.inner.lock() {
            dict.cancel();
        }
    }

    /// Transcribe raw mono f32 samples that are already resampled to Whisper's expected rate.
    #[allow(dead_code)]
    pub fn transcribe_samples(&self, model_path: &std::path::Path, samples: &[f32]) -> Result<String, String> {
        ocw_stt::transcribe(model_path, samples)
    }

    /// Resolve model filename from config-provided directory
    pub fn model_path(&self, model_dir: &std::path::Path) -> PathBuf {
        model_dir.join(ocw_stt::DEFAULT_MODEL_FILE)
    }
}

/// Cloneable application state shared across all handler functions.
#[derive(Clone)]
pub struct AppState {
    pub recorder: Arc<Recorder>,
    pub config: Arc<Config>,
}

impl AppState {
    /// Construct fresh app state from parsed configuration.
    pub fn new(config: Config) -> Self {
        let model_dir = expand_tilde(&config.model_dir);
        Self {
            recorder: Arc::new(Recorder::new(&model_dir)),
            config: Arc::new(config),
        }
    }
}

/// Build the complete axum router wiring every endpoint to appropriate handlers.
pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/dictate/start", post(dictate_start))
        .route("/dictate/stop", post(dictate_stop))
        .route("/dictate/cancel", post(dictate_cancel))
        .route("/agent/audio", post(agent_audio))
        .with_state(state)
}

async fn health() -> &'static str {
    "ok"
}

/// POST /dictate/start — begin recording session immediately upon request arrival.
async fn dictate_start(State(state): State<AppState>) -> impl IntoResponse {
    let recorder = state.recorder.clone();

    let outcome = tokio::task::spawn_blocking(move || recorder.start())
        .await
        .map_err(|e| format!("Recorder thread panicked: {}", e))
        .and_then(std::convert::identity);

    match outcome {
        Ok(_) => (StatusCode::OK, "recording started".to_string()).into_response(),
        Err(msg) if msg.contains("Already recording") => {
            (StatusCode::CONFLICT, msg).into_response()
        }
        Err(e) => {
            error!("Start failed: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, format!("Error starting: {}", e)).into_response()
        }
    }
}

/// POST /dictate/stop — stop capturing, produce final text result then optionally inject into target device
async fn dictate_stop(
    State(state): State<AppState>,
) -> impl IntoResponse {
    let recorder = state.recorder.clone();
    let config = state.config.clone();

    let transcript_result = tokio::task::spawn_blocking(move || recorder.stop_and_transcribe())
        .await
        .map_err(|e| format!("Stop worker panicked: {}", e))
        .and_then(std::convert::identity);

    let transcript = match transcript_result {
        Ok(text) => text,
        Err(msg) if msg.contains("Not currently recording") => {
            return (StatusCode::BAD_REQUEST, Json(StopResponse {
                transcript: String::new(),
                injected: false,
                error: Some(msg),
            })).into_response();
        }
        Err(e) => {
            error!("Transcription error: {}", e);
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(StopResponse {
                transcript: String::new(),
                injected: false,
                error: Some(format!("Failed: {}", e)),
            })).into_response();
        }
    };

    // Handle silence case — nothing to inject or return as error
    if transcript.is_empty() {
        warn!("Silent recording discarded");
        return (StatusCode::OK, Json(StopResponse {
            transcript: String::new(),
            injected: false,
            error: Some("Silence detected; no transcript produced".to_string()),
        })).into_response();
    }

    // Attempt real-world injection based on configured backend
    let injection_ok = match inject::inject(&config, &transcript) {
        Ok(_) => true,
        Err(e) => {
            warn!("Injection failed: {}", e);
            false
        }
    };

    let response = (StatusCode::OK, Json(StopResponse {
        transcript,
        injected: injection_ok,
        error: None,
    }));
    
    response.into_response()
}

/// POST /dictate/cancel — abandon the ongoing recording silently
async fn dictate_cancel(State(state): State<AppState>) -> impl IntoResponse {
    let recorder = state.recorder.clone();
    let _ = tokio::task::spawn_blocking(move || recorder.cancel()).await;
    "cancelled".to_owned()
}

#[derive(Serialize)]
struct StopResponse {
    transcript: String,
    injected: bool,
    error: Option<String>,
}

#[derive(Serialize)]
struct AgentAudioResponse {
    transcript: String,
    stt_model: &'static str,
    error: Option<String>,
}

/// POST /agent/audio — accept arbitrary WAV payload and return structured JSON output
async fn agent_audio(
    State(state): State<AppState>,
    body: axum::body::Bytes,
) -> impl IntoResponse {
    let model_path = state.recorder.model_path(&state.config.model_dir);

    let result = tokio::task::spawn_blocking(move || {
        decode_wav_and_transcribe(&model_path, &body)
    })
    .await;

    match result {
        Ok(Ok(transcript)) => {
            let status = if transcript.trim().len() < 3 {
                warn!("Short/noisy transcript discarded: '{}'", transcript);
                (StatusCode::BAD_REQUEST, Json(AgentAudioResponse {
                    transcript: String::new(),
                    stt_model: "whisper-base.en",
                    error: Some("Too short/noisy input".to_string()),
                }))
            } else {
                (StatusCode::OK, Json(AgentAudioResponse {
                    transcript,
                    stt_model: "whisper-base.en",
                    error: None,
                }))
            };

            status.into_response()
        }
        Ok(Err(msg)) => {
            warn!("Transcription failed: {}", msg);
            (StatusCode::BAD_REQUEST, Json(AgentAudioResponse {
                transcript: String::new(),
                stt_model: "whisper-base.en",
                error: Some(msg),
            })).into_response()
        }
        Err(e) => {
            error!("Worker panic: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, Json(AgentAudioResponse {
                transcript: String::new(),
                stt_model: "whisper-base.en",
                error: Some(format!("worker panicked: {}", e)),
            })).into_response()
        }
    }
}

/// Decode raw bytes as WAV format then feed samples through whisper.cpp inference pipeline
fn decode_wav_and_transcribe(model_path: &std::path::Path, wav_bytes: &[u8]) -> Result<String, String> {
    let (samples, sample_rate) = decode_wav_to_f32(wav_bytes)?;
    let resampled = resample_mono(&samples, sample_rate);
    ocw_stt::transcribe(model_path, &resampled)
}

/// Minimal WAV parser extracting PCM data into normalized float range [-1..+1]
fn decode_wav_to_f32(data: &[u8]) -> Result<(Vec<f32>, u32), String> {
    if data.len() < 44 {
        return Err("Invalid WAV: too small header".to_owned());
    }

    // Verify RIFF chunk ID
    if &data[0..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return Err("Invalid WAV: missing RIFF/WAVE identifier".to_owned());
    }

    // Locate fmt subchunk
    let mut offset = 12;
    while offset + 8 <= data.len() {
        let id = &data[offset..offset + 4];
        if id == b"fmt " {
            let length = u32::from_le_bytes([data[offset+4], data[offset+5], data[offset+6], data[offset+7]]) as usize;
            
            // Parse fields within fmt chunk
            let audio_format = u16::from_le_bytes([data[offset + 8], data[offset + 9]]);
            let channels = u16::from_le_bytes([data[offset + 10], data[offset + 11]]);
            let sample_rate = u32::from_le_bytes([data[offset + 12], data[offset + 13], data[offset + 14], data[offset + 15]]);
            let bits_per_sample = u16::from_le_bytes([data[offset + 22], data[offset + 23]]);

            if audio_format != 1 {
                return Err(format!("WAV format {} not supported (expected PCM=1)", audio_format));
            }

            // Move past header to actual data chunk after this fmt block
            let data_offset = offset + 8 + length;
            if data_offset + 8 > data.len() {
                return Err("Missing data chunk reference".to_owned());
            }

            if &data[data_offset..data_offset + 4] != b"data" {
                return Err("Expected 'data' chunk marker".to_owned());
            }

            let byte_count = u32::from_le_bytes([data[data_offset+4], data[data_offset+5], data[data_offset+6], data[data_offset+7]]);
            let start = data_offset + 8;
            let end = (start + byte_count as usize).min(data.len());

            let raw = &data[start..end];
            let samples: Vec<f32> = match bits_per_sample {
                16 => raw.chunks_exact(2)
                    .map(|bytes| i16::from_le_bytes([bytes[0], bytes[1]]) as f32 / 32768.0)
                    .collect(),
                24 => raw.chunks_exact(3)
                    .map(|bytes| {
                        let val = ((bytes[2] as i32) << 16) | ((bytes[1] as i32) << 8) | (bytes[0] as i32);
                        val as f32 / 8388608.0
                    })
                    .collect(),
                32 => raw.chunks_exact(4)
                    .map(|bytes| i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f32 / 2147483648.0)
                    .collect(),
                _ => return Err(format!("Unsupported bit depth: {}", bits_per_sample)),
            };

            // Handle multi-channel audio by averaging each frame into single channel (mono)
            if channels > 1 {
                let mixed = samples.chunks(channels as usize)
                    .map(|frame| frame.iter().sum::<f32>() / channels as f32)
                    .collect();
                return Ok((mixed, sample_rate));
            }

            return Ok((samples, sample_rate));
        }

        // Advance offset safely past current chunk
        let chunk_length = u32::from_le_bytes([data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7]]);
        offset += 8 + chunk_length as usize;
    }

    Err("Could not find valid fmt chunk inside WAV file".to_owned())
}
