# Training Notes & Lessons Learned

Technical notes from building and debugging the openWakeWord training pipeline. Useful if you're troubleshooting issues or want to understand why certain design decisions were made.

## torchaudio 2.10+ Breaking Changes

torchaudio 2.10 (shipped with PyTorch 2.10) removed several APIs that openWakeWord, speechbrain, and torch-audiomentations depend on:

- `torchaudio.load()` — replaced with backend-agnostic API
- `torchaudio.info()` — removed entirely
- `torchaudio.list_audio_backends()` — removed

Our `compat.py` patches these with soundfile-based replacements. The `torchaudio.load` patch also handles automatic resampling from 22050 Hz (Piper TTS output) to 16000 Hz (what openWakeWord expects).

### Why not globally patch `soundfile.read`?

We tried patching `soundfile.read` globally to auto-resample, but this broke torchaudio's internal `_soundfile_load` function which passes extra kwargs (`start`, `stop`, `always_2d`) that don't survive wrapping. The fix was to only patch `torchaudio.load` and let it call `soundfile.read` directly.

## Sample Rate Mismatch

Piper TTS generates audio at 22050 Hz, but openWakeWord expects 16000 Hz throughout. We handle this with on-the-fly resampling in the patched `torchaudio.load` using `scipy.signal.resample`.

We initially tried bulk-resampling all 110k+ WAV files, but this was extremely slow (~75 minutes) on WSL2's `/mnt/c/` filesystem due to the 9P protocol overhead. The on-the-fly approach handles it transparently with no I/O penalty during augmentation.

## ONNX Export

PyTorch 2.x's `torch.onnx.export` now requires `onnxscript` (not installed by default). The export may also attempt a TFLite conversion via `onnx_tf` which isn't needed — the ONNX model is the final output.

The export produces two files:
- `model_name.onnx` — the model graph (~14 KB)
- `model_name.onnx.data` — external weights (~200 KB)

Both files must be kept together for the model to load.

## WSL2 Filesystem Considerations

- **Venvs**: Must be created on WSL2's native filesystem (`~/.oww-trainer-venv`), not on `/mnt/c/`. Symlinks don't work across the 9P boundary.
- **Training data**: Works fine on `/mnt/c/` for reads, but bulk writes are slow. The pipeline handles this by minimizing write operations.
- **setuptools**: Pin to `<82` to keep `pkg_resources` available (required by several dependencies).

## Model Architecture

The example config (`hey_echo.yaml`) uses minimal defaults:
- **DNN** (not RNN) — simpler, faster inference
- **layer_size: 32** — minimal CPU footprint, good enough for single-phrase detection
- **50k training steps** — typically converges well for simple phrases

For multi-word or phonetically complex phrases (like "hey peregrine"), use higher capacity:
- **layer_size: 128** — more parameters for complex phoneme patterns
- **200k training steps** — longer convergence for larger models
- **augmentation_rounds: 3** — more data diversity to prevent overfitting

The `hey_peregrine.yaml` config uses these higher values.

## Augmentation Strategy

The pipeline uses three types of augmentation:
1. **Room Impulse Responses (RIR)** — MIT environmental recordings simulate different room acoustics
2. **Background noise** — AudioSet clips add real-world ambient noise
3. **Background music** — FMA clips add music interference

If HuggingFace dataset downloads fail (rate limits, etc.), the pipeline generates synthetic white noise as a fallback. This works but produces a less robust model.

## Real Voice Recordings

Synthetic TTS clips alone produce a model that triggers inconsistently on real speech. Adding real voice recordings dramatically improves accuracy.

### Recording Clips

Use `training/record_wake_word.py` to record clips:

```bash
# Interactive mode (press Enter for each clip)
python3 record_wake_word.py --phrase "hey peregrine" --count 50

# Auto mode (3-2-1 countdown, no Enter needed)
python3 record_wake_word.py --phrase "hey peregrine" --count 50 --auto
```

Clips are saved to `training/real_clips/hey_peregrine/` as 16 kHz mono WAV files, 2 seconds each. Clips with RMS below 300 are automatically discarded as too quiet.

### Recording Negative Clips

Negative clips teach the model to reject similar-sounding phrases. Use `--suggest` to see a prioritized list of confusable phrases:

