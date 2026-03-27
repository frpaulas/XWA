#!/usr/bin/env python3
"""
NLI gate sidecar for XWA ingestion pipeline.

Scores (premise, hypothesis) pairs using a DeBERTa NLI cross-encoder.
Returns per-pair entailment/neutral/contradiction probabilities.

Run:  python3 nli_service.py
Port: 8765 (localhost only)
"""

from contextlib import asynccontextmanager
from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import CrossEncoder
import torch
import uvicorn

_model: CrossEncoder | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _model
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Loading NLI model on {device}…", flush=True)
    _model = CrossEncoder("cross-encoder/nli-deberta-v3-small", device=device)
    print(f"NLI model ready (device={device}).", flush=True)
    yield


app = FastAPI(lifespan=lifespan)


class ScoreRequest(BaseModel):
    pairs: list[list[str]]  # [[premise, hypothesis], ...]


@app.get("/health")
def health():
    return {"status": "ok", "model_loaded": _model is not None}


@app.post("/score")
def score(req: ScoreRequest):
    if not req.pairs or _model is None:
        return {"scores": []}

    raw = _model.predict(req.pairs, apply_softmax=True)
    id2label = _model.config.id2label  # e.g. {0: "contradiction", 1: "entailment", 2: "neutral"}

    scores = [
        {id2label[i]: float(row[i]) for i in range(len(row))}
        for row in raw
    ]
    return {"scores": scores}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="info")
