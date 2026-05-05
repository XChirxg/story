"""
VibeStory Backend — app.py  v3.0
=================================
Models (all LOCAL):
  STT        : openai-whisper  "small"  ~244 MB
  LLM        : Qwen/Qwen2.5-1.5B-Instruct  ~3 GB RAM
  Images     : nitrosocke/Ghibli-Diffusion  (SD 1.5, fits 4 GB VRAM fp16)
  TTS        : kokoro-onnx  (CPU, ~310 MB)  → WAV output
  Detection  : YOLOv8n  (ultralytics, ~6 MB)

Install:
  pip install fastapi uvicorn[standard] motor pymongo python-jose[cryptography]
              passlib[bcrypt] pydantic openai-whisper torch torchvision
              transformers accelerate diffusers kokoro-onnx soundfile
              ultralytics pillow python-multipart

Run:
  uvicorn app:app --host 0.0.0.0 --port 8000 --reload
"""

import os, io, re, json, asyncio, tempfile, logging, threading
from pathlib import Path
from typing import List, Dict, Optional
from datetime import datetime, timedelta
from concurrent.futures import ThreadPoolExecutor

import jwt
from passlib.context import CryptContext
from bson import ObjectId
import motor.motor_asyncio
from fastapi import (FastAPI, HTTPException, Depends, UploadFile,
                     File, BackgroundTasks, Request)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s  %(levelname)-8s  %(message)s")
log = logging.getLogger("vibestory")

# ─── Config ──────────────────────────────────────────────────────────────────
MONGO_URL       = os.getenv("MONGO_URL",     "mongodb://localhost:27017")
DB_NAME         = os.getenv("DB_NAME",       "vibestory")
JWT_SECRET      = os.getenv("JWT_SECRET",    "vibestory_kids_secret_42")
JWT_ALGO        = "HS256"
JWT_EXPIRE_DAYS = 30
WHISPER_MODEL   = os.getenv("WHISPER_MODEL", "small")
QWEN_MODEL_ID   = "Qwen/Qwen2.5-1.5B-Instruct"
GHIBLI_MODEL_ID = "nitrosocke/Ghibli-Diffusion"
IMAGE_STEPS     = int(os.getenv("IMAGE_STEPS", "5"))
IMAGE_CFG       = float(os.getenv("IMAGE_CFG",  "7.0"))
KOKORO_VOICE    = os.getenv("KOKORO_VOICE",  "af_heart")

# HuggingFace cache
_HF_CACHE = str(Path(__file__).parent / "hf_cache")
os.environ.setdefault("HF_HOME",               _HF_CACHE)
os.environ.setdefault("TRANSFORMERS_CACHE",    _HF_CACHE)
os.environ.setdefault("HUGGINGFACE_HUB_CACHE", _HF_CACHE)
Path(_HF_CACHE).mkdir(parents=True, exist_ok=True)

STATIC_DIR  = Path("static")
STORIES_DIR = STATIC_DIR / "stories"
AUDIO_DIR   = STATIC_DIR / "audio"
BBOX_DIR    = STATIC_DIR / "bbox_data"
for _d in [STATIC_DIR, STORIES_DIR, AUDIO_DIR, BBOX_DIR]:
    _d.mkdir(parents=True, exist_ok=True)

executor = ThreadPoolExecutor(max_workers=2)

# ─── Lazy model holders ───────────────────────────────────────────────────────
_whisper_model  = None
_qwen_pipeline  = None
_diffusion_pipe = None
_yolo_model     = None
_kokoro         = None
_qwen_lock      = threading.Lock()

# ─── Dev-mode event queues ────────────────────────────────────────────────────
_dev_events: Dict[str, List[dict]] = {}
_dev_events_lock = threading.Lock()

def _push_event(story_id: str, event_type: str, data: dict):
    with _dev_events_lock:
        if story_id in _dev_events:
            _dev_events[story_id].append({"type": event_type, "data": data})

# ═════════════════════════════════════════════════════════════════════════════
#  MODEL LOADERS
# ═════════════════════════════════════════════════════════════════════════════

def _load_whisper():
    global _whisper_model
    if _whisper_model is None:
        import whisper
        log.info("Loading Whisper '%s' …", WHISPER_MODEL)
        _whisper_model = whisper.load_model(WHISPER_MODEL)
        log.info("Whisper loaded ✓")
    return _whisper_model

