from fastapi import FastAPI
from pydantic import BaseModel
import requests
import json
import re

app = FastAPI()

GROQ_API_KEY = "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"

class Message(BaseModel):
    message: str

@app.post("/analyze")
def analyze(data: Message):
    text = data.message

    prompt = f"""You are an AI-Based Fraud Risk Detection system designed to protect rural Indian citizens from digital scams.

Analyze the following message and detect scam risk with high accuracy.

Message: "{text}"

Scoring Rules (apply strictly):
- Messages asking for OTP, password, or bank details → score 80-100
- Messages asking to click links to verify account → score 70-95
- Messages claiming lottery, prize, or winner → score 80-100
- Messages offering job with high salary or work-from-home requiring payment → score 60-90
- Messages requesting UPI payment or money transfer → score 70-95
- Messages with urgent or threatening language about account suspension → score 65-90
- Messages with suspicious shortened URLs (bit.ly, tinyurl, etc.) → add 15-20 to score
- Normal informational or personal messages → score 0-20
- Sometimes massages are might from the isp so dont show them high rish and u analyze that weather from any company message or not and act accordingly

Risk Classification:
0-30 → Safe
31-60 → Suspicious
61-100 → High Risk

Return ONLY a valid JSON object with no extra text, no markdown, no explanation outside the JSON:
{{
  "scam_probability": <0-100>,
  "risk_level": "<Safe|Suspicious|High Risk>",
  "fraud_type": "<UPI Fraud|Job Scam|Lottery Scam|Phishing|KYC Scam|Safe Message|Others>",
  "suspicious_keywords": ["keyword1", "keyword2"],
  "explanation": "<2-3 sentences explaining why this is or is not a scam>",
  "prevention_tips": [
    "tip1",
    "tip2",
    "tip3"
  ],
  "what_to_do": "<clear action the person should take right now>",
  "helpline": "1930"
}}"""

    try:
        response = requests.post(
            "https://api.groq.com/openai/v1/chat/completions",
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {GROQ_API_KEY}"
            },
            json={
                "model": "llama-3.3-70b-versatile",
                "messages": [
                    {"role": "user", "content": prompt}
                ],
                "temperature": 0.1,
                "max_tokens": 500
            }
        )

        result = response.json()

        if "choices" not in result:
            raise ValueError("No choices in Groq API response")

        content = result["choices"][0]["message"]["content"].strip()
        content = re.sub(r"```json", "", content)
        content = re.sub(r"```", "", content)

        # Extract JSON object even if surrounded by extra text
        json_match = re.search(r"\{[\s\S]*\}", content)
        if json_match:
            content = json_match.group(0)

        parsed = json.loads(content)

        # Ensure risk_level is consistent with scam_probability
        if "risk_level" not in parsed or not parsed["risk_level"]:
            score = parsed.get("scam_probability", 0)
            parsed["risk_level"] = (
                "High Risk" if score >= 61 else
                "Suspicious" if score >= 31 else
                "Safe"
            )

        # Always ensure helpline is present
        parsed["helpline"] = "1930"

        return parsed

    except Exception as e:
        return {
            "scam_probability": 0,
            "risk_level": "Safe",
            "fraud_type": "Others",
            "suspicious_keywords": [],
            "explanation": f"Analysis error: {str(e)}",
            "prevention_tips": [
                "Do not click unknown links",
                "Never share OTP or bank details",
                "Verify information through official sources"
            ],
            "what_to_do": "If in doubt, call the National Cybercrime Helpline at 1930.",
            "helpline": "1930"
        }

