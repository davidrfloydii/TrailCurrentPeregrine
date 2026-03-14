#!/usr/bin/env bash
# Deploy voice assistant files to the Radxa Dragon Q6A board.
# Uses a single SSH connection (ControlMaster) so you only authenticate once.
#
# Usage:
#   ./deploy.sh <board-ip-or-hostname>
#   ./deploy.sh <board-ip>
#   ./deploy.sh root@<board-ip>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <host-or-user@host>"
    echo "  e.g. $0 <board-ip>"
    exit 1
fi

TARGET="$1"
# Default to root@ if no user specified (assistant user has no password)
if [[ "$TARGET" != *@* ]]; then
    TARGET="root@${TARGET}"
fi

REMOTE_HOME="/home/assistant"

echo "Deploying to ${TARGET}..."
echo ""

# Set up SSH ControlMaster for single authentication
SOCK="/tmp/deploy-assistant-$$"
ssh -o ControlMaster=yes -o ControlPersist=60 -o ControlPath="$SOCK" -fN "$TARGET" || {
    echo "ERROR: Could not connect to ${TARGET}"
    exit 1
}

cleanup() {
    ssh -o ControlPath="$SOCK" -O exit "$TARGET" 2>/dev/null || true
}
trap cleanup EXIT

SCP="scp -o ControlPath=$SOCK"
SSH="ssh -o ControlPath=$SOCK"

# Ensure remote directories exist
$SSH "$TARGET" "mkdir -p ${REMOTE_HOME}/models"

# Ensure Python dependencies are up to date (run as assistant user)
echo "[1/5] Checking Python dependencies..."
# --no-deps: tflite-runtime has no aarch64 wheel and we only use ONNX inference.
# --force-reinstall ensures resource files (melspectrogram.onnx, embedding_model.onnx)
# are included even when upgrading across major versions.
$SSH "$TARGET" "su -c '${REMOTE_HOME}/assistant-env/bin/pip install -q --force-reinstall --no-deps openwakeword 2>&1 | tail -1' assistant"
# timezonefinder: DST-aware local time from GPS coordinates
$SSH "$TARGET" "su -c '${REMOTE_HOME}/assistant-env/bin/pip install -q timezonefinder 2>&1 | tail -1' assistant"

# Copy assistant.py
echo "[2/5] Copying assistant.py..."
$SCP "${SCRIPT_DIR}/src/assistant.py" "${TARGET}:${REMOTE_HOME}/assistant.py"

# Copy genie NPU server
echo "[3/5] Copying genie_server.py..."
$SCP "${SCRIPT_DIR}/src/genie_server.py" "${TARGET}:${REMOTE_HOME}/genie_server.py"

# Copy wake word model
echo "[4/5] Copying wake word model..."
$SCP "${SCRIPT_DIR}/models/hey_peregrine.onnx" "${TARGET}:${REMOTE_HOME}/models/hey_peregrine.onnx"
if [[ -f "${SCRIPT_DIR}/models/hey_peregrine.onnx.data" ]]; then
    $SCP "${SCRIPT_DIR}/models/hey_peregrine.onnx.data" "${TARGET}:${REMOTE_HOME}/models/hey_peregrine.onnx.data"
fi

# Copy service files and fix ownership (deploying as root, services run as assistant)
echo "[5/5] Copying service files..."
$SCP "${SCRIPT_DIR}/config/voice-assistant.service" "${TARGET}:/etc/systemd/system/voice-assistant.service"
$SCP "${SCRIPT_DIR}/config/genie-server.service" "${TARGET}:/etc/systemd/system/genie-server.service"
$SSH "$TARGET" "systemctl daemon-reload && systemctl enable genie-server && chown -R assistant:assistant ${REMOTE_HOME}"

# Create default env file if it doesn't exist (never overwrite)
$SSH "$TARGET" "test -f ${REMOTE_HOME}/assistant.env || cat > ${REMOTE_HOME}/assistant.env << 'ENVEOF'
# Voice assistant environment config — persists across deploys.
# Edit with: nano ~/assistant.env
# Then restart: sudo systemctl restart voice-assistant

# MQTT
#MQTT_BROKER=192.168.x.x
#MQTT_PORT=8883
#MQTT_USE_TLS=true
#MQTT_CA_CERT=/home/assistant/ca.pem
#MQTT_USERNAME=
#MQTT_PASSWORD=

# Audio tuning
#WAKE_THRESHOLD=0.5
#SILENCE_THRESHOLD=500
#SILENCE_DURATION=1.5
ENVEOF"

echo ""
echo "Deploy complete. Files copied:"
echo "  ${REMOTE_HOME}/assistant.py"
echo "  ${REMOTE_HOME}/genie_server.py"
echo "  ${REMOTE_HOME}/models/hey_peregrine.onnx"
echo "  ${REMOTE_HOME}/models/hey_peregrine.onnx.data"
echo "  /etc/systemd/system/voice-assistant.service"
echo "  /etc/systemd/system/genie-server.service"
echo ""

# Show current env config
ENV_STATUS=$($SSH "$TARGET" "cat ${REMOTE_HOME}/assistant.env 2>/dev/null | grep -v '^#' | grep -v '^\$' || true")
if [[ -n "$ENV_STATUS" ]]; then
    echo "Active environment config (~/assistant.env):"
    echo "$ENV_STATUS" | sed 's/^/  /'
else
    echo "No active config in ~/assistant.env (all defaults)."
    echo "To configure MQTT, edit on the board:"
    echo "  nano ~/assistant.env"
fi

echo ""
echo "Restart the service:"
echo "  systemctl restart voice-assistant"
echo "  journalctl -u voice-assistant -f"
echo ""
