# VibeStory 📖✨

AI-powered interactive story app for children — locally hosted, no cloud required.

---

## What it does

1. **Tell a story idea** — type, speak Hindi/Punjabi/English, or upload audio  
2. **AI generates** a Ghibli-style illustrated story with narration  
3. **Play it back** — slides with audio, like a picture book  
4. **Learn mode** — draw bounding boxes on story images to label objects (powers YOLO fine-tuning)  
5. **Dev Mode** — see every AI step live: Qwen prompts, image generation progress, model details  

---

## Architecture

```
Flutter app (Android/iOS)
        │  HTTP REST + polling
        ▼
FastAPI backend (app.py)  ←  runs on your PC
        │
        ├── Whisper (STT + translation)
        ├── Qwen 2.5-1.5B (story generation)
        ├── Ghibli-Diffusion (image gen)
        ├── Kokoro ONNX (TTS → WAV)
        ├── YOLOv8n (object detection)
        └── MongoDB (users + stories)
```

---

## Backend Setup

### Requirements

- Python 3.10+
- NVIDIA GPU with ≥ 4 GB VRAM recommended (works on CPU but slower)
- MongoDB running locally
- ~8 GB free disk space for models

### Install dependencies

```bash
pip install fastapi uvicorn[standard] motor pymongo \
    python-jose[cryptography] passlib[bcrypt] pydantic \
    openai-whisper torch torchvision \
    transformers accelerate diffusers \
    kokoro-onnx soundfile \
    ultralytics pillow python-multipart
```

### Kokoro TTS model files

Download and place in the same folder as `app.py`:
- `kokoro-v1.0.onnx` — https://github.com/thewh1teagle/kokoro-rs/releases
- `voices.bin`        — same release page

### Run

```bash
uvicorn app:app --host 0.0.0.0 --port 8000 --reload
```

> Use `--reload=False` in production to avoid re-downloading models on file changes.

---

## Flutter Setup

### Dependencies (`pubspec.yaml`)

```yaml
dependencies:
  flutter:
    sdk: flutter
  google_fonts: ^6.1.0
  http: ^1.2.0
  http_parser: ^4.0.2
  shared_preferences: ^2.2.2
  record: ^5.1.0
  audioplayers: ^6.0.0
  file_picker: ^8.0.0
  path_provider: ^2.1.2
  permission_handler: ^11.3.0
```

### Android permissions (`android/app/src/main/AndroidManifest.xml`)

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
```

### iOS permissions (`ios/Runner/Info.plist`)

```xml
<key>NSMicrophoneUsageDescription</key>
<string>VibeStory needs your mic to record story ideas.</string>
```

---

## 🔧 What to change per device

### 1. Server IP Address

Open `main.dart` and change:

```dart
const String kBaseUrl = 'http://192.168.31.201:8000';
```

To your backend machine's LAN IP. Find it with:

- **Windows**: `ipconfig` → look for "IPv4 Address" under your Wi-Fi adapter  
- **Linux/Mac**: `ip a` or `ifconfig` → look for `inet` under `wlan0` or `en0`  
- **USB debugging**: Use `http://localhost:8000` after running:
  ```bash
  adb reverse tcp:8000 tcp:8000
  ```

> Both the phone and PC must be on the **same Wi-Fi network** for LAN to work.

### 2. Whisper model size

In `app.py`:
```python
WHISPER_MODEL = os.getenv("WHISPER_MODEL", "small")
```

| Model  | Size    | Speed   | Accuracy |
|--------|---------|---------|----------|
| tiny   | ~75 MB  | fastest | lower    |
| base   | ~142 MB | fast    | ok       |
| small  | ~244 MB | medium  | good ✓   |
| medium | ~769 MB | slow    | better   |

For RTX 3050 (4 GB VRAM), `small` is recommended.

### 3. Image generation steps

Default is 5 steps (fast but lower quality). Change via:
- `IMAGE_STEPS` env variable
- Dev Mode → Settings in the app (live edit, no restart needed)

Higher steps (15–30) = better quality but slower.

### 4. MongoDB URL

```python
MONGO_URL = os.getenv("MONGO_URL", "mongodb://localhost:27017")
```