def _load_qwen():
    global _qwen_pipeline
    if _qwen_pipeline is not None:
        return _qwen_pipeline
    with _qwen_lock:
        if _qwen_pipeline is not None:
            return _qwen_pipeline
        from transformers import pipeline as hfp
        import torch
        device = "cuda" if torch.cuda.is_available() else "cpu"
        dtype  = torch.bfloat16 if device == "cuda" else torch.float32
        log.info("Loading Qwen2.5-1.5B on %s (dtype=%s) …", device, dtype)
        _qwen_pipeline = hfp(
            "text-generation",
            model=QWEN_MODEL_ID,
            torch_dtype=dtype,
            device_map="auto",
            trust_remote_code=True,
        )
        log.info("Qwen loaded ✓")
    return _qwen_pipeline

def _load_diffusion():
    global _diffusion_pipe
    if _diffusion_pipe is None:
        import torch
        from diffusers import StableDiffusionPipeline
        dtype = torch.float16 if torch.cuda.is_available() else torch.float32
        log.info("Loading Ghibli-Diffusion …")
        pipe = StableDiffusionPipeline.from_pretrained(
            GHIBLI_MODEL_ID, torch_dtype=dtype,
            safety_checker=None, requires_safety_checker=False)
        if torch.cuda.is_available():
            pipe = pipe.to("cuda")
            pipe.enable_attention_slicing()
        _diffusion_pipe = pipe
        log.info("Ghibli-Diffusion loaded ✓")
    return _diffusion_pipe

def _load_yolo():
    global _yolo_model
    if _yolo_model is None:
        from ultralytics import YOLO
        log.info("Loading YOLOv8n …")
        _yolo_model = YOLO("yolov8n.pt")
        log.info("YOLO loaded ✓")
    return _yolo_model

def _load_kokoro():
    global _kokoro
    if _kokoro is None:
        try:
            from kokoro_onnx import Kokoro
            log.info("Loading Kokoro TTS …")
            _kokoro = Kokoro("kokoro-v1.0.onnx", "voices.bin")
            log.info("Kokoro TTS loaded ✓")
        except Exception as e:
            log.warning("Kokoro unavailable (%s) — pyttsx3 fallback", e)
    return _kokoro


# ═════════════════════════════════════════════════════════════════════════════
#  SYNC INFERENCE
# ═════════════════════════════════════════════════════════════════════════════

def _sync_transcribe(audio_path: str) -> Dict:
    model       = _load_whisper()
    result_orig = model.transcribe(audio_path, task="transcribe")
    lang        = result_orig.get("language", "en")
    original    = result_orig["text"].strip()
    english     = original
    if lang != "en":
        result_en = model.transcribe(audio_path, task="translate")
        english   = result_en["text"].strip()
    return {"original": original, "english": english, "language": lang}


def _sync_translate_text(text: str) -> str:
    messages = [
        {"role": "system", "content":
            "You are a translator. Translate the user's text to English. "
            "Output ONLY the English translation, nothing else."},
        {"role": "user", "content": text},
    ]
    return _sync_qwen(messages, max_new_tokens=256).strip()


def _sync_qwen(messages: list, max_new_tokens: int = 1800) -> str:
    pipe = _load_qwen()
    out  = pipe(
        messages,
        max_new_tokens=max_new_tokens,
        do_sample=True,
        temperature=0.7,
        top_p=0.9,
        repetition_penalty=1.1,
    )
    generated = out[0]["generated_text"]
    if isinstance(generated, list):
        return generated[-1]["content"].strip()
    return str(generated).strip()


def _sync_gen_image(prompt: str, save_path: Path,
                    story_id: str = "", part_idx: int = 0,
                    steps: int = None, cfg: float = None):
    pipe    = _load_diffusion()
    _steps  = steps if steps is not None else IMAGE_STEPS
    _cfg    = cfg   if cfg   is not None else IMAGE_CFG
    neg     = ("ugly, blurry, dark, scary, violent, adult content, "
               "realistic photo, 3d render, bad anatomy, deformed, "
               "duplicate characters, inconsistent character, wrong colors, "
               "extra limbs, missing limbs, watermark, text, logo")
    # Do NOT prepend anything — use the prompt exactly as Qwen built it
    step_count = [0]
    def _cb(step, ts, latents):
        step_count[0] = step
        _push_event(story_id, "image_step",
                    {"part": part_idx, "step": step, "total": _steps})

    img = pipe(
        prompt,
        negative_prompt=neg,
        num_inference_steps=_steps,
        guidance_scale=_cfg,
        width=512, height=512,
        callback=_cb, callback_steps=1,
    ).images[0]
    img.save(save_path)


