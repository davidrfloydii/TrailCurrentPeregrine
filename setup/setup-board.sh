#!/usr/bin/env bash
# ============================================================================
# Voice Assistant — Board Setup & Hardening
# For Radxa Dragon Q6A (Qualcomm QCS6490, Ubuntu Noble 24.04, 8 GB RAM)
#
# Combines provisioning (packages, users, models) with system hardening
# (disable desktop, tune CPU, power-down unused hardware).
#
# Idempotent — safe to re-run on a fresh board or an existing one.
# Each step checks whether work is already done and skips if so.
#
# Prerequisites:
#   - Radxa OS R2 (Noble) flashed to the board (see docs/board-setup.md)
#   - Board connected to the network with SSH access as root
#
# Fresh board:
#   chmod +x setup-board.sh && sudo ./setup-board.sh
#
# Existing board (e.g., after OS update or to apply new hardening):
#   sudo ./setup-board.sh
#
# After setup, deploy application code from your dev machine:
#   ./deploy.sh <board-ip>
# ============================================================================

set -uo pipefail

ASSISTANT_USER="assistant"
ASSISTANT_HOME="/home/${ASSISTANT_USER}"
VENV_DIR="${ASSISTANT_HOME}/assistant-env"
PIPER_VOICE="en_US-libritts_r-medium"
PIPER_VOICE_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/libritts_r/medium"
PIPER_DIR="${ASSISTANT_HOME}/piper-voices"
NPU_MODEL_DIR="${ASSISTANT_HOME}/Llama3.2-1B-1024-v68"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }
fatal(){ echo -e "${RED}[FATAL]${NC} $*"; exit 1; }

ERRORS=0
step_fail() { err "$*"; ERRORS=$((ERRORS + 1)); }

[[ $(id -u) -eq 0 ]] || fatal "Run this script as root"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "============================================"
echo "  Voice Assistant — Board Setup & Hardening"
echo "  Radxa Dragon Q6A (QCS6490)"
echo "============================================"
echo ""

# ============================================================================
# 1. Radxa QCS6490 apt repository (for NPU packages)
# ============================================================================
log "1. Radxa QCS6490 apt repository"

if [[ -f /etc/apt/sources.list.d/70-qcs6490-noble.list ]]; then
    log "  Radxa QCS6490 repo already configured"
else
    log "  Adding Radxa QCS6490 repository..."
    curl -s https://radxa-repo.github.io/qcs6490-noble/install.sh | sh \
        || step_fail "Failed to add Radxa QCS6490 repo"
fi

# ============================================================================
# 2. System packages
# ============================================================================
log "2. System packages"

apt-get update -y || step_fail "apt update failed"
apt-get upgrade -y || warn "apt upgrade had issues (continuing)"

apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    curl \
    wget \
    ffmpeg \
    alsa-utils \
    libsndfile1 \
    libasound2-dev \
    avahi-daemon \
    htop \
|| step_fail "Some packages failed to install"

# ============================================================================
# 3. NPU packages (Qualcomm Hexagon DSP via FastRPC)
# ============================================================================
log "3. NPU packages (FastRPC / libcdsprpc)"

apt-get install -y fastrpc libcdsprpc1 \
    || step_fail "Failed to install NPU packages (fastrpc, libcdsprpc1)"

# Verify the CDSP remoteproc is running
if [[ -d /sys/class/remoteproc ]]; then
    for rp in /sys/class/remoteproc/remoteproc*/; do
        fw=$(cat "${rp}firmware" 2>/dev/null || true)
        state=$(cat "${rp}state" 2>/dev/null || true)
        if echo "$fw" | grep -q cdsp; then
            if [[ "$state" == "running" ]]; then
                log "  CDSP remoteproc: running ($fw)"
            else
                warn "  CDSP remoteproc state: $state (expected 'running')"
            fi
        fi
    done
fi

# ============================================================================
# 4. Create dedicated user
# ============================================================================
log "4. Assistant user"

if id "${ASSISTANT_USER}" &>/dev/null; then
    log "  User '${ASSISTANT_USER}' already exists"