```bash
python3 record_wake_word.py --suggest
```

Then record each phrase with the `--negative` flag:

```bash
python3 record_wake_word.py --phrase "hey pelican" --count 10 --negative --auto
python3 record_wake_word.py --phrase "hey penguin" --count 10 --negative --auto
```

Negative clips are saved to `training/real_clips_negative/<phrase>/`. Aim for 50-100 total negative clips across 5-10 different phrases. The most confusable phrases (sharing prefixes like "hey pe-" or endings like "-erine") have the biggest impact.

### Tips for Better Models

- **200+ positive clips** from multiple speakers is a good starting point
- **50-100 negative clips** across similar-sounding phrases reduces false positives
- Vary distance (close, arm's length, across room), volume (whisper to loud), and speaking speed
- Record in different environments (quiet room, with background noise)
- Use **3 augmentation rounds** (`augmentation_rounds: 3` in the config) — this multiplies each clip with different noise/reverb combinations
- Real clips are mixed into the training data alongside the 50k synthetic TTS clips

### Integrating Real Clips

Positive clips in `real_clips/` are automatically picked up by `train_wakeword.py` and copied into the positive training set before augmentation. Negative clips in `real_clips_negative/` are copied into the negative training set.

## Ambient Noise Negatives

Without ambient noise negatives, the model only sees speech during training. This causes it to output ~0.5 on silence and ambient sounds (fan noise, road noise, etc.) because it has never learned what "not speech" looks like.

The fix is to generate ambient noise clips and featurize them into a separate `.npy` file:

```bash
cd training/
python3 generate_ambient_negatives.py   # generates clips in real_clips_negative/
python3 build_ambient_features.py       # produces data/negative_features_ambient.npy
```

Key constraints:
- **Clip length must be exactly 2 seconds** (32000 samples at 16 kHz) to produce 16 embedding frames
- **Feature shape must be (N, 16, 96)** — wrong clip length produces wrong shape and breaks the model
- The ambient features are referenced in the training config as a separate `negative_ambient` class with its own batch slot, so the model reliably sees silence/noise examples every batch

Sources used (all MIT-compatible):
- Synthetic: fan noise, brown/pink/white noise, rain, road noise, 60 Hz hum, silence
- MS-SNSD (MIT): 25+ categories of real-world ambient recordings
- MUSAN (CC0/CC-BY-3.0): free sound + sound bible noise recordings

## Additional Compatibility Fixes

### `torchcodec` Required for Dataset Loading

The MIT RIR dataset loading requires `torchcodec` (not installed by default):
```bash
pip install torchcodec
```

### `scipy.special.sph_harm` Renamed

The `acoustics` library imports `sph_harm` which was renamed to `sph_harm_y` in scipy 1.17+ with a different argument order:
- Old: `sph_harm(m, n, phi, theta)`
- New: `sph_harm_y(n, m, theta, phi)`

Fix applied in the installed `acoustics/directivity.py`:
```python
from scipy.special import sph_harm_y
def sph_harm(m, n, phi, theta): return sph_harm_y(n, m, theta, phi)
```

### Piper `generate_samples()` Missing `model` Kwarg

openWakeWord's training code calls Piper's `generate_samples()` without a `model=` argument. The fix makes `model` optional with auto-detection of `.pt` files in the `models/` directory.

### Piper TTS Model Size

The Piper `en_US-libritts_r-medium.pt` model is ~195 MB, not the 600 MB the original `MIN_SIZES` check expected. The threshold was lowered to 150 MB.

## Threshold Tuning

Custom models generally need a lower detection threshold than pre-trained ones:
- Pre-trained (e.g., `hey_jarvis`): threshold 0.7 works well
- Custom trained with synthetic only: often needs 0.3–0.4
- Custom trained with real voice clips + ambient negatives: 0.5–0.8 works well

The assistant defaults to `WAKE_THRESHOLD=0.8`. Check `~/assistant.env` on the board — it can override the code default.

**Version compatibility**: The openWakeWord version on the board must match the trainer (v0.6.0+). Different versions normalize model output differently, causing score offsets (~0.5 baseline instead of ~0.0).

Tune based on your false positive vs. missed detection trade-off.