def _sync_tts(text: str, save_path: Path, voice: str = None):
    kok   = _load_kokoro()
    _voice = voice or KOKORO_VOICE
    if kok:
        import soundfile as sf
        samples, sr = kok.create(text, voice=_voice, speed=0.85, lang="en-us")
        sf.write(str(save_path), samples, sr)
    else:
        import pyttsx3
        engine = pyttsx3.init()
        engine.setProperty("rate", 140)
        engine.save_to_file(text, str(save_path))
        engine.runAndWait()


def _sync_yolo(img_path: str) -> List[Dict]:
    yolo    = _load_yolo()
    results = yolo(img_path)
    out     = []
    for r in results:
        for box in r.boxes:
            x1, y1, x2, y2 = [int(v) for v in box.xyxy[0].tolist()]
            out.append({
                "label":      yolo.names[int(box.cls[0])],
                "confidence": round(float(box.conf[0]), 3),
                "box": {"x": x1, "y": y1,
                        "width": x2 - x1, "height": y2 - y1}
            })
    return out


# ═════════════════════════════════════════════════════════════════════════════
#  ASYNC WRAPPERS
# ═════════════════════════════════════════════════════════════════════════════

async def do_transcribe(audio_bytes: bytes, suffix: str = ".webm") -> Dict:
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(audio_bytes); tmp_path = tmp.name
    try:
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(executor, _sync_transcribe, tmp_path)
    finally:
        os.unlink(tmp_path)

async def do_translate(text: str) -> str:
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(executor, _sync_translate_text, text)

async def do_qwen(messages: list, max_tokens: int = 1800) -> str:
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(
        executor, lambda: _sync_qwen(messages, max_tokens))

async def do_gen_image(prompt: str, save_path: Path,
                       story_id: str = "", part_idx: int = 0,
                       steps: int = None, cfg: float = None):
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(
        executor,
        lambda: _sync_gen_image(prompt, save_path, story_id, part_idx, steps, cfg))

async def do_tts(text: str, save_path: Path, voice: str = None):
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(
        executor, lambda: _sync_tts(text, save_path, voice))

async def do_yolo(img_bytes: bytes) -> List[Dict]:
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
        tmp.write(img_bytes); tmp_path = tmp.name
    try:
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(executor, _sync_yolo, tmp_path)
    finally:
        os.unlink(tmp_path)


# ─── Helpers ──────────────────────────────────────────────────────────────────

def parse_json_block(text: str) -> dict:
    m   = re.search(r"```json\s*(.*?)\s*```", text, re.DOTALL)
    raw = m.group(1) if m else text
    s   = raw.find("{"); e = raw.rfind("}") + 1
    return json.loads(raw[s:e])

def make_placeholder(path: Path, index: int):
    try:
        from PIL import Image, ImageDraw
        colors = ["#FFD6E0","#FFEFBA","#C1E1C1","#BDE0FE","#E8D5FF"]
        img = Image.new("RGB", (512, 512), colors[(index-1) % 5])
        ImageDraw.Draw(img).text((200, 245), f"Part {index}", fill="#555")
        img.save(path)
    except Exception:
        pass

def save_bbox_data(story_id: str, image_index: int,
                   image_url: str, labels: List[Dict]):
    record = {
        "story_id":    story_id,
        "image_index": image_index,
        "image_url":   image_url,
        "labels":      labels,
        "saved_at":    datetime.utcnow().isoformat(),
    }
    out_path = BBOX_DIR / f"{story_id}_{image_index}.json"
    with open(out_path, "w") as f:
        json.dump(record, f, indent=2)
    log.info("BBox data saved → %s", out_path)


# ═════════════════════════════════════════════════════════════════════════════
#  AUTH HELPERS
# ═════════════════════════════════════════════════════════════════════════════
pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto", bcrypt__rounds=12)
hash_pw   = lambda pw: pwd_ctx.hash(pw)
verify_pw = lambda pw, h: pwd_ctx.verify(pw, h)

def create_token(uid: str) -> str:
    exp = datetime.utcnow() + timedelta(days=JWT_EXPIRE_DAYS)
    return jwt.encode({"sub": uid, "exp": exp}, JWT_SECRET, algorithm=JWT_ALGO)

def decode_token(token: str) -> str:
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGO])["sub"]
    except Exception:
        raise HTTPException(401, "Invalid or expired token")


# ═════════════════════════════════════════════════════════════════════════════
#  FASTAPI APP + DB
# ═════════════════════════════════════════════════════════════════════════════
app = FastAPI(title="VibeStory API", version="3.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"],
                   allow_credentials=True, allow_methods=["*"], allow_headers=["*"])
app.mount("/static", StaticFiles(directory="static"), name="static")