else
    useradd -m -s /bin/bash -G audio,render "${ASSISTANT_USER}" \
        || step_fail "Failed to create user '${ASSISTANT_USER}'"
fi

usermod -aG audio,render "${ASSISTANT_USER}" 2>/dev/null || true

# ============================================================================
# 5. NPU LLM model (Llama3.2-1B for Hexagon v68)
# ============================================================================
log "5. NPU LLM model (Llama3.2-1B-1024-v68)"

if [[ -f "${NPU_MODEL_DIR}/genie-t2t-run" && -d "${NPU_MODEL_DIR}/models" ]]; then
    log "  NPU model already downloaded at ${NPU_MODEL_DIR}"
else
    log "  Installing modelscope..."
    pip3 install --break-system-packages -q modelscope 2>/dev/null \
        || step_fail "Failed to install modelscope"

    log "  Downloading Llama3.2-1B-1024-v68 from ModelScope (this will take a while)..."
    modelscope download --model radxa/Llama3.2-1B-1024-qairt-v68 --local "${NPU_MODEL_DIR}" \
        || step_fail "Failed to download NPU model"
fi

# Ensure genie-t2t-run is executable
if [[ -f "${NPU_MODEL_DIR}/genie-t2t-run" ]]; then
    chmod +x "${NPU_MODEL_DIR}/genie-t2t-run"
    log "  genie-t2t-run is ready"
fi

# ============================================================================
# 6. Python virtual environment and packages
# ============================================================================
log "6. Python virtual environment"

if [[ -x "${VENV_DIR}/bin/python3" ]]; then
    log "  Venv already exists at ${VENV_DIR}"
else
    python3 -m venv "${VENV_DIR}" || step_fail "Failed to create venv"
fi

if [[ -x "${VENV_DIR}/bin/python3" ]]; then
    log "  Installing/upgrading Python packages..."
    "${VENV_DIR}/bin/pip" install --upgrade pip 2>/dev/null || true
    "${VENV_DIR}/bin/pip" install \
        faster-whisper \
        piper-tts \
        paho-mqtt \
        numpy \
        scipy \
        scikit-learn \
        pathvalidate \
        requests \
        timezonefinder \
    || step_fail "Some Python packages failed to install"

    # openwakeword installed separately with --no-deps because tflite-runtime
    # has no aarch64 wheel. We only use ONNX inference so tflite is not needed.
    # --force-reinstall ensures resource files (melspectrogram.onnx, embedding_model.onnx)
    # are included even when upgrading across major versions.
    "${VENV_DIR}/bin/pip" install --force-reinstall --no-deps openwakeword \
    || step_fail "openwakeword install failed"

    # Download openwakeword resource models (melspectrogram.onnx, embedding_model.onnx)
    # These are not included in the wheel and must be downloaded separately.
    log "  Downloading openwakeword resource models..."
    "${VENV_DIR}/bin/python3" -c "
import openwakeword
openwakeword.utils.download_models()
print('  Resource models downloaded')
" || warn "openwakeword resource model download failed (non-fatal)"

    log "  Verifying wake word model loads..."
    "${VENV_DIR}/bin/python3" -c "
from openwakeword.model import Model
m = Model()
print('  Wake word model OK')
del m
" || warn "Wake word model verification failed (non-fatal)"
fi

# ============================================================================
# 7. Custom wake word model
# ============================================================================
log "7. Custom wake word model (hey_peregrine)"

WAKE_MODEL_DIR="${ASSISTANT_HOME}/models"
mkdir -p "${WAKE_MODEL_DIR}"
MODELS_SRC="${SCRIPT_DIR}/../models"
if [[ -f "${MODELS_SRC}/hey_peregrine.onnx" ]]; then
    cp "${MODELS_SRC}/hey_peregrine.onnx" "${WAKE_MODEL_DIR}/"
    cp "${MODELS_SRC}/hey_peregrine.onnx.data" "${WAKE_MODEL_DIR}/" 2>/dev/null || true
    log "  Installed hey_peregrine wake word model"
else
    warn "  hey_peregrine.onnx not found in ${MODELS_SRC} — using default wake word"
