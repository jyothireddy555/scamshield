# from fastapi import FastAPI
# from pydantic import BaseModel
# import requests
# import json
# import re
#
# app = FastAPI()
#
# GROQ_API_KEY = "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"
#
# class Message(BaseModel):
#     message: str
#
# @app.post("/analyze")
# def analyze(data: Message):
#     text = data.message
#
#     prompt = f"""You are an AI-Based Fraud Risk Detection system designed to protect rural Indian citizens from digital scams.
#
# Analyze the following message and detect scam risk with high accuracy.
#
# Message: "{text}"
#
# Scoring Rules (apply strictly):
# - Messages asking for OTP, password, or bank details → score 80-100
# - Messages asking to click links to verify account → score 70-95
# - Messages claiming lottery, prize, or winner → score 80-100
# - Messages offering job with high salary or work-from-home requiring payment → score 60-90
# - Messages requesting UPI payment or money transfer → score 70-95
# - Messages with urgent or threatening language about account suspension → score 65-90
# - Messages with suspicious shortened URLs (bit.ly, tinyurl, etc.) → add 15-20 to score
# - Normal informational or personal messages → score 0-20
# - Sometimes massages are might from the isp so dont show them high rish and u analyze that weather from any company message or not and act accordingly
#
# Risk Classification:
# 0-30 → Safe
# 31-60 → Suspicious
# 61-100 → High Risk
#
# Return ONLY a valid JSON object with no extra text, no markdown, no explanation outside the JSON:
# {{
#   "scam_probability": <0-100>,
#   "risk_level": "<Safe|Suspicious|High Risk>",
#   "fraud_type": "<UPI Fraud|Job Scam|Lottery Scam|Phishing|KYC Scam|Safe Message|Others>",
#   "suspicious_keywords": ["keyword1", "keyword2"],
#   "explanation": "<2-3 sentences explaining why this is or is not a scam>",
#   "prevention_tips": [
#     "tip1",
#     "tip2",
#     "tip3"
#   ],
#   "what_to_do": "<clear action the person should take right now>",
#   "helpline": "1930"
# }}"""
#
#     try:
#         response = requests.post(
#             "https://api.groq.com/openai/v1/chat/completions",
#             headers={
#                 "Content-Type": "application/json",
#                 "Authorization": f"Bearer {GROQ_API_KEY}"
#             },
#             json={
#                 "model": "llama-3.3-70b-versatile",
#                 "messages": [
#                     {"role": "user", "content": prompt}
#                 ],
#                 "temperature": 0.1,
#                 "max_tokens": 500
#             }
#         )
#
#         result = response.json()
#
#         if "choices" not in result:
#             raise ValueError("No choices in Groq API response")
#
#         content = result["choices"][0]["message"]["content"].strip()
#         content = re.sub(r"```json", "", content)
#         content = re.sub(r"```", "", content)
#
#         # Extract JSON object even if surrounded by extra text
#         json_match = re.search(r"\{[\s\S]*\}", content)
#         if json_match:
#             content = json_match.group(0)
#
#         parsed = json.loads(content)
#
#         # Ensure risk_level is consistent with scam_probability
#         if "risk_level" not in parsed or not parsed["risk_level"]:
#             score = parsed.get("scam_probability", 0)
#             parsed["risk_level"] = (
#                 "High Risk" if score >= 61 else
#                 "Suspicious" if score >= 31 else
#                 "Safe"
#             )
#
#         # Always ensure helpline is present
#         parsed["helpline"] = "1930"
#
#         return parsed
#
#     except Exception as e:
#         return {
#             "scam_probability": 0,
#             "risk_level": "Safe",
#             "fraud_type": "Others",
#             "suspicious_keywords": [],
#             "explanation": f"Analysis error: {str(e)}",
#             "prevention_tips": [
#                 "Do not click unknown links",
#                 "Never share OTP or bank details",
#                 "Verify information through official sources"
#             ],
#             "what_to_do": "If in doubt, call the National Cybercrime Helpline at 1930.",
#             "helpline": "1930"
#         }
#


"""
=============================================================
  Hybrid Spam Detector — Fixed & Improved
  Model: mrm8488/bert-tiny-finetuned-sms-spam-detection
=============================================================
  pip install transformers torch
=============================================================
"""

from transformers import pipeline
import re

# ── Load AI Model ─────────────────────────────────────────
print("Loading model...")
classifier = pipeline(
    "text-classification",
    model="mrm8488/bert-tiny-finetuned-sms-spam-detection"
)
print("Model loaded ✅\n")

# ── Scam Keyword Weights ──────────────────────────────────
scam_keywords = {
    "won":              0.30,
    "winner":           0.30,
    "prize":            0.30,
    "lottery":          0.40,
    "claim":            0.25,
    "urgent":           0.30,
    "verify":           0.30,
    "bank":             0.20,
    "account blocked":  0.40,
    "free":             0.20,
    "click":            0.20,
    "limited offer":    0.25,
    "act now":          0.25,
    "reward":           0.25,
    "gift card":        0.30,
    "otp":              0.35,
    "upi":              0.35,
    "kyc":              0.35,
    "update account":   0.35,
    "confirm details":  0.35,
    "click here":       0.50,
    "card":             0.30,
}

