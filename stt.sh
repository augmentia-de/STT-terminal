#!/usr/bin/env bash
##############################################################################
# stt.sh — Unificiertes Lifecycle-Management für den STT Terminal Injection Daemon
#
# Baut, installiert, startet, stoppt, ersetzt (update) und überwacht die
# Rust-Binary. Arbeitet mit systemd-User-Service ODER direkt (Fallback).
#
# Usage:
#   ./stt.sh build                  # release-Build + Install nach ~/.cargo/bin
#   ./stt.sh start                  # Daemon starten (systemd oder direkt)
#   ./stt.sh restart                # Neustart
#   ./stt.sh stop                   # Stoppen
#   ./stt.sh status                 # Status + Health-Check
#   ./stt.sh replace                # Rebuild + neues Binary einspielen + Neustart („update")
#   ./stt.sh replace --debug        # wie replace, aber Debug-Binary
#   ./stt.sh logs                   # Logs verfolgen
#   ./stt.sh config                 # Konfig-Datei öffnen/anzeigen
#   ./stt.sh install                # systemd-User-Service (Autostart) installieren
#   ./stt.sh uninstall              # systemd-Service entfernen + stoppen
#   ./stt.sh help
##############################################################################

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
step() { echo -e "${CYAN}→${NC} $*"; }

NAME="stt-terminject"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_DIR="$SCRIPT_DIR/target/release"
DEBUG_DIR="$SCRIPT_DIR/target/debug"
INSTALL_DIR="${HOME}/.cargo/bin"
CONFIG_FILE="${HOME}/.config/stt-terminject/config.json"
SERVICE="stt-terminject.service"
SERVICE_SRC="$SCRIPT_DIR/$SERVICE"
SERVICE_DST="${HOME}/.config/systemd/user/$SERVICE"

# === Helper ==================================================================

have_systemd() {
    command -v systemctl &>/dev/null && [[ -n "${XDG_RUNTIME_DIR:-}" ]]
}

is_service_enabled() {
    [[ -f "$SERVICE_DST" ]]
}

# Start-Argumente — optional CLI-Overrides durchreichen
start_args() {
    # Bsp.: ./stt.sh start --tmux-session work
    printf '%q ' "$@"
}

# === build ===================================================================

cmd_build() {
    step "Baue ${NAME} (release)..."
    "$SCRIPT_DIR/build.sh" "$@"
}

# === start ===================================================================

cmd_start() {
    if is_service_enabled; then
        systemctl --user start "$SERVICE"
        info "systemd-Service gestartet."
        cmd_status
        return
    fi

    step "Kein systemd-Service → direkter Start..."
    ensure_dirs
    local bin="${INSTALL_DIR}/${NAME}"
    [[ -x "$bin" ]] || bin="${BINARY_DIR}/${NAME}"
    if [[ ! -x "$bin" ]]; then
        err "Binary nicht gefunden. Erst: ./stt.sh build"
        return 1
    fi

    if pgrep -x "$NAME" >/dev/null; then
        warn "Läuft bereits (PID $(pgrep -x "$NAME"))."
        return 0
    fi

    mkdir -p "$(dirname "$LOGFILE")"
    nohup "$bin" --config "$CONFIG_FILE" "$@" >> "$LOGFILE" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        info "Direkt gestartet (PID $pid)."
        info "API → http://127.0.0.1:3210"
    else
        err "Start fehlgeschlagen. Letzte Log-Zeilen:"
        tail -10 "$LOGFILE" 2>/dev/null || true
        return 1
    fi
}

# === stop ====================================================================

cmd_stop() {
    if is_service_enabled; then
        systemctl --user stop "$SERVICE" 2>/dev/null || true
        info "systemd-Service gestoppt."
        return
    fi
    if pgrep -x "$NAME" >/dev/null; then
        pkill -x "$NAME"
        info "Gestoppt."
    else
        info "Läuft nicht."
    fi
}

# === restart =================================================================

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

# === status ==================================================================

cmd_status() {
    local port
    port=$(get_port)
    if is_service_enabled; then
        systemctl --user status "$SERVICE" --no-pager
    elif pgrep -x "$NAME" >/dev/null; then
        info "Direkt gestartet: PID $(pgrep -x "$NAME")"
    else
        warn "Nicht aktiv (kein systemd-Service, kein Prozess)."
    fi
    echo -n "Health:  "
    if curl -sf --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
        info "OK → http://127.0.0.1:${port}/health"
    else
        err "FAILED (Port ${port})"
    fi
}