fi

# ============================================================================
# 8. Piper TTS voice
# ============================================================================
log "8. Piper TTS voice"

mkdir -p "${PIPER_DIR}"

if [[ -f "${PIPER_DIR}/${PIPER_VOICE}.onnx" ]]; then
    log "  Piper voice already downloaded"
else
    wget -q --show-progress -O "${PIPER_DIR}/${PIPER_VOICE}.onnx" \
        "${PIPER_VOICE_URL}/${PIPER_VOICE}.onnx" \
    || step_fail "Failed to download Piper voice model"

    wget -q -O "${PIPER_DIR}/${PIPER_VOICE}.onnx.json" \
        "${PIPER_VOICE_URL}/${PIPER_VOICE}.onnx.json" \
    || warn "Failed to download Piper voice config (non-fatal)"
fi

# ============================================================================
# 9. systemd services (genie-server + voice-assistant)
# ============================================================================
log "9. systemd services"

# Genie NPU server — thin HTTP wrapper around genie-t2t-run
# No hardening (ProtectSystem etc.) — it breaks DSP access via /dev/fastrpc-*
cat > /etc/systemd/system/genie-server.service << EOF
[Unit]
Description=Genie NPU LLM Server (Llama3.2-1B on Hexagon DSP)
After=network.target

[Service]
Type=simple
User=${ASSISTANT_USER}
Group=audio
SupplementaryGroups=render
WorkingDirectory=${ASSISTANT_HOME}
ExecStart=/usr/bin/python3 ${ASSISTANT_HOME}/genie_server.py
Restart=on-failure
RestartSec=5

Environment=HOME=${ASSISTANT_HOME}
Environment=PYTHONUNBUFFERED=1
Environment=GENIE_DIR=${NPU_MODEL_DIR}

[Install]
WantedBy=multi-user.target
EOF

# Voice assistant — depends on genie-server for LLM inference
cat > /etc/systemd/system/voice-assistant.service << EOF
[Unit]
Description=Local Voice Assistant
After=network.target sound.target genie-server.service
Wants=genie-server.service

[Service]
Type=simple
User=${ASSISTANT_USER}
Group=audio
WorkingDirectory=${ASSISTANT_HOME}
ExecStartPre=/bin/sleep 5
ExecStart=${VENV_DIR}/bin/python3 ${ASSISTANT_HOME}/assistant.py
Restart=on-failure
RestartSec=10

# Environment
Environment=HOME=${ASSISTANT_HOME}
Environment=WAKE_MODEL_PATH=${ASSISTANT_HOME}/models/hey_peregrine.onnx
Environment=PATH=${VENV_DIR}/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONUNBUFFERED=1
# Site-specific config (MQTT, thresholds, etc.) lives in this file on the board.
# It is never overwritten by setup or deploy. Edit it with: nano ~/assistant.env
EnvironmentFile=-${ASSISTANT_HOME}/assistant.env

# Hardening
ProtectSystem=strict
ReadWritePaths=${ASSISTANT_HOME} /tmp
ProtectHome=tmpfs
BindPaths=${ASSISTANT_HOME}
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable genie-server 2>/dev/null || true
systemctl enable voice-assistant 2>/dev/null || true
log "  Services installed and enabled"

# Create default env file if it doesn't exist (never overwrite)
if [[ ! -f "${ASSISTANT_HOME}/assistant.env" ]]; then
    cat > "${ASSISTANT_HOME}/assistant.env" << 'ENVEOF'
# Voice assistant environment config — persists across deploys and setup runs.
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
ENVEOF
    log "  Created default assistant.env (edit to configure MQTT)"
else
    log "  assistant.env already exists (not overwritten)"
fi

# ============================================================================
# 10. File ownership
# ============================================================================
log "10. File ownership"

chown -R "${ASSISTANT_USER}:${ASSISTANT_USER}" "${ASSISTANT_HOME}"

# ============================================================================
# 11. Disable graphical desktop
# ============================================================================
log "11. Disable graphical desktop"

if systemctl get-default | grep -q graphical; then
    systemctl set-default multi-user.target
    log "  Set default target to multi-user (CLI only)"
