# Radxa Dragon Q6A Board Setup

Complete guide for flashing and provisioning the Radxa Dragon Q6A for the
TrailCurrent Peregrine voice assistant. Follow every step in order.

## Hardware

| Item | Details |
|---|---|
| **Board** | Radxa Dragon Q6A (Qualcomm QCS6490, 8 GB RAM) |
| **SoC** | Qualcomm QCS6490 — ARM64, Hexagon DSP/NPU (12 TOPS) |
| **Storage** | M.2 2230 NVMe SSD (installed in the M.2 M Key slot) |
| **OS** | Radxa OS Noble (Ubuntu 24.04 based), R2 release |
| **Audio** | USB microphone + speaker (ALSA, no PulseAudio) |

## What You Need

### On the board
- NVMe SSD installed in the M.2 M Key 2230 slot
- 12 V USB-C power adapter (PD compatible)

### On your Linux host (dev machine)
- USB Type-A to Type-A cable (male-to-male)
- USB 3.0 port
- ~2 GB free disk space for downloads

## Part 1: Flash the Board

> **NVMe vs UFS:** This guide uses NVMe storage. If you are using UFS instead,
> substitute `--memory UFS` for `--memory nvme` in the flash commands, and
> download the `output_4096` image instead of `output_512`. Everything else is
> the same.

### 1.1 Download everything

Create a working directory and download the required files:

```bash
mkdir -p ~/dragon-flash && cd ~/dragon-flash

# EDL flashing tool (Linux, no drivers needed)
wget https://dl.radxa.com/q6a/images/edl-ng-dist.zip

# SPI boot firmware (version 260120 — required for R1+ images)
wget https://dl.radxa.com/dragon/q6a/images/dragon-q6a_flat_build_wp_260120.zip

# Radxa OS R2 for NVMe (512-byte sector image)
wget https://github.com/radxa-build/radxa-dragon-q6a/releases/download/rsdk-r2/radxa-dragon-q6a_noble_gnome_r2.output_512.img.xz
```

### 1.2 Extract the downloads

```bash
cd ~/dragon-flash

# EDL tool — the outer zip contains an inner zip with platform-specific binaries
unzip -o edl-ng-dist.zip -d edl-ng-dist
unzip -o edl-ng-dist/edl-ng-dist.zip -d edl-ng-dist
# If your dev machine is not x86_64, substitute the matching directory:
#   linux-arm64, macos-x64, macos-arm64, windows-x64, windows-arm64
chmod +x edl-ng-dist/linux-x64/edl-ng

# SPI boot firmware
unzip -o dragon-q6a_flat_build_wp_260120.zip

# OS image — decompress (keeps the .xz original). This takes a few minutes.
xz -dk radxa-dragon-q6a_noble_gnome_r2.output_512.img.xz
```

Verify you have these files:

```bash
ls -lh edl-ng-dist/linux-x64/edl-ng
# Expected: -rwxr-xr-x ... 7.4M ... edl-ng-dist/linux-x64/edl-ng

ls flat_build/spinor/dragon-q6a/prog_firehose_ddr.elf
# Expected: flat_build/spinor/dragon-q6a/prog_firehose_ddr.elf

ls -lh radxa-dragon-q6a_noble_gnome_r2.output_512.img
# Expected: -rw-rw-r-- ... 5.6G ... radxa-dragon-q6a_noble_gnome_r2.output_512.img
```

If any command returns "No such file or directory", re-check the extract steps above.

### 1.3 Do you need to flash the SPI firmware?

Radxa OS R2 requires SPI boot firmware version **260120** or newer.

- **Fresh board / first time setup:** Yes — proceed with step 1.4.
- **Re-flashing a board that already runs Radxa OS R2:** You can check the
  current firmware version from the running board before wiping it:
  ```bash
  ssh root@<board-ip> "dmidecode -s bios-version"
  ```
  If the output is `260120` or higher, **skip steps 1.4–1.5 and go directly
  to 1.6**. Otherwise, proceed with step 1.4.

### 1.4 Enter EDL mode

The EDL (Emergency Download) button is located next to the audio jack on the
board (position 14 on the Radxa board diagram).

1. **Disconnect power** (USB-C) from the board completely.
2. **Connect the USB-A to USB-A cable** between the board's **USB 3.1 Type-A
   port** and your Linux host. This is the OTG port — it is the single
   USB-A port that supports USB 3.x (typically blue inside), separate from
   the three USB 2.0 Type-A ports. Do **not** use one of the USB 2.0 ports.
