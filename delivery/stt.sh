#!/usr/bin/env bash
##############################################################################
# stt.sh — Lifecycle-Management für den STT Terminal Injection Daemon (Delivery)
#
# Läuft OHNE Rust/cargo/libclang (Build-Toolchain). Binary und Config liegen
# direkt in diesem Ordner. Fehlende System-Libs / Model laden: ./install-deps.sh
#
# Usage:
#   ./stt.sh setup                 # EINMALIG: deps installieren + als systemd-Service
#   ./stt.sh start                 # Daemon starten (systemd oder direkt)
#   ./stt.sh restart               # Neustart
#   ./stt.sh stop                  # Stoppen
#   ./stt.sh status                # Status + Health-Check
#   ./stt.sh logs                  # Logs verfolgen
#   ./stt.sh config                # Konfig-Anzeige/-Bearbeitung (JSON)
#   ./stt.sh install-deps          # Libs + Modell bereitstellen
#   ./stt.sh install               # systemd-User-Service installieren (Autostart)
#   ./stt.sh uninstall             # Service entfernen + stoppen
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
BINARY="$SCRIPT_DIR/stt-terminject"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SERVICE="stt-terminject.service"
SERVICE_DST="${HOME}/.config/systemd/user/$SERVICE"
LOG_DIR="${HOME}/.cache/${NAME}"
LOGFILE="$LOG_DIR/${NAME}.log"

have_systemd() {
    command -v systemctl &>/dev/null && [[ -n "${XDG_RUNTIME_DIR:-}" ]]
}
is_service_enabled() {
    [[ -f "$SERVICE_DST" ]]
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
    if [[ ! -x "$BINARY" ]]; then
        err "Binary fehlt: $BINARY"
        return 1
    fi
    if pgrep -x "$NAME" >/dev/null; then
        warn "Läuft bereits (PID $(pgrep -x "$NAME"))."
        return 0
    fi
    nohup "$BINARY" --config "$CONFIG_FILE" "$@" >> "$LOGFILE" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        info "Direkt gestartet (PID $pid)."
        info "API → http://127.0.0.1:$(get_port)"
    else
        err "Start fehlgeschlagen. Letzte Log-Zeilen:"
        tail -10 "$LOGFILE" 2>/dev/null || true
        return 1
    fi
}

# === stop / restart ===========================================================

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

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start "$@"
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
    if curl -sf --max-time 3 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
        info "OK → http://127.0.0.1:${port}/health"
    else
        err "FAILED (Port ${port})"
    fi
}

# === logs / config ============================================================

cmd_logs() {
    if is_service_enabled && have_systemd; then
        journalctl --user -u "$SERVICE" -f
    else
        tail -f "$LOGFILE"
    fi
}

cmd_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "Keine Konfig vorhanden: $CONFIG_FILE"
        return 1
    fi
    echo "=== $CONFIG_FILE ==="
    cat "$CONFIG_FILE"
    echo
    if [[ -t 0 ]]; then
        info "Öffnen mit Editor? [y/N] "
        read -r r
        [[ "$r" == "y" ]] && ${EDITOR:-nano} "$CONFIG_FILE"
    fi
}

# === install-deps =============================================================

cmd_install_deps() {
    if [[ ! -x "$SCRIPT_DIR/install-deps.sh" ]]; then
        err "install-deps.sh fehlt neben stt.sh."
        return 1
    fi
    "$SCRIPT_DIR/install-deps.sh" "$@"
}

# === install (systemd service generated with absolute paths) =================

cmd_install() {
    if ! have_systemd; then
        warn "Kein systemd-User-Bus verfügbar → direkter Start."
        cmd_start
        return
    fi
    # Service-Datei dynamisch mit absolutem Pfad dieses Ordners erzeugen
    local unit
    unit="[Unit]
Description=STT Terminal Injection Daemon (speech-to-text terminal injection)
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=${BINARY} --config ${CONFIG_FILE}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${NAME}
NoNewPrivileges=yes
PrivateTmp=yes
ReadOnlyPaths=${HOME}/.cache/ocw-stt/models
ReadWritePaths=${HOME}/.cache/ocw-stt ${HOME}/.config/stt-terminject

[Install]
WantedBy=graphical-session.target
"
    mkdir -p "$(dirname "$SERVICE_DST")"
    printf '%s' "$unit" > "$SERVICE_DST"
    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE"
    systemctl --user start "$SERVICE"
    info "systemd-User-Service installiert + gestartet (Autostart aktiv)."
    info "Status: ./stt.sh status  |  Logs: ./stt.sh logs"
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

# === setup (einmalig) =========================================================

cmd_setup() {
    step "Setup: System-Bibliotheken + Modell bereitstellen..."
    cmd_install_deps
    echo
    step "Daemon installieren + starten..."
    cmd_install
    echo
    cmd_status
}

# === Getter ===================================================================

get_port() {
    # grep ist unabhängig von python; Config ist ein kleines JSON
    local p
    p=$(sed -n 's/.*"listen_port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$CONFIG_FILE" | head -1)
    echo "${p:-3210}"
}

ensure_dirs() {
    mkdir -p "$LOG_DIR" "${HOME}/.local/state" 2>/dev/null || true
}

# === Hauptprogramm ===========================================================

cmd="${1:-status}"
shift || true

case "$cmd" in
    setup)          cmd_setup "$@"          ;;
    start)          cmd_start "$@"          ;;
    stop)           cmd_stop                ;;
    restart)        cmd_restart "$@"        ;;
    status)         cmd_status              ;;
    logs)           cmd_logs                ;;
    config)         cmd_config              ;;
    install-deps)   cmd_install_deps "$@"   ;;
    install)        cmd_install             ;;
    uninstall)      cmd_uninstall           ;;
    help|-h|--help) sed -n '3,24p' "$0"     ;;
    *)              err "Unbekanntes Kommando: $cmd"; sed -n '3,24p' "$0"; exit 2 ;;
esac