else
    log "  Already CLI-only"
fi

for dm in gdm3 gdm lightdm sddm; do
    if systemctl is-enabled "$dm" 2>/dev/null | grep -q enabled; then
        systemctl disable --now "$dm" 2>/dev/null
        log "  Disabled $dm"
    fi
done

# ============================================================================
# 12. Disable unnecessary services
# ============================================================================
log "12. Disable unnecessary services"

DISABLE_SERVICES=(
    accounts-daemon
    colord
    switcheroo-control
    power-profiles-daemon
    udisks2
    cups cups-browsed
    ModemManager
    wpa_supplicant
    bluetooth
    snapd snapd.socket snapd.seeded
    fwupd
    packagekit
    unattended-upgrades
    apt-daily.timer
    apt-daily-upgrade.timer
    motd-news.timer
    man-db.timer
    e2scrub_all.timer
    fstrim.timer
)

for svc in "${DISABLE_SERVICES[@]}"; do
    if systemctl is-enabled "$svc" 2>/dev/null | grep -qE "enabled|static"; then
        systemctl disable --now "$svc" 2>/dev/null
        log "  Disabled $svc"
    fi
done

# ============================================================================
# 13. Disable PulseAudio / PipeWire (assistant uses ALSA directly)
# ============================================================================
log "13. Disable PulseAudio/PipeWire"

for svc in pulseaudio pipewire pipewire-pulse wireplumber; do
    systemctl --global disable "$svc.service" "$svc.socket" 2>/dev/null || true
done
killall pulseaudio 2>/dev/null || true

# System-wide autospawn disable
if [[ -f /etc/pulse/client.conf ]]; then
    grep -q "autospawn = no" /etc/pulse/client.conf 2>/dev/null || \
        echo "autospawn = no" >> /etc/pulse/client.conf
else
    mkdir -p /etc/pulse
    echo "autospawn = no" > /etc/pulse/client.conf
fi

# Per-user disable
mkdir -p "${ASSISTANT_HOME}/.config/pulse"
cat > "${ASSISTANT_HOME}/.config/pulse/client.conf" << 'PAEOF'
autospawn = no
PAEOF
chown -R "${ASSISTANT_USER}:${ASSISTANT_USER}" "${ASSISTANT_HOME}/.config"

su - "${ASSISTANT_USER}" -c "systemctl --user mask pulseaudio.service pulseaudio.socket 2>/dev/null" || true
loginctl enable-linger "${ASSISTANT_USER}" 2>/dev/null || warn "enable-linger failed"

log "  Audio daemons disabled, autospawn blocked"

# ============================================================================
# 14. Kernel / sysctl tuning
# ============================================================================
log "14. Kernel tuning"

cat > /etc/sysctl.d/90-assistant.conf << 'EOF'
# Reduce swap pressure — keep inference models in RAM
vm.swappiness = 10

# Reduce filesystem dirty page writebacks (less I/O contention)
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5

# Increase inotify limits
fs.inotify.max_user_watches = 65536

# Reduce kernel log verbosity
kernel.printk = 4 4 1 7
EOF

sysctl --system > /dev/null 2>&1
log "  Applied sysctl tuning"

# ============================================================================
# 15. CPU governor — performance
# ============================================================================
log "15. CPU governor"

if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$cpu" 2>/dev/null || true
    done

    cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable cpu-performance 2>/dev/null
    log "  CPU governor set to performance (persists across reboots)"
else
    warn "  cpufreq not available — skipping"
fi

# ============================================================================
# 16. Remove snap
# ============================================================================
log "16. Remove snap"

if command -v snap &>/dev/null; then
    snap list 2>/dev/null | tail -n+2 | awk '{print $1}' | while read -r pkg; do
        snap remove --purge "$pkg" 2>/dev/null || true
    done
    apt-get remove -y --purge snapd 2>/dev/null || true
    rm -rf /snap /var/snap /var/lib/snapd
    log "  Snap removed"
else
    log "  Snap not installed"
fi