# === replace (update) ========================================================

cmd_replace() {
    step "Ersetzen (update): bauen → Binary tauschen → neu starten"
    local debug=0
    local extra=()
    for a in "$@"; do
        [[ "$a" == "--debug" ]] && { debug=1; continue; }
        extra+=("$a")
    done

    # 1. Neues Binary bauen
    if [[ "$debug" -eq 0 ]]; then
        cmd_build --only-build || return 1
        local src="${BINARY_DIR}/${NAME}"
    else
        step "Debug-Build..."
        cargo build 2>&1 | tail -3
        local src="${DEBUG_DIR}/${NAME}"
    fi

    cp -f "$src" "${INSTALL_DIR}/${NAME}"
    chmod +x "${INSTALL_DIR}/${NAME}"
    info "Neues Binary installiert: ${INSTALL_DIR}/${NAME}"

    # 2. Neustarten, damit die neue Version aktiv wird
    step "Neustart mit neuem Binary..."
    cmd_restart "${extra[@]}"
    info "Replace abgeschlossen."
}

# === logs ====================================================================

cmd_logs() {
    if is_service_enabled && have_systemd; then
        journalctl --user -u "$SERVICE" -f
    else
        tail -f "$LOGFILE"
    fi
}

# === config ==================================================================

cmd_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "=== $CONFIG_FILE ==="
        cat "$CONFIG_FILE"
        echo
        if [[ -t 0 ]]; then
            info "Öffnen mit Editor? [y/N] "
            read -r r
            [[ "$r" == "y" ]] && ${EDITOR:-nano} "$CONFIG_FILE"
        fi
    else
        warn "Keine Konfig vorhanden."
        ${EDITOR:-nano} "$CONFIG_FILE"
    fi
}

# === install / uninstall =====================================================

cmd_install() {
    if have_systemd; then
        if [[ ! -f "$SERVICE_SRC" ]]; then
            err "Service-Vorlage fehlt: $SERVICE_SRC"
            return 1
        fi
        mkdir -p "$(dirname "$SERVICE_DST")"
        cp -f "$SERVICE_SRC" "$SERVICE_DST"
        systemctl --user daemon-reload
        systemctl --user enable "$SERVICE"
        systemctl --user start "$SERVICE"
        info "systemd-User-Service installiert + gestartet (Autostart aktiv)."
        info "Status: ./stt.sh status   |  Logs: ./stt.sh logs"
    else
        warn "Kein systemd-User-Bus verfügbar → direkter Start."
        cmd_start
    fi
}

cmd_uninstall() {
    if [[ -f "$SERVICE_DST" ]]; then
        systemctl --user stop "$SERVICE" 2>/dev/null || true
        systemctl --user disable "$SERVICE" 2>/dev/null || true
        rm -f "$SERVICE_DST"
        systemctl --user daemon-reload
        info "systemd-Service entfernt."
    else
        warn "Kein systemd-Service installiert."
    fi
    cmd_stop
}

# === Getter ==================================================================

get_port() {
    if command -v python3 &>/dev/null; then
        python3 -c "import json;print(json.load(open('$CONFIG_FILE')).get('listen_port',3210))" 2>/dev/null || echo 3210
    else
        echo 3210
    fi
}

ensure_dirs() {
    mkdir -p "${HOME}/.cache/${NAME}" "${HOME}/.local/state" 2>/dev/null || true
}

LOGFILE="${HOME}/.cache/${NAME}/${NAME}.log"

# === Hauptprogramm ===========================================================

cmd="${1:-status}"
shift || true

case "$cmd" in
    build)      cmd_build "$@"         ;;
    start)      cmd_start "$@"         ;;
    stop)       cmd_stop               ;;
    restart)    cmd_restart "$@"       ;;
    status)     cmd_status             ;;
    replace|update) cmd_replace "$@"   ;;
    logs)       cmd_logs               ;;
    config)     cmd_config             ;;
    install)    cmd_install            ;;
    uninstall)  cmd_uninstall          ;;
    help|-h|--help) sed -n '3,22p' "$0" ;;
    *)          err "Unbekanntes Kommando: $cmd"; sed -n '3,22p' "$0"; exit 2 ;;
esac