3. **Press and hold the EDL button** (located next to the audio jack).
4. **While holding the EDL button**, connect the **12 V USB-C power adapter**
   to power on the board.
5. **Release the EDL button** after about 1 second.

Verify the board is in EDL mode:

```bash
lsusb | grep 05c6:9008
```

You should see:

```
Bus XXX Device XXX: ID 05c6:9008 Qualcomm, Inc. Gobi Wireless Modem (QDL mode)
```

If `05c6:9008` does not appear, disconnect everything and repeat. The timing
matters — hold the button **before** power, release **after**.

### 1.5 Flash the SPI boot firmware

```bash
cd ~/dragon-flash/flat_build/spinor/dragon-q6a/

sudo ~/dragon-flash/edl-ng-dist/linux-x64/edl-ng \
    --memory spinor \
    --loader prog_firehose_ddr.elf \
    rawprogram rawprogram0.xml patch0.xml
```

This takes about 2 minutes. Ignore any "missing fat12test.bin" warnings — they
are harmless.

### 1.6 Flash Radxa OS to NVMe

The board should still be in EDL mode after the SPI flash. If not, re-enter
EDL mode (step 1.4).

```bash
cd ~/dragon-flash/flat_build/spinor/dragon-q6a/

sudo ~/dragon-flash/edl-ng-dist/linux-x64/edl-ng \
    --loader prog_firehose_ddr.elf \
    --memory nvme \
    write-sector 0 ~/dragon-flash/radxa-dragon-q6a_noble_gnome_r2.output_512.img
```

This writes the full OS image to the NVMe. It takes a few minutes depending on
the SSD speed.

### 1.7 Reset the board

```bash
sudo ~/dragon-flash/edl-ng-dist/linux-x64/edl-ng \
    --loader prog_firehose_ddr.elf \
    reset
```

Disconnect the USB-A cable. The board will reboot into Radxa OS.

### 1.8 First boot

Connect a **display** (HDMI or USB-C DisplayPort), **keyboard**, and **mouse** to the
board. The GNOME desktop image requires a display for initial setup. You will
switch to headless (SSH-only) operation after provisioning.

Disconnect the USB-A flashing cable if still connected, then power the board via
the 12 V USB-C adapter. Wait about 60 seconds for the first boot.

**Default login:** username `radxa`, password `radxa`