# ============================================================================
# 17. Clean up desktop packages
# ============================================================================
log "17. Package cleanup"

REMOVE_PKGS=""
for pkg in xserver-xorg x11-common gnome-shell ubuntu-desktop firefox thunderbird libreoffice-core; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        REMOVE_PKGS="$REMOVE_PKGS $pkg"
    fi
done

if [[ -n "$REMOVE_PKGS" ]]; then
    log "  Desktop packages found:$REMOVE_PKGS"
    log "  Run manually to remove: apt remove -y --purge$REMOVE_PKGS && apt autoremove -y"
    log "  (Not auto-removing to avoid surprises — review first)"
else
    log "  No desktop packages to remove"
fi

apt-get autoremove -y 2>/dev/null || true
apt-get clean 2>/dev/null || true

# ============================================================================
# 18. QCS6490 power: disable unused hardware
# ============================================================================
log "18. Disable unused QCS6490 hardware (GPU, HDMI, video codecs)"

# USB runtime power management (skip audio devices — they must stay awake)
for dev in /sys/bus/usb/devices/*/power/control; do
    devpath=$(dirname "$dev")
    # Keep audio devices active (class 01 = audio)
    is_audio=false
    for iface in "$devpath"/*:*/bInterfaceClass; do
        if [[ -f "$iface" ]] && grep -q "01" "$iface" 2>/dev/null; then
            is_audio=true
            break
        fi
    done
    if [[ -f "$devpath/product" ]] && grep -qi "jabra\|audio\|sound\|speak" "$devpath/product" 2>/dev/null; then
        is_audio=true
    fi
    if $is_audio; then
        echo on > "$dev" 2>/dev/null || true
    else
        echo auto > "$dev" 2>/dev/null || true
    fi
done
log "  USB runtime power management: auto (audio devices excluded)"

# GPU (Adreno 643) — lock to minimum frequency if devfreq is available
for gpu in /sys/class/devfreq/*gpu* /sys/class/devfreq/*3d00000*; do
    if [[ -f "$gpu/governor" ]]; then
        echo powersave > "$gpu/governor" 2>/dev/null && \
            log "  GPU devfreq governor: powersave"
    fi
    if [[ -f "$gpu/min_freq" && -f "$gpu/available_frequencies" ]]; then
        min_freq=$(awk '{print $1}' "$gpu/available_frequencies" 2>/dev/null)
        if [[ -n "$min_freq" ]]; then
            echo "$min_freq" > "$gpu/max_freq" 2>/dev/null
            echo "$min_freq" > "$gpu/min_freq" 2>/dev/null
            log "  GPU frequency locked to minimum: ${min_freq}Hz"
        fi
    fi
done

# Unbind unused platform drivers (QCS6490-specific)
# NOTE: Do NOT unbind fastrpc or cdsp — the NPU needs them!
_unbind_driver() {
    local drv_path="/sys/bus/platform/drivers/$1"
    local label="$2"
    if [[ -d "$drv_path" ]]; then
        for dev in "$drv_path"/*/; do
            local devname
            devname=$(basename "$dev")
            [[ "$devname" == "module" || "$devname" == "uevent" ]] && continue
            echo "$devname" > "$drv_path/unbind" 2>/dev/null && \
                log "  Unbound ${label}: $devname"
        done
    fi
}

# Display and video (headless — not needed)
_unbind_driver msm_dsi     "display DSI"
_unbind_driver msm_dp      "DisplayPort"
_unbind_driver msm_mdss    "display controller"

# Camera (not used)
_unbind_driver camss       "camera subsystem"

# WiFi power save
iw dev 2>/dev/null | grep Interface | awk '{print $2}' | while read -r iface; do
    iw "$iface" set power_save on 2>/dev/null && \
        log "  WiFi power save enabled on $iface"
done