_mongo      = motor.motor_asyncio.AsyncIOMotorClient(MONGO_URL)
db          = _mongo[DB_NAME]
users_col   = db["users"]
stories_col = db["stories"]

# ─── Schemas ──────────────────────────────────────────────────────────────────
class SignupReq(BaseModel):
    name: str; email: str; password: str

class LoginReq(BaseModel):
    email: str; password: str

class TextReq(BaseModel):
    text: str

class LabelSubmitReq(BaseModel):
    story_id: str
    image_index: int
    image_url: str = ""
    labels: List[Dict]

class DevSettingsReq(BaseModel):
    image_steps: Optional[int] = None
    kokoro_voice: Optional[str] = None

# ─── Auth dependency ──────────────────────────────────────────────────────────
async def current_user(request: Request):
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Missing token")
    uid  = decode_token(auth[7:])
    user = await users_col.find_one({"_id": ObjectId(uid)})
    if not user:
        raise HTTPException(401, "User not found")
    return user


# ═════════════════════════════════════════════════════════════════════════════
#  AUTH ROUTES
# ═════════════════════════════════════════════════════════════════════════════

@app.post("/api/auth/signup")
async def signup(req: SignupReq):
    if await users_col.find_one({"email": req.email.lower()}):
        raise HTTPException(400, "Email already registered")
    doc = {
        "name": req.name.strip(), "email": req.email.lower().strip(),
        "password": hash_pw(req.password),
        "score": 0, "total_objects": 0, "created_at": datetime.utcnow(),
    }
    res   = await users_col.insert_one(doc)
    token = create_token(str(res.inserted_id))
    return {"token": token, "name": req.name, "user_id": str(res.inserted_id)}


@app.post("/api/auth/login")
async def login(req: LoginReq):
    user = await users_col.find_one({"email": req.email.lower()})
    if not user or not verify_pw(req.password, user["password"]):
        raise HTTPException(401, "Wrong email or password")
    token = create_token(str(user["_id"]))
    return {"token": token, "name": user["name"], "user_id": str(user["_id"])}


@app.get("/api/auth/me")
async def me(user=Depends(current_user)):
    return {"user_id": str(user["_id"]), "name": user["name"],
            "email": user["email"], "score": user.get("score", 0),
            "total_objects": user.get("total_objects", 0)}


# ═════════════════════════════════════════════════════════════════════════════
#  INPUT ROUTES
# ═════════════════════════════════════════════════════════════════════════════

@app.post("/api/input/transcribe")
async def route_transcribe(audio: UploadFile = File(...),
                           user=Depends(current_user)):
    raw    = await audio.read()
    suffix = Path(audio.filename or "audio.webm").suffix or ".webm"
    return await do_transcribe(raw, suffix)


@app.post("/api/input/translate")
async def route_translate(req: TextReq, user=Depends(current_user)):
    english = await do_translate(req.text)
    return {"original": req.text, "english": english}


# ═════════════════════════════════════════════════════════════════════════════
#  STORY GENERATION
# ═════════════════════════════════════════════════════════════════════════════

@app.post("/api/story/generate")
async def start_gen(req: TextReq, bg: BackgroundTasks,
                    user=Depends(current_user)):
    sid       = str(ObjectId())
    story_dir = STORIES_DIR / sid
    story_dir.mkdir(parents=True)

    await stories_col.insert_one({
        "_id":           ObjectId(sid),
        "user_id":       str(user["_id"]),
        "original_text": req.text,
        "status":        "queued",
        "step":          "Warming up… 🔥",
        "dev_log":       [],
        "refined_story": "",
        "protagonist":   "",
        "parts":         [],
        "images":        [],
        "audio_url":     "",
        "created_at":    datetime.utcnow(),
    })
    bg.add_task(_pipeline, sid, req.text, story_dir, str(user["_id"]))
    return {"story_id": sid}


async def _set(sid: str, **kw):
    await stories_col.update_one({"_id": ObjectId(sid)}, {"$set": kw})

async def _log(sid: str, msg: str, data: dict = None):
    entry = {"ts": datetime.utcnow().isoformat(), "msg": msg}
    if data:
        entry["data"] = data
    await stories_col.update_one(
        {"_id": ObjectId(sid)},
        {"$push": {"dev_log": entry}})
    _push_event(sid, "log", entry)


