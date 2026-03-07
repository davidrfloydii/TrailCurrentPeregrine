# openwakeword-trainer

Train custom wake word models with [openWakeWord](https://github.com/dscripka/openWakeWord). A granular 13-step pipeline with compatibility patches for torchaudio 2.10+, Piper TTS, and speechbrain. Generates tiny ONNX models (~200 KB) for real-time keyword detection — like building your own "Hey Siri" trigger.

## What It Does

This toolkit automates the entire openWakeWord training process:

1. **Synthesizes** thousands of speech clips using Piper TTS with varied voices and accents
2. **Augments** clips with real-world noise, music, and room impulse responses
3. **Trains** a small DNN classifier optimized for always-on, low-latency detection
4. **Exports** a tiny ONNX model you can deploy anywhere

The result is a ~200 KB model that runs on CPU in real-time with negligible resource usage.

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **Linux** | Ubuntu recommended (native or WSL2) |
| **NVIDIA GPU** | CUDA drivers installed (WSL2 includes CUDA passthrough automatically) |
| **Disk space** | ~15 GB free (temporary downloads; deletable after training) |
| **Python 3.10+** | `python3 --version` |
| **Time** | ~1–2 hours with GPU, 12–24 hours CPU-only |

### Verify CUDA

```bash
nvidia-smi
python3 -c "import torch; print(torch.cuda.is_available())"
```

You should see your GPU listed and `True` printed. If using WSL2, CUDA passthrough is included automatically with recent NVIDIA Windows drivers.

## Quick Start

### Option A: One-liner

```bash
bash train.sh
```

This creates an isolated virtualenv, installs dependencies, downloads datasets, trains the model, and exports the result.

### Option B: Step-by-step

```bash
# Create & activate a training venv
python3 -m venv ~/.oww-trainer-venv
source ~/.oww-trainer-venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Run the full pipeline
python train_wakeword.py

# Or resume from where you left off
python train_wakeword.py --from augment
```

### Train Your Own Wake Word

1. Copy the example config:
   ```bash
   cp configs/hey_echo.yaml configs/my_word.yaml
   ```

2. Edit `configs/my_word.yaml`:
   ```yaml
   model_name: "my_word"
   target_phrase:
     - "hey computer"
   custom_negative_phrases:
     - "hey commuter"
     - "computer"
     - "hey"
   ```

3. Train:
   ```bash
   python train_wakeword.py --config configs/my_word.yaml
   ```

4. Find your model in `export/my_word.onnx` (and `export/my_word.onnx.data`).

### Improve with Real Voice Recordings

Synthetic TTS clips get you a working model, but real voice recordings significantly improve accuracy. Use the recording script in the parent `training/` directory:

```bash
cd ../

# Positive clips (the wake word itself)
python3 record_wake_word.py --phrase "hey computer" --count 50
python3 record_wake_word.py --phrase "hey computer" --count 50 --auto  # auto mode

# See suggested negative phrases to reduce false positives
python3 record_wake_word.py --suggest

# Negative clips (similar-sounding phrases the model should reject)
python3 record_wake_word.py --phrase "hey commuter" --count 10 --negative --auto
```

Tips for better results:
- Record 200+ positive clips from multiple speakers
- Record 50-100 negative clips from similar-sounding phrases (use `--suggest` for ideas)
- Vary distance, volume, and speaking speed between clips
- Set `augmentation_rounds: 3` in your config for more data diversity
- Positive clips go in `real_clips/<phrase>/`, negative clips go in `real_clips_negative/<phrase>/`

After recording, retrain:
```bash
cd openwakeword-trainer/
python train_wakeword.py --config configs/my_word.yaml
```

### Ambient Noise Negatives

The model needs non-speech negative examples (silence, fan noise, road noise, etc.) to avoid false triggers on ambient sounds. Without these, the model may score ~0.5 on silence instead of ~0.0.

```bash
cd ../  # back to training/

# Generate synthetic noise + download MS-SNSD (MIT) and MUSAN (CC0) recordings
python3 generate_ambient_negatives.py

# Build the ambient feature file (.npy) for training
python3 build_ambient_features.py
```

This populates `real_clips_negative/` with ambient noise clips and produces `data/negative_features_ambient.npy`. Reference this file in your training config:

```yaml
feature_data_files:
  "negative_broad": "data/negative_features_librispeech_voxpopuli.npy"
  "negative_ambient": "data/negative_features_ambient.npy"

batch_n_per_class:
  "negative_broad": 512
  "negative_ambient": 100
  "adversarial_negative": 50
  "positive": 150
```

Ambient clips must be exactly 2 seconds (32000 samples at 16 kHz) to produce the correct feature shape of (N, 16, 96).

## Pipeline Steps

The pipeline runs **13 granular steps**, each with built-in verification. If any step fails, it stops immediately and tells you exactly how to resume.

| # | Step | Description | Time |
|---|------|-------------|------|
| 1 | `check-env` | Verify Python, CUDA, critical imports | instant |
| 2 | `apply-patches` | Patch torchaudio/speechbrain/piper compat | instant |
| 3 | `download` | Download datasets, Piper TTS model, tools | ~30 min |
| 4 | `verify-data` | Check all data files present & sizes | instant |
| 5 | `resolve-config` | Resolve config paths to absolute | instant |
| 6 | `generate` | Generate clips via Piper TTS | ~10 min (GPU) |
| 7 | `resample-clips` | Spot-check clip sample rates | instant |
| 8 | `verify-clips` | Verify clip counts and directories | instant |
| 9 | `augment` | Augment clips & extract mel features | ~30 min |
| 10 | `verify-features` | Check `.npy` feature files & shapes | instant |
| 11 | `train` | Train DNN model + ONNX export | ~30 min (GPU) |
| 12 | `verify-model` | Load-test with ONNX Runtime | instant |
| 13 | `export` | Copy model to `export/` directory | instant |

If any step fails:
```
Pipeline stopped.  Fix the issue above, then resume:
  python train_wakeword.py --from <failed-step>
```

**Important**: The pipeline skips the train step if the output model already exists. Before retraining, always delete the old model:
```bash
rm -f output/hey_peregrine.onnx output/hey_peregrine.onnx.data
rm -f export/hey_peregrine.onnx export/hey_peregrine.onnx.data
```

## CLI Reference

```bash
# Full pipeline (all 13 steps)
python train_wakeword.py

# Use a custom config
python train_wakeword.py --config configs/my_word.yaml

# Resume from a specific step
python train_wakeword.py --from augment

# Run exactly one step
python train_wakeword.py --step verify-clips

# Check current state without side effects
python train_wakeword.py --verify-only

# Show all available steps
python train_wakeword.py --list-steps
```

## Using Your Model

The export step produces two files that must be kept together:

- `hey_peregrine.onnx` — the model graph (~14 KB)
- `hey_peregrine.onnx.data` — external weights (~200 KB)

Copy **both** files to your project. The trained model works with any openWakeWord-compatible runtime:

```python
from openwakeword.model import Model

oww = Model(wakeword_models=["export/hey_peregrine.onnx"])

# Feed 16 kHz audio frames
prediction = oww.predict(audio_frame)
```

Or with ONNX Runtime directly:

```python
import onnxruntime as ort
import numpy as np

sess = ort.InferenceSession("export/hey_peregrine.onnx")
# Input shape: [1, 16, 96] (mel spectrogram features)
result = sess.run(None, {"x": features})
```

**Version compatibility**: The openWakeWord version on your deployment target must match the version used during training (v0.6.0+). Different versions normalize model output differently, causing score offsets (~0.5 baseline instead of ~0.0).

## Configuration Reference

See [configs/hey_echo.yaml](configs/hey_echo.yaml) for a fully commented example. Key settings:

| Setting | Default | hey_peregrine | Description |
|---------|---------|---------------|-------------|
| `model_name` | — | `hey_peregrine` | Name for the model (used for filenames) |
| `target_phrase` | — | `hey peregrine` | List of phrases to detect |
| `custom_negative_phrases` | `[]` | 10 phrases | Phrases to explicitly reject |
| `n_samples` | `50000` | `50000` | Number of positive training clips |
| `tts_batch_size` | `25` | `25` | Piper TTS batch size (reduce for low VRAM) |
| `model_type` | `"dnn"` | `"dnn"` | `"dnn"` or `"rnn"` |
| `layer_size` | `32` | `128` | Hidden layer size (32=fast, 128=higher capacity) |
| `steps` | `50000` | `200000` | Training steps |
| `augmentation_rounds` | `1` | `3` | Data augmentation multiplier |
| `target_false_positives_per_hour` | `0.2` | `0.5` | Target false positive rate |

For multi-word or phonetically complex phrases like "hey peregrine", use `layer_size: 128` and `steps: 200000` for better accuracy.

## Threshold Tuning

After training, tune the detection threshold for your use case:

| Problem | Fix |
|---------|-----|
| False activations (triggers when you didn't say it) | Increase threshold: 0.5 -> 0.6 -> 0.7 |
| Missed activations (need to over-pronounce) | Decrease threshold: 0.5 -> 0.4 -> 0.3 |
| False triggers on similar words | Add to `custom_negative_phrases` and retrain |
| False triggers on silence/ambient noise | Add ambient negatives (see above) and retrain |

Custom models with real voice clips typically work well at threshold 0.5–0.8. Synthetic-only models may need 0.3–0.4.

## Compatibility Patches

This toolkit includes automatic patches for known breaking changes in modern dependency versions:

| Issue | Affected | Patch |
|-------|----------|-------|
| `torchaudio.load()` removed | torchaudio >=2.10 | Soundfile-based replacement with automatic 22050->16000 Hz resampling |
| `torchaudio.info()` removed | torchaudio >=2.10 | Soundfile-based metadata reader |
| `torchaudio.list_audio_backends()` removed | torchaudio >=2.10 | Returns `["soundfile"]` for speechbrain compat |
| `pkg_resources` removed | setuptools >=82 | Auto-installs setuptools<82 |
| Piper API change | piper-sample-generator v2+ | Auto-resolves `model=` kwarg |
| `torchcodec` missing | MIT RIR dataset loading | `pip install torchcodec` |
| `sph_harm` renamed to `sph_harm_y` | scipy >=1.17 + acoustics lib | Wrapper with swapped args |

Patches are applied and verified automatically during the `apply-patches` step.

## Cleanup

After training, reclaim disk space:

```bash
rm -rf data/          # ~12 GB of downloaded datasets
rm -rf output/        # intermediate training artifacts
```

Keep only the `export/` directory with your trained model.

## Troubleshooting

### `piper-phonemize` fails to install
This package only has Linux wheels. If on Windows, make sure you're running inside WSL2.

### Training is very slow
Verify CUDA is available: `python -c "import torch; print(torch.cuda.is_available())"`. If `False`, everything falls back to CPU.

### Out of GPU memory
Reduce `tts_batch_size` in your config (e.g., 25 -> 10). If training on a shared GPU, stop other GPU consumers (e.g., ComfyUI) first.

### Download stalls
Re-run the script — all downloads are idempotent and resume where they left off.

### `ImportError: torchcodec`
Install it: `pip install torchcodec`. Required for loading MIT RIR audio datasets.

### `ImportError: sph_harm` (acoustics library)
scipy 1.17+ renamed `sph_harm` to `sph_harm_y` with different argument order. The pipeline patches this automatically, but if you see this error, check `docs/training_notes.md` for the manual fix.

### Model detects well in training but poorly on real speech
Train with real voice recordings — see "Improve with Real Voice Recordings" above. Synthetic-only models score inconsistently on actual speech. Lower the detection threshold (0.5 or lower) for custom models.

### `onnx_tf` error at end of training
The pipeline exports ONNX successfully but may fail at TFLite conversion (`ModuleNotFoundError: No module named 'onnx_tf'`). This is harmless — we only use the ONNX model.

### Model outputs ~0.5 on silence
Missing ambient noise negatives. See "Ambient Noise Negatives" above. The model has only seen speech negatives and doesn't know how to score non-speech input.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- [openWakeWord](https://github.com/dscripka/openWakeWord) by David Scripka
- [Piper](https://github.com/rhasspy/piper) by Rhasspy for synthetic TTS
- Built with PyTorch, ONNX Runtime, and speechbrain
