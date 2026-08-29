#!/usr/bin/env bash
##############################################################################
# stt-daemon.sh — Starten, Stoppen und Verwalten des STT Terminal Injection Daemon
#
# Ein einzelner Prozess (Rust), keine Python-Skripte oder Bash-Magie im Hintergrund.
# Das Script verwaltet nur den Lebenszyklus der Binary (Start, Stopp, Neustart, Status).
#
# Usage:
#   ./stt-daemon.sh start [args...]    # Startet mit optionalen Argumenten (--model-dir, --tmux-session ...)
#   ./stt-daemon.sh stop               # Beendet sauber (SIGTERM → SIGKILL nach 5 Sek)
#   ./stt-daemon.sh restart            # Graceful Restart ohne Datenverlust
#   ./stt-daemon.sh status             # Zeigt PID, Uptime und Health-Check
#   ./stt-daemon.sh logs               # Live-Anzeige der Logs (tail -f)
#   ./stt-daemon.sh install            # Installiert als systemd user service
##############################################################################

set -euo pipefail

# === Konfiguration ============================================================

NAME="stt-terminject"
BINARY=""                       # Wird automatisch beim Start ermittelt
PIDFILE="$HOME/.local/state/${NAME}.pid"
LOGFILE="$HOME/.cache/${NAME}/${NAME}.log"
CONFIG_FILE="$HOME/.config/stt-terminject/config.json"

# === Farben & Logging --------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }

# === Helper ------------------------------------------------------------------

ensure_dirs() {
    mkdir -p "$(dirname "$PIDFILE")" \
             "$(dirname "$LOGFILE")" \
             "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
}

find_binary() {
    local candidates=(
        "./target/release/${NAME}"
        "/home/torsten/dev/my-projects/STT-terminal/stt-terminject/target/release/${NAME}"
        "${CARGO_HOME:-$HOME/.cargo}/bin/${NAME}"
        "/usr/local/bin/${NAME}"
    )
    for c in "${candidates[@]}"; do
        if [[ -x "$c" ]]; then echo "$c"; return 0; fi
    done
    err "Binary '${NAME}' nicht gefunden!"
    echo "  Versuche: cargo build --release" >&2
    return 1
}

get_port() {
    python3 -c "
import json, sys
try:
    cfg = json.load(open('${CONFIG_FILE:-$HOME/.config/stt-terminject/config.json}'))
    print(cfg.get('listen_port', 3210))
except: print(3210)
" 2>/dev/null || echo 3210
}

read_pid() {
    [[ -f "$PIDFILE" ]] && cat "$PIDFILE" || echo ""
}

is_running() {
    local pid
    pid=$(read_pid)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

health_check() {
    local port
    port=$(get_port)
    curl -sf --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1
}

show_status() {
    if is_running; then
        local pid port health
        pid=$(read_pid)
        port=$(get_port)
        local mtime
        mtime=$(stat -c %Y "$PIDFILE" 2>/dev/null || echo 0)
        local uptime=$(( $(date +%s) - mtime ))
        local mins=$((uptime / 60))
        
        echo -e "${GREEN}Running${NC}:  PID ${pid} (${mins}min)"
        echo "Port:     ${port}"
        echo "Config:   ${CONFIG_FILE:-~/.config/stt-terminject/config.json}"
        echo "Log:      ${LOGFILE}"
        
        if health_check; then
            echo -e "Health:   ${GREEN}OK${NC}"
        else
            echo -e "Health:   ${YELLOW}FAILED${NC}"
        fi
    else
        echo -e "${RED}Not running${NC}"
    fi
}

# === Kommandos ---------------------------------------------------------------

cmd_start() {
    ensure_dirs
    BINARY=$(find_binary)
    
    if is_running; then
        warn "Already running (PID $(read_pid)). Use 'restart' to update."
        return 0
    fi
    
    info "Starting ${NAME} from ${BINARY}..."
    
    nohup "$BINARY" \
        --config "${CONFIG_FILE:-$HOME/.config/stt-terminject/config.json}" \
        "$@" >> "$LOGFILE" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    echo "$pid" > "$PIDFILE"
    
    # Warten bis Server antwortet
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        info "Started successfully (PID ${pid})"
        info "API → http://127.0.0.1:$(get_port)"
        info "View logs: tail -f \"$LOGFILE\""
    else
        err "Failed to start. Last lines of log:"
        tail -10 "$LOGFILE" 2>/dev/null || true
        rm -f "$PIDFILE"
        return 1
    fi
}

cmd_stop() {
    if ! is_running; then
        info "Not running."
        return 0
    fi
    
    local pid
    pid=$(read_pid)
    info "Stopping PID ${pid}..."
    
    kill "$pid" 2>/dev/null || true
    
    # Maximal 10 Sekunden warten auf sauberes Beenden
    for _ in $(seq 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    
    if kill -0 "$pid" 2>/dev/null; then
        warn "Force killing..."
        kill -9 "$pid" 2>/dev/null || true
    fi
    
    rm -f "$PIDFILE"
    info "Stopped."
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_logs() {
    if [[ -f "$LOGFILE" ]]; then
        tail -f "$LOGFILE"
    elif command -v journalctl &>/dev/null; then
        journalctl --user -u stt-terminject -f 2>/dev/null || \
            journalctl -u stt-terminject -f 2>/dev/null || \
            echo "No journal logs found."
    else
        echo "No logs available. Run 'start' first."
    fi
}

cmd_install() {
    local service_file
    service_file="$(dirname "${BASH_SOURCE[0]}")/stt-terminject.service"
    
    if [[ ! -f "$service_file" ]]; then
        err "stt-terminject.service not found in $(dirname "${BASH_SOURCE[0]}")."
        echo "Place stt-terminject.service next to this script." >&2
        return 1
    fi
    
    local dest="$HOME/.config/systemd/user/stt-terminject.service"
    cp "$service_file" "$dest"
    
    info "Service installed to $dest"
    
    systemctl --user daemon-reload
    systemctl --user enable stt-terminject
    systemctl --user start stt-terminject
    
    info "Installed and started as systemd user service."
    info "Status: systemctl --user status stt-terminject"
    info "Logs:   journalctl --user -u stt-terminject -f"
}

# === Hauptprogramm -----------------------------------------------------------

case "${1:-status}" in
    start)     cmd_start     ;;
    stop)      cmd_stop      ;;
    restart)   cmd_restart   ;;
    logs)      cmd_logs      ;;
    install)   cmd_install   ;;
    status|*)  show_status   ;;
esac