async def _pipeline(sid: str, text: str, story_dir: Path, user_id: str):
    import torch
    gpu_name = (torch.cuda.get_device_name(0)
                if torch.cuda.is_available() else "CPU only")

    try:
        await _log(sid, "Pipeline started",
                   {"gpu": gpu_name,
                    "whisper_model": WHISPER_MODEL,
                    "qwen_model": QWEN_MODEL_ID,
                    "image_model": GHIBLI_MODEL_ID,
                    "image_steps": IMAGE_STEPS,
                    "tts_voice": KOKORO_VOICE})

        # ── STEP 1  Qwen story + prompts ──────────────────────────────────
        await _set(sid, status="running", step="Crafting your story ✨")

        sys_msg = (
            "You are VibeBot, a creative AI storyteller and professional Stable Diffusion "
            "prompt engineer for children aged 4-10. "
            "Always output valid JSON only. No extra text, no markdown, no backticks. "
            "Use simple, fun, age-appropriate language for the story. "
            "For image prompts, use advanced Stable Diffusion prompt engineering techniques."
        )

        user_msg = f"""You are given a story idea. Follow ALL steps carefully in order.

STORY IDEA: {text}

=== STEP 1: INTERPRET THE STORY ===
Read the story idea and understand:
- Who is the main character (protagonist)? What species/type are they?
- What is their personality? (brave, shy, curious, playful?)
- What is the setting? (forest, village, space, underwater?)
- What is the emotional tone? (joyful, adventurous, magical, cozy?)

=== STEP 2: DESIGN THE PROTAGONIST APPEARANCE ===
Based on your interpretation, design a VERY DETAILED visual appearance for the protagonist.
Include ALL of the following:
- Body type and size (small child, tall teen, tiny fairy, big fluffy bear?)
- Face features (big round eyes, small button nose, freckles, rosy cheeks?)
- Hair (color, length, style — e.g. short messy black hair, long braided golden hair)
- Clothing (color, style, any accessories — e.g. red striped scarf, blue overalls, green boots)
- Any unique features (glowing wings, striped tail, star-shaped birthmark, always carries a lantern)
- Art style notes (soft rounded shapes, expressive eyes, chibi proportions)
This description will be reused across ALL images so the character looks IDENTICAL in every scene.

=== STEP 3: WRITE THE STORY ===
Rewrite the idea as a fun child-friendly story of exactly 6-8 sentences.
Use simple words. Make it warm, magical and age-appropriate.
Split it into exactly 5 parts (1-2 sentences each).

=== STEP 4: WRITE IMAGE PROMPTS ===
For EACH of the 5 story parts, write a Stable Diffusion image prompt.
You are a professional prompt engineer. Follow these rules:

RULE 1 — DECIDE WHAT TO SHOW:
Look at what the story part is actually about:
- If it describes a PLACE or ENVIRONMENT (forest, market, storm, sunrise) → show the environment, protagonist optional or small in distance
- If it describes an OBJECT or ITEM (magic seed, glowing stone, old map) → make that object the focus, close-up, detailed
- If it describes an ACTION or EMOTION (running, crying, laughing, hugging) → show protagonist doing that action, expressive
- If it describes a MEETING (two characters, crowd, animal) → show the interaction between them
- NEVER just paste the protagonist description into every single prompt

RULE 2 — USE PROPER PROMPT STRUCTURE:
Every prompt must have ALL of these elements in order:
1. Art style: "studio ghibli anime style, hand-drawn, soft cel shading"
2. Shot type: choose ONE → "extreme close-up" / "close-up portrait" / "medium shot" / "wide shot" / "establishing shot" / "bird's eye view" / "low angle shot"
3. Subject: what is actually shown (use protagonist description ONLY if protagonist is in scene)
4. Action/pose: what are they doing
5. Environment: background setting with specific details
6. Lighting: choose → "golden hour sunlight" / "soft morning mist" / "warm candlelight" / "cool moonlight" / "dappled forest light" / "dramatic storm light" / "bright cheerful daylight"
7. Mood/atmosphere: "whimsical and magical" / "cozy and warm" / "tense and mysterious" / "joyful and bright" / "peaceful and serene"
8. Color palette: specific colors → "warm amber and soft greens" / "cool blues and silver" / "pastel pinks and yellows"
9. Quality tags: "highly detailed, beautiful illustration, children's book art, masterpiece"

RULE 3 — PROTAGONIST CONSISTENCY:
When the protagonist appears, ALWAYS use their EXACT appearance description from Step 2.
Never change their hair, clothes, or features between prompts.

RULE 4 — NO GENERIC FILLERS:
Never use vague words like "beautiful scene" or "nice background".
Every detail must be specific and visual.

=== OUTPUT FORMAT ===
Respond ONLY with this exact JSON structure. No other text:
{{
  "story_interpretation": {{
    "setting": "brief description of world/setting",
    "tone": "emotional tone of story",
    "protagonist_type": "what kind of character"
  }},
  "protagonist": "FULL detailed appearance description — hair, face, clothing, body, unique features, art style notes. This exact text will be injected into every prompt where protagonist appears.",
  "refined_story": "Full 6-8 sentence story as one paragraph.",
  "parts": [
    {{
      "text": "Part 1 story sentences.",
      "scene_type": "environment",
      "show_protagonist": false,
      "prompt": "studio ghibli anime style, hand-drawn, soft cel shading, establishing shot, [DETAILED ENVIRONMENT DESCRIPTION], soft morning mist, peaceful and serene, warm amber and soft greens, highly detailed, beautiful illustration, children's book art, masterpiece"
    }},
    {{
      "text": "Part 2 story sentences.",
      "scene_type": "action",
      "show_protagonist": true,
      "prompt": "studio ghibli anime style, hand-drawn, soft cel shading, medium shot, [FULL PROTAGONIST APPEARANCE] doing [ACTION], [ENVIRONMENT], golden hour sunlight, joyful and bright, pastel pinks and yellows, highly detailed, beautiful illustration, children's book art, masterpiece"
    }},
    {{
      "text": "Part 3 story sentences.",
      "scene_type": "object",
      "show_protagonist": false,
      "prompt": "studio ghibli anime style, hand-drawn, soft cel shading, extreme close-up, [MAGICAL OBJECT] with intricate details, [ENVIRONMENT HINT], warm candlelight, whimsical and magical, warm amber and gold, highly detailed, beautiful illustration, children's book art, masterpiece"
    }},
    {{
      "text": "Part 4 story sentences.",
      "scene_type": "meeting",
      "show_protagonist": true,
      "prompt": "studio ghibli anime style, hand-drawn, soft cel shading, wide shot, [FULL PROTAGONIST APPEARANCE] meeting [OTHER CHARACTER/CREATURE], [DETAILED ENVIRONMENT], dappled forest light, whimsical and magical, cool blues and soft greens, highly detailed, beautiful illustration, children's book art, masterpiece"
    }},
    {{
      "text": "Part 5 story sentences.",
      "scene_type": "action",
      "show_protagonist": true,
      "prompt": "studio ghibli anime style, hand-drawn, soft cel shading, close-up portrait, [FULL PROTAGONIST APPEARANCE] with expression of [EMOTION], [ENVIRONMENT], golden hour sunlight, warm and joyful, pastel warm tones, highly detailed, beautiful illustration, children's book art, masterpiece"
    }}
  ]
}}"""

        messages = [{"role": "system", "content": sys_msg},
                    {"role": "user",   "content": user_msg}]

        await _log(sid, "Qwen prompt sent",
                   {"system": sys_msg[:200], "user_prompt_len": len(user_msg)})

        # Give Qwen more tokens since the prompt and output are now larger
        raw = await do_qwen(messages, 2400)
        await _log(sid, "Qwen raw output", {"raw": raw[:800]})

        try:
            data  = parse_json_block(raw)
            parts = data.get("parts", [])[:5]
            assert len(parts) >= 1
        except Exception as parse_err:
            log.warning("Qwen JSON parse failed (%s), building fallback", parse_err)
            await _log(sid, "Qwen parse failed — using fallback",
                       {"error": str(parse_err)})
            sents = [s.strip() for s in text.split(".") if s.strip()][:5]
            while len(sents) < 5:
                sents.append(sents[-1] if sents else "The adventure continues.")
            data  = {
                "story_interpretation": {
                    "setting": "a magical world",
                    "tone": "whimsical and adventurous",
                    "protagonist_type": "a curious child"
                },
                "refined_story": text,
                "protagonist": (
                    "a small curious child with short messy brown hair, "
                    "big round hazel eyes, rosy cheeks, wearing a bright yellow raincoat "
                    "with blue buttons, brown boots, carrying a small red backpack, "
                    "soft rounded chibi proportions, expressive face, studio ghibli style"
                ),
                "parts": [
                    {
                        "text": s,
                        "scene_type": "action",
                        "show_protagonist": True,
                        "prompt": (
                            f"studio ghibli anime style, hand-drawn, soft cel shading, "
                            f"medium shot, small curious child with short messy brown hair "
                            f"big round hazel eyes rosy cheeks yellow raincoat blue buttons "
                            f"brown boots red backpack, {s}, lush green meadow with wildflowers "
                            f"and distant rolling hills, golden hour sunlight, joyful and bright, "
                            f"warm amber and soft greens, highly detailed, beautiful illustration, "
                            f"children's book art, masterpiece"
                        )
                    }
                    for s in sents[:5]
                ]
            }
            parts = data["parts"]

        # Log full interpretation and protagonist for dev mode
        await _log(sid, "Story structured", {
            "interpretation": data.get("story_interpretation", {}),
            "protagonist":    data.get("protagonist", "")[:300],
            "refined_story":  data.get("refined_story", "")[:300],
            "num_parts":      len(parts),
            "parts": [
                {
                    "text":             p["text"][:80],
                    "scene_type":       p.get("scene_type", "unknown"),
                    "show_protagonist": p.get("show_protagonist", True),
                    "prompt":           p.get("prompt", "")[:150],
                }
                for p in parts
            ]
        })

        await _set(sid,
                   refined_story        = data.get("refined_story", text),
                   protagonist          = data.get("protagonist", ""),
                   story_interpretation = data.get("story_interpretation", {}),
                   parts                = parts,
                   step                 = "Drawing pictures 🎨")

        # ── STEP 2  Images ────────────────────────────────────────────────
        image_urls = []
        for i, part in enumerate(parts):
            await _set(sid, step=f"Drawing picture {i+1} of {len(parts)} 🖼️")

            # Use the fully built prompt from Qwen directly
            prompt = part.get("prompt", "")

            # Safety fallback if prompt is somehow empty
            if not prompt.strip():
                protagonist = data.get("protagonist", "a curious child")
                prompt = (
                    f"studio ghibli anime style, hand-drawn, soft cel shading, "
                    f"medium shot, {protagonist}, standing in a magical landscape, "
                    f"golden hour sunlight, whimsical and magical, warm pastel colors, "
                    f"highly detailed, beautiful illustration, children's book art, masterpiece"
                )

            img_path = story_dir / f"part_{i+1}.png"
            await _log(sid, f"Generating image {i+1}", {
                "scene_type":       part.get("scene_type", "unknown"),
                "show_protagonist": part.get("show_protagonist", True),
                "prompt":           prompt,
                "steps":            IMAGE_STEPS,
            })

            try:
                with _dev_events_lock:
                    if sid not in _dev_events:
                        _dev_events[sid] = []
                await do_gen_image(prompt, img_path, story_id=sid, part_idx=i+1)
                await _log(sid, f"Image {i+1} done", {"path": str(img_path)})
            except Exception as img_err:
                log.error("Image %d failed: %s", i+1, img_err)
                await _log(sid, f"Image {i+1} FAILED", {"error": str(img_err)})
                make_placeholder(img_path, i+1)

            url = f"/static/stories/{sid}/part_{i+1}.png"
            image_urls.append(url)
            await _set(sid, images=image_urls, status=f"image_{i+1}_ready")

        # ── STEP 3  TTS ───────────────────────────────────────────────────
        await _set(sid, status="running", step="Recording the narration 🎙️")
        audio_path = AUDIO_DIR / f"{sid}.wav"
        await _log(sid, "TTS starting",
                   {"voice": KOKORO_VOICE,
                    "text_len": len(data.get("refined_story", text))})
        try:
            await do_tts(data.get("refined_story", text), audio_path)
            audio_url = f"/static/audio/{sid}.wav"
            await _log(sid, "TTS done", {"url": audio_url})
        except Exception as tts_err:
            log.error("TTS failed: %s", tts_err)
            await _log(sid, "TTS FAILED", {"error": str(tts_err)})
            audio_url = ""

        # ── DONE ─────────────────────────────────────────────────────────
        await _set(sid,
                   status    = "done",
                   step      = "Your story is ready! 🎉",
                   images    = image_urls,
                   audio_url = audio_url)
        await _log(sid, "Pipeline complete ✓",
                   {"total_images": len(image_urls), "audio": audio_url})
        log.info("Story %s complete.", sid)

    except Exception as fatal:
        log.exception("Pipeline crashed for story %s", sid)
        await _set(sid, status="error", step=str(fatal))
        await _log(sid, "Pipeline CRASHED", {"error": str(fatal)})
    finally:
        async def _cleanup():
            await asyncio.sleep(300)
            with _dev_events_lock:
                _dev_events.pop(sid, None)
        asyncio.ensure_future(_cleanup())