# ── Risk Scoring Functions ────────────────────────────────

def keyword_risk_score(text: str) -> float:
    """Sum weights of matched scam keywords (capped at 1.0)."""
    text_lower = text.lower()
    score = sum(w for kw, w in scam_keywords.items() if kw in text_lower)
    return min(score, 1.0)

def url_risk_score(text: str) -> float:
    """Detect suspicious URLs."""
    urls = re.findall(r"https?://\S+|www\.\S+", text)
    return 0.5 if urls else 0.0

def phone_risk_score(text: str) -> float:
    """Detect raw phone numbers (10-digit Indian mobile)."""
    numbers = re.findall(r"\b[6-9]\d{9}\b", text)   # ✅ stricter: starts 6-9
    return 0.4 if numbers else 0.0

def urgency_risk_score(text: str) -> float:
    """Detect urgency language."""
    urgency_words = ["immediately", "urgent", "act now", "verify now", "limited time"]
    text_lower = text.lower()
    return 0.3 if any(w in text_lower for w in urgency_words) else 0.0

# ── Main Hybrid Detector ──────────────────────────────────

def hybrid_detect(text: str) -> dict:
    """
    Combines AI model prediction with rule-based signals.

    Label mapping for mrm8488/bert-tiny-finetuned-sms-spam-detection:
      LABEL_0 = ham  (not spam)
      LABEL_1 = spam
    """
    # AI prediction
    ai_result = classifier(text, truncation=True, max_length=512)[0]
    raw_score = ai_result["score"]
    # Convert to spam probability
    ai_score = raw_score if ai_result["label"] == "LABEL_1" else 1 - raw_score

    # Rule-based signals
    kw_score      = keyword_risk_score(text)
    url_score     = url_risk_score(text)
    phone_score   = phone_risk_score(text)
    urgency_score = urgency_risk_score(text)
    pattern_score = min(kw_score + url_score + phone_score + urgency_score, 1.0)

    # Weighted combination
    final_score = round((0.65 * ai_score) + (0.35 * pattern_score), 4)

    # Risk tier
    if   final_score > 0.75: risk = "🔴 HIGH"
    elif final_score > 0.45: risk = "🟡 MEDIUM"
    else:                    risk = "🟢 LOW"

    return {
        "risk":           risk,
        "final_score":    final_score,
        "ai_score":       round(ai_score, 4),
        "pattern_score":  round(pattern_score, 4),
        "keyword_score":  round(kw_score, 4),
        "url_score":      url_score,
        "phone_score":    phone_score,
        "urgency_score":  urgency_score,
    }

# ── Pretty Print Helper ───────────────────────────────────

def print_result(label: str, text: str):
    print(f"\n{'─'*60}")
    print(f"📨 Message : {text[:80]}{'...' if len(text)>80 else ''}")
    result = hybrid_detect(text)
    print(f"   Risk     : {result['risk']}")
    print(f"   Final    : {result['final_score']:.2%}")
    print(f"   AI Score : {result['ai_score']:.2%}  |  Pattern: {result['pattern_score']:.2%}")
    print(f"   Keyword  : {result['keyword_score']:.2f}  URL: {result['url_score']:.2f}  "
          f"Phone: {result['phone_score']:.2f}  Urgency: {result['urgency_score']:.2f}")

# ── Test Messages ─────────────────────────────────────────

test_cases = [
    # ✅ FIX: triple-quote closed correctly (was """"")
    ("Jio Notification", """Dear Customer, +918919897741 is now available to take calls. Jio."""),

    ("Spam – Prize",     "Congratulations! You've WON a lottery prize of ₹50,000! Click here to claim now: http://prize-win.in"),
    ("Spam – KYC",       "URGENT: Your bank account is blocked. Update your KYC immediately or your UPI will be disabled. Call 9876543210."),
    ("Spam – OTP Phish", "Your OTP is 847291. Do NOT share it. But verify your account details at www.sbi-verify.com/confirm"),
    ("Ham – Friend",     "Hey! Are we still meeting for lunch tomorrow at 1pm?"),
    ("Ham – Office",     "Team meeting rescheduled to 4pm today. Conference Room B. Please be on time."),
]

print("\n" + "="*60)
print("  HYBRID SPAM DETECTOR — TEST RESULTS")
print("="*60)

for label, msg in test_cases:
    print_result(label, msg)

print(f"\n{'─'*60}")
print("✅ Done!\n")

# ── Interactive Mode ──────────────────────────────────────
print("💬 Enter your own message (or 'quit' to exit):\n")
while True:
    user_input = input("Message: ").strip()
    if user_input.lower() in ("quit", "exit", "q", ""):
        break
    result = hybrid_detect(user_input)
    print(f"  ➜  Risk: {result['risk']}  |  Score: {result['final_score']:.2%}\n")