If MongoDB runs on a different host/port, set the env variable.

### 5. JWT Secret

```python
JWT_SECRET = os.getenv("JWT_SECRET", "vibestory_kids_secret_42")
```

Change to a long random string in production.

---

## YOLO Fine-Tuning Data

Every time a user submits bounding box labels in Learn mode, the data is saved to:

```
static/bbox_data/<story_id>_<image_index>.json
```

Format:
```json
{
  "story_id": "...",
  "image_index": 0,
  "image_url": "/static/stories/xxx/part_1.png",
  "labels": [
    {
      "label": "tree",
      "box": { "x": 120, "y": 80, "width": 200, "height": 300 }
    }
  ],
  "saved_at": "2025-..."
}
```

To convert to YOLO format for fine-tuning:

```python
import json, pathlib
for f in pathlib.Path("static/bbox_data").glob("*.json"):
    d = json.loads(f.read_text())
    img_w, img_h = 512, 512
    for lbl in d["labels"]:
        b = lbl["box"]
        cx = (b["x"] + b["width"] / 2) / img_w
        cy = (b["y"] + b["height"] / 2) / img_h
        w  = b["width"] / img_w
        h  = b["height"] / img_h
        print(f"class_id {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")
```

---

## Dev Mode

Enable in **Profile → Settings → Dev Mode**.

What you'll see while a story generates:
- Qwen system prompt and user prompt (truncated)
- Raw Qwen output and parsed story structure
- Per-image generation step counter
- TTS voice and text length
- GPU/CPU info and model names
- Full pipeline log with timestamps

You can also edit:
- **Image Steps** (slider, 1–50)
- **TTS Voice** (dropdown — 7 voices)

Changes apply to the next story generated without restarting the server.

---

## API Reference

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/auth/signup` | Register |
| POST | `/api/auth/login` | Login |
| GET  | `/api/auth/me` | Current user |
| POST | `/api/input/transcribe` | Audio → text (multipart) |
| POST | `/api/input/translate` | Text → English |
| POST | `/api/story/generate` | Start story pipeline |
| GET  | `/api/story/{id}/status` | Poll status + dev_log |
| GET  | `/api/story/{id}/dev-events` | SSE stream of dev events |
| GET  | `/api/story/{id}` | Full story document |
| GET  | `/api/profile` | User profile + stories |
| POST | `/api/learn/detect` | YOLOv8 detection |
| POST | `/api/learn/submit-labels` | Submit bbox labels |
| GET  | `/api/dev/config` | Get dev settings |
| POST | `/api/dev/config` | Update dev settings |
| GET  | `/api/health` | Server health check |

---

## Audio Notes

- Audio is saved as **WAV** (`.wav`) because Kokoro ONNX outputs raw PCM samples
- The `audioplayers` Flutter package streams WAV over HTTP natively
- If audio doesn't play, check:
  1. `static/audio/<story_id>.wav` exists on the server
  2. The URL in the app matches the server IP
  3. The file size is > 0 bytes (TTS may have failed silently)
  4. Check server logs for "TTS FAILED" entries

---

## Common Issues

| Issue | Fix |
|-------|-----|
| `Connection refused` | Wrong IP in `kBaseUrl`, or server not running |
| Images not loading | Check STATIC_DIR path; visit `http://IP:8000/static/...` in browser |
| CUDA out of memory | Lower IMAGE_STEPS, or use CPU (set `CUDA_VISIBLE_DEVICES=""`) |
| Qwen produces no JSON | Normal — fallback kicks in automatically |
| Audio silent but file exists | File might be corrupt; check server TTS logs |
| MongoDB connection error | Ensure `mongod` is running (`sudo systemctl start mongod`) |

---

## File Structure

```
project/
├── app.py              ← FastAPI backend
├── kokoro-v1.0.onnx    ← TTS model (download separately)
├── voices.bin          ← TTS voices (download separately)
├── hf_cache/           ← HuggingFace model cache (auto-created)
├── static/
│   ├── stories/        ← Generated images per story
│   ├── audio/          ← Generated WAV files
│   └── bbox_data/      ← User bbox labels for YOLO fine-tuning
└── flutter_app/
    └── lib/main.dart   ← Flutter app
```