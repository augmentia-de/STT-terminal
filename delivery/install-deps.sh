#!/usr/bin/env bash
##############################################################################
# install-deps.sh — System-Bibliotheken + Whisper-Modell für den STT-Daemon
#
# Macht das Deployment aus diesem Ordner heraus lauffähig, OHNE Rust/cargo/
# libclang (Build-Toolchain). Es kümmert sich um:
#   1. Fehlende dynamische System-Bibliotheken der Binary (per apt)
#   2. Fehlendes Whisper-Modell (curl-Download aus Hugging Face)
#
# Usage:
#   ./install-deps.sh            # Libs prüfen/nachinstallieren + Modell sicherstellen
#   ./install-deps.sh --libs     # nur Bibliotheken
#   ./install-deps.sh --model    # nur Modell
#   ./install-deps.sh --check    # nur prüfen/berichten, nichts installieren/downloaden
##############################################################################

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

DO_LIBS=1
DO_MODEL=1
CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --libs)   DO_MODEL=0 ;;
        --model)  DO_LIBS=0  ;;
        --check)  CHECK_ONLY=1 ;;
        *)        err "Unbekanntes Argument: $arg"; exit 2 ;;
    esac
done

# === Konfiguration lesen (ohne Python abhängig zu sein) ======================

model_dir() {
    # "model_dir": "~/.cache/ocw-stt/models"
    sed -n 's/.*"model_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1
}
model_file() {
    sed -n 's/.*"model_file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1
}

expand_home() {
    case "$1" in
        "~"*) echo "${HOME}${1#\~}" ;;
        *)    echo "$1" ;;
    esac
}

MDIR="$(model_dir)"; MDIR="${MDIR:-~/.cache/ocw-stt/models}"
MFILE="$(model_file)"; MFILE="${MFILE:-ggml-base.en.bin}"
MODEL_DIR="$(expand_home "$MDIR")"
MODEL_PATH="$MODEL_DIR/$MFILE"

# === 1) System-Bibliotheken =================================================

# Binary relative zu diesem Skript
BINARY="$SCRIPT_DIR/stt-terminject"

# benötigte .so -> apt-Paketname (Debian/Ubuntu). Name alt/neu t64 abgedeckt.
declare -A LIB2PKG=(
    [libxdo.so.3]="libxdo3"
    [libasound.so.2]="libasound2 libasound2t64"
    [libXtst.so.6]="libxtst6"
    [libXinerama.so.1]="libxinerama1"
    [libxkbcommon.so.0]="libxkbcommon0"
    [libX11.so.6]="libx11-6"
    [libXext.so.6]="libxext6"
)

check_install_libs() {
    if [[ ! -x "$BINARY" ]]; then
        err "Binary fehlt: $BINARY (stt-terminject nicht im Ordner)"
        return 1
    fi
    # Zuverlässigste Prüfung: kann die Binary ALLE benötigten .so laden?
    local ldd_out missing=()
    ldd_out=$(ldd "$BINARY" 2>/dev/null)
    # Zeilen mit "=> not found" = fehlende Bibliothek
    while IFS= read -r line; do
        missing+=("$(echo "$line" | awk '{print $1}')")
    done < <(printf '%s\n' "$ldd_out" | grep "not found")

    if [[ ${#missing[@]} -eq 0 ]]; then
        info "Alle benötigten System-Bibliotheken ladbar."
        return 0
    fi

    # Fehlende libs -> apt-Pakete ermitteln und installieren
    local uniq=()
    for so in "${missing[@]}"; do
        local pkgs="${LIB2PKG[$so]:-}"
        if [[ -z "$pkgs" ]]; then
            uniq+=("${so#lib}" "${so//.so/}")
        else
            local p; p="${pkgs%% *}"
            uniq+=("$p")
        fi
    done
    # deduplizieren
    local seen=() want_pkgs=()
    for x in "${uniq[@]}"; do
        if [[ ! " ${seen[*]} " == *" $x "* ]]; then
            seen+=("$x"); want_pkgs+=("$x")
        fi
    done

    err "Fehlende Bibliotheken: ${missing[*]}"
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        err "Nötige Pakete: ${want_pkgs[*]}"
        return 0
    fi

    info "Installiere via apt (erfordert sudo / Root): ${want_pkgs[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y "${want_pkgs[@]}"
        sudo ldconfig 2>/dev/null || true
    else
        err "apt-get nicht gefunden. Bitte manuell installieren: ${want_pkgs[*]}"
        return 1
    fi
    # Nachprüfen
    if ldd "$BINARY" 2>/dev/null | grep -q "not found"; then
        err "Es fehlen weiterhin Bibliotheken trotz Installation."
        return 1
    fi
    info "Bibliotheken vorhanden und ladbar."
}

# === 2) Whisper-Modell =======================================================

# Bekannte Modelle: datei -> bytes:sha256:url  (bytes + sha256 für Verifikation)
declare -A MODELS=(
    [ggml-base.en.bin]="147964211:a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002:https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
    [ggml-small.bin]="487601967:1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b:https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
)

check_install_model() {
    mkdir -p "$MODEL_DIR"
    local spec="${MODELS[$MFILE]:-}"
    if [[ -z "$spec" ]]; then
        err "Unbekanntes Modell '$MFILE' — nicht in install-deps.sh hinterlegt."
        err "Modell manuell nach $MODEL_DIR legen."
        return 1
    fi
    local want_bytes want_sha url
    want_bytes="${spec%%:*}"; rest="${spec#*:}"
    want_sha="${rest%%:*}"; url="${rest#*:}"

    if [[ -f "$MODEL_PATH" && -s "$MODEL_PATH" ]]; then
        local actual size
        size=$(stat -c %s "$MODEL_PATH")
        if [[ "$size" != "$want_bytes" ]]; then
            warn "Modell $MFILE hat falsche Größe ($size statt $want_bytes). Neu-Download..."
            rm -f "$MODEL_PATH"
        else
            info "OK: Modell vorhanden ($MODEL_PATH, $(du -h "$MODEL_PATH" | cut -f1))."
            return 0
        fi
    fi

    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        warn "Modell '$MFILE' fehlt: $MODEL_PATH"
        return 0
    fi

    info "Downloade Modell $MFILE ..."
    curl -L --fail -o "$MODEL_PATH.part" "$url"
    local actual_sha
    actual_sha=$(sha256sum "$MODEL_PATH.part" | awk '{print $1}')
    if [[ "$actual_sha" != "$want_sha" ]]; then
        rm -f "$MODEL_PATH.part"
        err "SHA256 der Datei stimmt nicht (${actual_sha}). Abbruch."
        return 1
    fi
    mv "$MODEL_PATH.part" "$MODEL_PATH"
    info "Modell heruntergeladen + verifiziert (SHA256 ok)."
}

# === Hauptprogramm ===========================================================

if [[ "$DO_LIBS" -eq 1 ]]; then
    echo "── Bibliotheken ─────────────────────────────"
    check_install_libs
fi
if [[ "$DO_MODEL" -eq 1 ]]; then
    echo "── Whisper-Modell ───────────────────────────"
    check_install_model
fi
info "install-deps fertig."