@app.get("/api/story/{story_id}/status")
async def story_status(story_id: str, user=Depends(current_user)):
    doc = await stories_col.find_one({"_id": ObjectId(story_id)})
    if not doc:
        raise HTTPException(404, "Story not found")
    doc["_id"] = str(doc["_id"])
    doc.pop("user_id", None)
    return doc


@app.get("/api/story/{story_id}/dev-events")
async def story_dev_events(story_id: str, user=Depends(current_user)):
    with _dev_events_lock:
        _dev_events.setdefault(story_id, [])

    async def _stream():
        seen = 0
        for _ in range(600):
            await asyncio.sleep(1)
            with _dev_events_lock:
                events = _dev_events.get(story_id, [])
            for ev in events[seen:]:
                yield f"data: {json.dumps(ev)}\n\n"
                seen += 1
            doc = await stories_col.find_one(
                {"_id": ObjectId(story_id)}, {"status": 1})
            if doc and doc.get("status") in ("done", "error"):
                yield "data: {\"type\":\"done\"}\n\n"
                break

    return StreamingResponse(_stream(), media_type="text/event-stream")


@app.get("/api/story/{story_id}")
async def get_story(story_id: str, user=Depends(current_user)):
    doc = await stories_col.find_one({"_id": ObjectId(story_id)})
    if not doc:
        raise HTTPException(404, "Story not found")
    doc["_id"] = str(doc["_id"])
    return doc


