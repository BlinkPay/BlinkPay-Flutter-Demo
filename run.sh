#!/usr/bin/env bash
#
# Starts both the BlinkPay proxy server and the Flutter app.
#
# Usage:
#   ./run.sh                 # Interactive — prompts for device type
#   ./run.sh --emulator      # Skip prompt: Android emulator (10.0.2.2)
#   ./run.sh --simulator     # Skip prompt: iOS simulator (localhost)
#   ./run.sh --lan           # Skip prompt: physical device (auto-detect LAN IP)
#
# Prerequisites:
#   1. Copy server/.env.example to server/.env and fill in BlinkPay credentials.
#   2. If APP_API_KEY is left empty in server/.env, a random key will be generated
#      for this session automatically.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$PROJECT_DIR/server"
SERVER_PORT="${SERVER_PORT:-4567}"

# ─── Clean up on exit (registered early so any failure is caught) ────
# Trap EXIT plus common signals so the server is killed whether the user
# presses Ctrl-C, closes the terminal, or the script errors out.
cleanup() {
  # Avoid running twice when a signal triggers EXIT as well
  trap - EXIT INT TERM HUP
  if [[ -n "${SERVER_PID:-}" ]]; then
    echo ""
    echo "Stopping server (PID: $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    echo "Done."
  fi
}
trap cleanup EXIT INT TERM HUP

# ─── Parse arguments (flags skip the interactive prompt) ─────────────
MODE=""
for arg in "$@"; do
  case "$arg" in
    --emulator)  MODE="emulator" ;;
    --simulator) MODE="simulator" ;;
    --lan)       MODE="lan" ;;
    *)           echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ─── Interactive prompt if no flag was given ─────────────────────────
if [[ -z "$MODE" ]]; then
  echo ""
  echo "Where is the app running?"
  echo ""
  echo "  1) iOS Simulator"
  echo "  2) Android Emulator"
  echo "  3) Physical device (USB or same network)"
  echo ""
  read -r -p "Choose [1/2/3]: " choice
  case "$choice" in
    1) MODE="simulator" ;;
    2) MODE="emulator" ;;
    3) MODE="lan" ;;
    *) echo "Invalid choice. Exiting."; exit 1 ;;
  esac
fi

# ─── Check server .env exists ────────────────────────────────────────
if [[ ! -f "$SERVER_DIR/.env" ]]; then
  echo "ERROR: server/.env not found."
  echo "  cp server/.env.example server/.env"
  echo "  Then fill in your BlinkPay credentials."
  exit 1
fi

# ─── Portable sed -i ─────────────────────────────────────────────────
# macOS sed requires -i '', GNU sed requires -i without an argument.
sed_inplace() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ─── Read or generate APP_API_KEY ────────────────────────────────────
# If APP_API_KEY is not set or is a placeholder in server/.env,
# generate a random one for this session and write it back.
APP_API_KEY=$(grep '^APP_API_KEY=' "$SERVER_DIR/.env" | cut -d'=' -f2- || true)

if [[ -z "$APP_API_KEY" || "$APP_API_KEY" == "<"* ]]; then
  APP_API_KEY=$(openssl rand -hex 32)
  echo "Generated session API key: ${APP_API_KEY:0:8}..."

  # Write it into server/.env (replace existing line or append)
  if grep -q '^APP_API_KEY=' "$SERVER_DIR/.env"; then
    sed_inplace "s|^APP_API_KEY=.*|APP_API_KEY=$APP_API_KEY|" "$SERVER_DIR/.env"
  else
    echo "APP_API_KEY=$APP_API_KEY" >> "$SERVER_DIR/.env"
  fi
fi

# ─── Detect backend URL based on mode ────────────────────────────────
detect_lan_ip() {
  if [[ "$OSTYPE" == darwin* ]]; then
    local ip
    ip=$(ipconfig getifaddr en0 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return
    fi
  else
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return
    fi
  fi
  echo "localhost"
}

case "$MODE" in
  emulator)
    BACKEND_HOST="10.0.2.2"
    ;;
  simulator)
    BACKEND_HOST="localhost"
    ;;
  lan)
    BACKEND_HOST=$(detect_lan_ip)
    ;;
esac

BACKEND_URL="http://${BACKEND_HOST}:${SERVER_PORT}"

echo ""
echo "========================================="
echo "  BlinkPay Demo"
echo "========================================="
echo "  Mode:             $MODE"
echo "  Server binds on:  0.0.0.0:${SERVER_PORT}"
echo "  App backend URL:  ${BACKEND_URL}"
echo ""
echo "  NOTE: The server binds on 0.0.0.0 so it"
echo "  is reachable from your local network."
echo "  This is HTTP only — use HTTPS/TLS in"
echo "  production deployments."
echo "========================================="
echo ""

# ─── Check for stale process on the port ──────────────────────────────
# Safety net for cases where cleanup couldn't run (e.g. SIGKILL / force-quit).
STALE_PID=$(lsof -ti:"$SERVER_PORT" 2>/dev/null || true)
if [[ -n "$STALE_PID" ]]; then
  echo "Port $SERVER_PORT in use (PID: $STALE_PID) — killing stale process..."
  kill "$STALE_PID" 2>/dev/null || true
  sleep 1
fi

# ─── Install server dependencies ─────────────────────────────────────
echo "[1/3] Installing server dependencies..."
(cd "$SERVER_DIR" && dart pub get)

# ─── Start server in background ──────────────────────────────────────
echo "[2/3] Starting proxy server..."
# Use exec so the subshell replaces itself with the Dart process,
# ensuring SERVER_PID points directly at the Dart VM (not a wrapper shell).
(cd "$SERVER_DIR" && exec dart run bin/server.dart) &
SERVER_PID=$!

# Wait for server to start
sleep 2
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "ERROR: Server failed to start. Check server/.env configuration."
  exit 1
fi
echo "  Server running (PID: $SERVER_PID)"

# ─── Run Flutter app ─────────────────────────────────────────────────
echo "[3/3] Starting Flutter app..."
echo ""
(cd "$PROJECT_DIR" && flutter run \
  --dart-define="BACKEND_URL=$BACKEND_URL" \
  --dart-define="APP_API_KEY=$APP_API_KEY")