# Persist hardware power-down across reboots
cat > /etc/systemd/system/power-save-hw.service << 'PWREOF'
[Unit]
Description=Disable unused QCS6490 hardware for power savings
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  for gpu in /sys/class/devfreq/*gpu* /sys/class/devfreq/*3d00000*; do \
    [ -f "$gpu/governor" ] && echo powersave > "$gpu/governor"; \
    min=$(awk "{print \\$1}" "$gpu/available_frequencies" 2>/dev/null); \
    [ -n "$min" ] && echo "$min" > "$gpu/max_freq" && echo "$min" > "$gpu/min_freq"; \
  done; \
  for drv in msm_dsi msm_dp msm_mdss camss; do \
    d="/sys/bus/platform/drivers/$drv"; [ -d "$d" ] && \
    for dev in "$d"/*/; do n=$(basename "$dev"); \
      [ "$n" != module ] && [ "$n" != uevent ] && echo "$n" > "$d/unbind" 2>/dev/null; \
    done; \
  done; \
  for dev in /sys/bus/usb/devices/*/power/control; do \
    dp=$(dirname "$dev"); audio=false; \
    for ifc in "$dp"/*:*/bInterfaceClass; do \
      [ -f "$ifc" ] && grep -q 01 "$ifc" 2>/dev/null && audio=true && break; \
    done; \
    $audio && echo on > "$dev" 2>/dev/null || echo auto > "$dev" 2>/dev/null; \
  done; \
  true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
PWREOF

systemctl daemon-reload
systemctl enable power-save-hw 2>/dev/null
log "  Hardware power-down service installed (persists across reboots)"

# ============================================================================
# 19. Set hostname
# ============================================================================
log "19. Hostname"

CURRENT_HOSTNAME=$(hostname)
DESIRED_HOSTNAME="radxa-dragon-q6a"
if [[ "$CURRENT_HOSTNAME" != "$DESIRED_HOSTNAME" ]]; then
    hostnamectl set-hostname "$DESIRED_HOSTNAME"
    log "  Hostname set to $DESIRED_HOSTNAME (was $CURRENT_HOSTNAME)"
else
    log "  Hostname already $DESIRED_HOSTNAME"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
if [[ ${ERRORS} -eq 0 ]]; then
    log "============================================"
    log "  Setup complete! All steps passed."
    log "============================================"
else
    warn "============================================"
    warn "  Setup finished with ${ERRORS} error(s)."
    warn "  Review output above, fix issues, re-run."
    warn "============================================"
fi

echo ""
echo "Next steps:"
echo ""
echo "  1. Deploy assistant code from your dev machine:"
echo "     ./deploy.sh <board-ip>"
echo ""
echo "  2. Configure MQTT on the board:"
echo "     nano ${ASSISTANT_HOME}/assistant.env"
echo ""
echo "  3. Start the service:"
echo "     systemctl start voice-assistant"
echo "     journalctl -u voice-assistant -f"
echo ""
echo "  4. Reboot to apply all hardening changes:"
echo "     reboot"
echo ""
echo "Test commands:"
echo ""
echo "  # Test speaker"
echo "  speaker-test -t wav -c 2 -l 1"
echo ""
echo "  # Test microphone (record 5 sec, play back)"
echo "  arecord -d 5 -f S16_LE -r 16000 /tmp/test.wav && aplay /tmp/test.wav"
echo ""
echo "  # Test Piper TTS"
echo "  echo 'Hello, I am your voice assistant.' | \\"
echo "    ${VENV_DIR}/bin/piper --model ${PIPER_DIR}/${PIPER_VOICE}.onnx --output-raw | \\"
echo "    aplay -r 22050 -f S16_LE -c 1"
echo ""
echo "  # Test NPU inference (Llama3.2-1B on Hexagon DSP)"
echo "  cd ${NPU_MODEL_DIR} && export LD_LIBRARY_PATH=\$(pwd) && \\"
echo "    ./genie-t2t-run -c htp-model-config-llama32-1b-gqa.json \\"
echo "    -p '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\nYou are a helpful assistant.<|eot_id|><|start_header_id|>user<|end_header_id|>\n\nSay hello.<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n'"
echo ""
echo "  # Test genie server (NPU LLM over HTTP)"
echo "  curl -s http://localhost:11434/api/generate -d '{\"prompt\":\"Say hello\",\"system\":\"Reply in one sentence.\"}' | python3 -m json.tool"
echo ""