# ═════════════════════════════════════════════════════════════════════════════
#  DEV SETTINGS
# ═════════════════════════════════════════════════════════════════════════════

@app.get("/api/dev/config")
async def get_dev_config(user=Depends(current_user)):
    import torch
    return {
        "whisper_model":  WHISPER_MODEL,
        "qwen_model":     QWEN_MODEL_ID,
        "image_model":    GHIBLI_MODEL_ID,
        "image_steps":    IMAGE_STEPS,
        "image_cfg":      IMAGE_CFG,
        "kokoro_voice":   KOKORO_VOICE,
        "cuda_available": torch.cuda.is_available(),
        "device_name":    (torch.cuda.get_device_name(0)
                           if torch.cuda.is_available() else "CPU"),
        "tts_voices": ["af_heart","af_bella","af_sarah","am_adam",
                       "am_michael","bf_emma","bm_george"],
    }

@app.post("/api/dev/config")
async def set_dev_config(req: DevSettingsReq, user=Depends(current_user)):
    global IMAGE_STEPS, KOKORO_VOICE
    if req.image_steps is not None:
        IMAGE_STEPS = max(1, min(50, req.image_steps))
    if req.kokoro_voice is not None:
        KOKORO_VOICE = req.kokoro_voice
    return {"image_steps": IMAGE_STEPS, "kokoro_voice": KOKORO_VOICE}


