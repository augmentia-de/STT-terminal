#!/usr/bin/env bash
##############################################################################
# build.sh — Rust-Binary bauen und ins PATH installieren.
#
# Baut eine einzelne statische Rust-Binary (keine Python/Bash Runtimes).
# whisper-rs (bindgen) benötigt die libclang-Pfade aus stt-env.sh, daher
# werden diese hier geladen, falls vorhanden.
#
# Usage:
#   ./build.sh                 # Release-Build + Installation nach ~/.cargo/bin
#   ./build.sh --debug         # Debug-Build (keine Installation)
#   ./build.sh --install DIR   # Zielverzeichnis für die Binary überschreiben
#   ./build.sh --only-build    # Nur bauen, nicht installieren
#   ./build.sh --check         # Nur cargo check (schnell, zum Testen)
##############################################################################

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }

NAME="stt-terminject"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="release"
ONLY_BUILD=0
CHECK_ONLY=0
INSTALL_DIR="${HOME}/.cargo/bin"

# === Argumente parsen ========================================================

for arg in "$@"; do
    case "$arg" in
        --debug)     PROFILE="debug"                                              ;;
        --only-build) ONLY_BUILD=1                                                ;;
        --check)     CHECK_ONLY=1                                                 ;;
        --install)   err "--install needs a directory argument."; exit 2          ;;
        --install=*) INSTALL_DIR="${arg#*=}"                                      ;;
        -h|--help)   sed -n '3,24p' "$0"; exit 0                                  ;;
        *)           err "Unknown argument: $arg"; exit 2                         ;;
    esac
done

cd "$SCRIPT_DIR"

# === Build-Umgebung (libclang für whisper-rs bindgen) =========================

if [[ -f "/tmp/opencode/stt-env.sh" ]]; then
    # shellcheck source=/dev/null
    set +u  # stt-env.sh referenziert evtl. ungesetzte Var (LD_LIBRARY_PATH)
    source "/tmp/opencode/stt-env.sh"
    set -u
    info "Build-Umgebung geladen (libclang/libxdo)."
else
    warn "stt-env.sh nicht gefunden — falls der Build an libclang scheitert, "
    warn "die Env-Datei anlegen und erneut ausführen."
fi

# === Build aktualisieren =====================================================

info "Berechne Änderungen für '${PROFILE}' Profil..."
if ! command -v cargo &>/dev/null; then
    err "cargo nicht im PATH. Rust installieren: https://rustup.rs"
    exit 1
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    info "cargo check (ohne Optimierung)..."
    cargo check
    info "cargo check OK."
    exit 0
fi

info "Baue '${NAME}' (release)..."
cargo build --release

BINARY="$SCRIPT_DIR/target/release/${NAME}"

if [[ "$PROFILE" == "debug" ]]; then
    BINARY="$SCRIPT_DIR/target/debug/${NAME}"
    info "Debug-Build: ${BINARY}"
    exit 0
fi

if [[ ! -x "$BINARY" ]]; then
    err "Binary nicht gefunden: $BINARY"
    exit 1
fi

info "Binary gebaut: $BINARY ($(du -h "$BINARY" | cut -f1))"

# === Installieren ============================================================

if [[ "$ONLY_BUILD" -eq 1 ]]; then
    info "Installation übersprungen (--only-build)."
    exit 0
fi

mkdir -p "$INSTALL_DIR"
if cp -f "$BINARY" "$INSTALL_DIR/${NAME}"; then
    chmod +x "$INSTALL_DIR/${NAME}"
    info "Installiert nach ${INSTALL_DIR}/${NAME}"
else
    err "Installation nach ${INSTALL_DIR} fehlgeschlagen (Schreibrechte?)."
    err "Mit --install DIR ein anderes Ziel wählen, z. B.:"
    err "  sudo ./build.sh --install /usr/local/bin"
    exit 1
fi

# Optionaler Symlink nach /usr/local/bin, falls wir Schreibrechte haben
if [[ -d /usr/local/bin ]] && [[ -w /usr/local/bin ]] && [[ "$ONLY_BUILD" -eq 0 ]]; then
    ln -sf "$INSTALL_DIR/${NAME}" "/usr/local/bin/${NAME}"
    info "Symlink: /usr/local/bin/${NAME}"
fi

# === Verify ==================================================================

if [[ -x "$INSTALL_DIR/${NAME}" ]]; then
    info "Done. Starten mit: ./stt-daemon.sh start"
    info "ODER:             ${INSTALL_DIR}/${NAME} --help"
else
    warn "Build OK, aber Binary nicht im Zielpfad. Manuell starten: $BINARY"
fi
