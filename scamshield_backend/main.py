"""
=============================================================
  Spam Shield — FastAPI Backend
=============================================================
  INSTALL:
      pip install fastapi uvicorn transformers torch

  RUN:
      uvicorn main:app --reload --port 8000

  API:
      POST http://localhost:8000/detect
      Body: { "text": "Your message here" }
=============================================================
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel
import re
import os

# ── App Setup ─────────────────────────────────────────────
app = FastAPI(title="Spam Shield API", version="1.0.0")

# Allow browser requests from the HTML file
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Load AI Model (once at startup) ───────────────────────
print("\n🤖 Loading spam detection model...")
from transformers import pipeline as hf_pipeline

classifier = hf_pipeline(
    "text-classification",
    model="mrm8488/bert-tiny-finetuned-sms-spam-detection",
)
print("✅ Model ready!\n")

# ── Scam Keywords ─────────────────────────────────────────
SCAM_KEYWORDS = {
    "won": 0.30, "winner": 0.30, "prize": 0.30, "lottery": 0.40,
    "claim": 0.25, "urgent": 0.30, "verify": 0.30, "bank": 0.20,
    "account blocked": 0.40, "free": 0.20, "click": 0.20,
    "limited offer": 0.25, "act now": 0.25, "reward": 0.25,
    "gift card": 0.30, "otp": 0.35, "upi": 0.35, "kyc": 0.35,
    "update account": 0.35, "confirm details": 0.35,
    "click here": 0.50, "card": 0.30,
}

# ── Risk Helpers ──────────────────────────────────────────
def keyword_score(text: str) -> tuple[float, list[str]]:
    t = text.lower()
    matched = [kw for kw in SCAM_KEYWORDS if kw in t]
    score = sum(SCAM_KEYWORDS[kw] for kw in matched)
    return min(score, 1.0), matched

def url_score(text: str) -> float:
    return 0.5 if re.search(r"https?://\S+|www\.\S+", text) else 0.0

def phone_score(text: str) -> float:
    return 0.4 if re.search(r"\b[6-9]\d{9}\b", text) else 0.0

def urgency_score(text: str) -> float:
    words = ["immediately", "urgent", "act now", "verify now", "limited time"]
    return 0.3 if any(w in text.lower() for w in words) else 0.0

# ── Request / Response Models ─────────────────────────────
class DetectRequest(BaseModel):
    text: str

class DetectResponse(BaseModel):
    risk: str
    risk_label: str
    final_score: float
    ai_score: float
    pattern_score: float
    keyword_score: float
    url_score: float
    phone_score: float
    urgency_score: float
    matched_keywords: list[str]
    message_length: int

# ── Main Endpoint ─────────────────────────────────────────
@app.post("/detect", response_model=DetectResponse)
def detect_spam(req: DetectRequest):
    text = req.text.strip()

    # AI prediction
    ai_result = classifier(text, truncation=True, max_length=512)[0]
    raw = ai_result["score"]
    ai = raw if ai_result["label"] == "LABEL_1" else 1 - raw

    # Pattern scores
    kw, matched = keyword_score(text)
    url  = url_score(text)
    phone = phone_score(text)
    urgency = urgency_score(text)
    pattern = min(kw + url + phone + urgency, 1.0)

    # Final weighted score
    final = round((0.65 * ai) + (0.35 * pattern), 4)

    if   final > 0.75: risk, label = "HIGH",   "SPAM DETECTED"
    elif final > 0.45: risk, label = "MEDIUM",  "SUSPICIOUS"
    else:              risk, label = "LOW",     "SAFE"

    return DetectResponse(
        risk=risk,
        risk_label=label,
        final_score=final,
        ai_score=round(ai, 4),
        pattern_score=round(pattern, 4),
        keyword_score=round(kw, 4),
        url_score=url,
        phone_score=phone,
        urgency_score=urgency,
        matched_keywords=matched,
        message_length=len(text),
    )

# ── Health Check ──────────────────────────────────────────
@app.get("/health")
def health():
    return {"status": "ok", "model": "mrm8488/bert-tiny-finetuned-sms-spam-detection"}

# ── Serve Frontend ────────────────────────────────────────
@app.get("/")
def serve_frontend():
    return FileResponse("index.html")