# ═════════════════════════════════════════════════════════════════════════════
#  PROFILE
# ═════════════════════════════════════════════════════════════════════════════

@app.get("/api/profile")
async def profile(user=Depends(current_user)):
    cursor = stories_col.find(
        {"user_id": str(user["_id"]), "status": "done"},
        {"_id": 1, "refined_story": 1, "images": 1,
         "created_at": 1, "audio_url": 1}
    ).sort("created_at", -1)
    stories = []
    async for s in cursor:
        s["_id"] = str(s["_id"])
        stories.append(s)
    return {
        "name": user["name"],
        "score": user.get("score", 0),
        "total_objects": user.get("total_objects", 0),
        "stories": stories,
    }


# ═════════════════════════════════════════════════════════════════════════════
#  LEARN (YOLO + user labels)
# ═════════════════════════════════════════════════════════════════════════════

@app.post("/api/learn/detect")
async def detect(image: UploadFile = File(...), user=Depends(current_user)):
    raw  = await image.read()
    dets = await do_yolo(raw)
    return {"detections": dets}


@app.post("/api/learn/submit-labels")
async def submit_labels(req: LabelSubmitReq, user=Depends(current_user)):
    n      = len(req.labels)
    points = n * 10
    await users_col.update_one(
        {"_id": user["_id"]},
        {"$inc": {"score": points, "total_objects": n}})
    await stories_col.update_one(
        {"_id": ObjectId(req.story_id)},
        {"$push": {f"user_labels.image_{req.image_index}": {"$each": req.labels}}})

    save_bbox_data(req.story_id, req.image_index, req.image_url, req.labels)

    updated = await users_col.find_one({"_id": user["_id"]})
    return {
        "points_awarded": points,
        "new_score":      updated.get("score", 0),
        "total_objects":  updated.get("total_objects", 0),
    }


# ═════════════════════════════════════════════════════════════════════════════
#  HEALTH
# ═════════════════════════════════════════════════════════════════════════════

@app.get("/api/health")
async def health():
    import torch
    return {
        "status": "ok",
        "cuda":   torch.cuda.is_available(),
        "device": (torch.cuda.get_device_name(0)
                   if torch.cuda.is_available() else "CPU"),
        "version": "3.0.0",
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="0.0.0.0", port=8000, reload=False)