Log in at the GNOME desktop (or TTY if the desktop hasn't started yet).

#### Resize the NVMe partition

The flashed image has a small root partition. Expand it to use the full SSD:

```bash
# Check current size
df -h /
# Expected: ~5-6 GB used, small total

# Resize partition and filesystem to fill the NVMe
sudo growpart /dev/nvme0n1 1
sudo resize2fs /dev/nvme0n1p1

# Verify
df -h /
# Expected: total now matches your SSD size (e.g. 238G for a 256 GB drive)
```

#### Generate SSH host keys and enable SSH

```bash
# Generate host keys (may already exist — this is safe to run either way)
sudo ssh-keygen -A

# Enable and start the SSH server
sudo systemctl enable ssh
sudo systemctl start ssh

# Reboot for SSH to accept connections
sudo reboot
```

After the board reboots, log back in at the display with username `radxa`,
password `radxa`.

```bash
# Verify SSH is running
sudo systemctl status ssh
# Expected: "active (running)"
```

#### Connect the board to your network

Plug in an Ethernet cable, or connect to Wi-Fi via the GNOME desktop network
settings. Then find the board's IP address:

```bash
ip addr show | grep "inet "
# Look for your LAN IP (e.g. 192.168.1.x), not 127.0.0.1
```

Note this IP address — you will use it as `<board-ip>` in all remaining steps.

#### Verify SSH access from your dev machine

From your **dev machine** (not the board), verify you can reach it:

```bash
ssh radxa@<board-ip>
# Password: radxa
```

If this works, you can disconnect the display, keyboard, and mouse. All
remaining steps are done over SSH.

### 1.9 SSH in and set the root password

```bash
ssh radxa@<board-ip>
# Password: radxa

# Set a root password (needed for setup script)
sudo passwd root

# Enable root SSH (temporarily — setup script creates a dedicated user)
sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

Log out and copy your SSH key for passwordless access:

```bash
ssh-copy-id root@<board-ip>
```

Verify:

```bash
ssh root@<board-ip> "hostname && cat /proc/device-tree/model"
```

You should see `Radxa Dragon Q6A`.

### 1.10 Verify the SPI firmware version

```bash
ssh root@<board-ip> "dmidecode -s bios-version"
```

Should show `260120` or newer.

## Part 2: Provision the Board

### 2.1 Copy the setup script to the board

From your dev machine, in the TrailCurrentPeregrine project root:

```bash
scp setup/setup-board.sh root@<board-ip>:/root/setup-board.sh
```

### 2.2 Run the setup script

SSH into the board and run:

```bash
ssh root@<board-ip>
chmod +x /root/setup-board.sh
/root/setup-board.sh
```

The script is **idempotent** — safe to re-run at any time. It performs:

1. Adds the Radxa QCS6490 apt repository (for NPU packages)
2. Installs system packages (Python, ffmpeg, ALSA, etc.)
3. Installs NPU packages (fastrpc, libcdsprpc)
4. Creates the `assistant` user (added to `audio` and `render` groups)
5. Downloads the NPU LLM model (Llama 3.2 1B for Hexagon v68)
6. Creates a Python venv with all dependencies
7. Deploys the custom wake word model
8. Downloads the Piper TTS voice model
9. Installs systemd services (genie-server + voice-assistant)
10. Hardens the board (disables desktop, GPU, HDMI, snap, unnecessary services)
11. Sets CPU governor to performance
12. Tunes kernel parameters (swappiness, dirty pages)

### 2.3 Reboot

After setup completes, reboot to apply all changes:

```bash
reboot
```

The board will boot to CLI (no desktop). The voice assistant service starts
automatically.

### 2.4 Deploy the application code

From your dev machine:

```bash
./deploy.sh <board-ip>
```

Then restart the service:

```bash
ssh root@<board-ip> "systemctl restart voice-assistant"
```

## Part 3: Verify Everything Works

### 3.1 Check the service

```bash
ssh root@<board-ip> "systemctl status voice-assistant"
ssh root@<board-ip> "journalctl -u voice-assistant -n 50"
```

### 3.2 Test audio

```bash
ssh root@<board-ip>

# List audio devices
aplay -l
arecord -l

# Speaker test
speaker-test -t wav -c 2 -l 1

# Record and playback
arecord -d 5 -f S16_LE -r 16000 /tmp/test.wav && aplay /tmp/test.wav
```

### 3.3 Test NPU inference

```bash
ssh root@<board-ip>

cd /home/assistant/Llama3.2-1B-1024-v68
export LD_LIBRARY_PATH=$(pwd)
./genie-t2t-run -c htp-model-config-llama32-1b-gqa.json \
    -p "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\nYou are a helpful assistant.<|eot_id|><|start_header_id|>user<|end_header_id|>\n\nWhat is 2 plus 2?<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
```

Expected output: a coherent answer at ~12 tokens/second.

### 3.4 Test Piper TTS

```bash
ssh root@<board-ip>
su - assistant

echo 'Hello, I am your voice assistant.' | \
    ~/assistant-env/bin/piper \
    --model ~/piper-voices/en_US-libritts_r-medium.onnx \
    --output-raw | \
    aplay -r 22050 -f S16_LE -c 1
```

### 3.5 Test genie server (NPU LLM over HTTP)

```bash
ssh root@<board-ip> "curl -s http://localhost:11434/api/generate \
    -d '{\"prompt\":\"Say hello\",\"system\":\"Reply in one sentence.\"}' | python3 -m json.tool"
```

## Troubleshooting

### EDL mode: `05c6:9008` not showing up

- Ensure the USB-A cable is in the OTG port (not a regular USB host port).
- Try a different USB cable — some cables are charge-only.
- Hold the EDL button **before** connecting power, release **after**.

### Board not booting after flash

- Re-enter EDL mode and re-flash both SPI firmware and the OS image.
- Verify you used the `output_512` image (not `output_4096` which is for UFS).

### NPU test fails with "Failed to create device"

- Verify `cdsprpcd` is running: `pgrep cdsprpcd`
- Check DSP firmware loaded: `cat /sys/class/remoteproc/remoteproc*/state`
  (should say `running`)
- Ensure you are on Radxa OS (not Armbian) — Armbian is missing DSP
  userspace binaries.

### SSH: "Permission denied"

- Default credentials are `radxa` / `radxa`.
- If you set up SSH keys, ensure they were copied to the correct user.

### No audio devices found

- Check `lsusb` for your USB audio device.
- Verify the `assistant` user is in the `audio` group: `groups assistant`
