# /// script
# dependencies = ["mlx-whisper"]
# ///
"""Transcribe one audio file to timestamped text lines, in whatever languages are spoken.

usage: transcribe.py AUDIO OUT_TXT [--model REPO] [--vocabulary TEXT] [--offset SECONDS]
                                   [--languages it,pt]

Whisper on its own picks one language from the first 30 seconds and uses it for the whole
file, so a class that mixes Italian and Portuguese comes out in one of them (or translated).
Instead the audio is cut at pauses into chunks of up to 30 seconds and:
  1. each chunk's language is detected, and the languages that win often enough become the
     recording's languages (or --languages names them up front);
  2. each chunk is transcribed in whichever of those languages it sounds most like.
When more than one language is found, every line is tagged with it: "[12:03] [it] ...".
"""
import argparse
from collections import Counter

import mlx.core as mx
import mlx_whisper
import numpy as np
from mlx_whisper.audio import N_FRAMES, N_SAMPLES, SAMPLE_RATE, load_audio, log_mel_spectrogram, pad_or_trim
from mlx_whisper.transcribe import ModelHolder

parser = argparse.ArgumentParser()
parser.add_argument("audio")
parser.add_argument("out")
parser.add_argument("--model", default="mlx-community/whisper-large-v3-turbo")
parser.add_argument("--vocabulary", default="", help="names and jargon the model should expect")
parser.add_argument("--offset", type=float, default=0.0, help="seconds to add to every timestamp")
parser.add_argument("--languages", default="", help="comma-separated codes (it,pt); empty = detect")
parser.add_argument("--save-languages", default="", help="file to write the languages used to, as it,pt")
args = parser.parse_args()

MIN_CHUNK, MAX_CHUNK = 5.0, 30.0  # seconds
FRAME = SAMPLE_RATE // 50  # 20 ms
# A language counts as spoken when it wins at least this share of the chunks it is sure about.
# Noise and mumbles come back as low-confidence English or Spanish, so only sure chunks vote.
MIN_CONFIDENCE, MIN_SHARE, MIN_CHUNKS = 0.8, 0.05, 2


def split_at_pauses(audio):
    """Yields (start, end) sample ranges, each cut at a pause between MIN_CHUNK and MAX_CHUNK."""
    frames = len(audio) // FRAME
    if frames == 0:
        return [(0, len(audio))], np.zeros(1)
    rms = np.sqrt(np.mean(audio[: frames * FRAME].reshape(frames, FRAME) ** 2, axis=1))
    smooth = np.convolve(rms, np.ones(15) / 15, mode="same")  # 300 ms
    quiet = np.percentile(smooth, 15) * 1.5
    pause = 20  # 400 ms below `quiet` counts as a pause

    chunks, start = [], 0
    lo, hi = int(MIN_CHUNK * 50), int(MAX_CHUNK * 50)
    while start < frames:
        if frames - start <= hi:
            chunks.append((start, frames))
            break
        window = smooth[start + lo : start + hi] < quiet
        cut = None
        run = 0
        for i, q in enumerate(window):
            run = run + 1 if q else 0
            if run >= pause:
                cut = start + lo + i - pause // 2
                break
        if cut is None:
            cut = start + lo + int(np.argmin(smooth[start + lo : start + hi]))
        chunks.append((start, cut))
        start = cut
    ranges = [(s * FRAME, min(e * FRAME, len(audio)) if e < frames else len(audio)) for s, e in chunks]
    speech_floor = max(quiet * 2, 1e-3)
    loud = np.array([np.percentile(rms[s:e], 90) if e > s else 0 for s, e in chunks]) > speech_floor
    return ranges, loud


def language_probs(model, chunk):
    mel = log_mel_spectrogram(chunk, n_mels=model.dims.n_mels, padding=N_SAMPLES)
    mel = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
    _, probs = model.detect_language(mel)
    return probs


audio = np.array(load_audio(args.audio), dtype=np.float32)
ranges, has_speech = split_at_pauses(audio)
model = ModelHolder.get_model(args.model, mx.float16)

probs = [language_probs(model, audio[s:e]) for s, e in ranges]

if args.languages.strip():
    languages = [code.strip() for code in args.languages.split(",") if code.strip()]
else:
    wins = Counter()
    for p, loud in zip(probs, has_speech):
        top = max(p, key=p.get)
        if loud and p[top] >= MIN_CONFIDENCE:
            wins[top] += 1
    total = sum(wins.values()) or 1
    languages = [lang for lang, n in wins.most_common() if n >= MIN_CHUNKS and n / total >= MIN_SHARE]
    languages = languages[:3] or [max(probs[0], key=probs[0].get)]

tag = len(languages) > 1
spoken = Counter()
kept = 0
with open(args.out, "w") as out:
    for (s, e), p in zip(ranges, probs):
        lang = max(languages, key=lambda code: p.get(code, 0.0))
        result = mlx_whisper.transcribe(
            audio[s:e],
            path_or_hf_repo=args.model,
            verbose=None,
            language=lang,
            condition_on_previous_text=False,
            initial_prompt=args.vocabulary or None,
        )
        for segment in result["segments"]:
            text = segment["text"].strip()
            # On silence the model invents filler such as "Thank you."; it marks those segments itself.
            # Text the model is very unsure of is noise read as words, often in random scripts.
            if not text or segment.get("no_speech_prob", 0) > 0.6 or segment.get("avg_logprob", 0) < -1.0:
                continue
            start = int(s / SAMPLE_RATE + segment["start"] + args.offset)
            label = f" [{lang}]" if tag else ""
            out.write(f"[{start // 60:02d}:{start % 60:02d}]{label} {text}\n")
            spoken[lang] += 1
            kept += 1

if args.save_languages:
    with open(args.save_languages, "w") as f:
        f.write(",".join(lang for lang, _ in spoken.most_common()) or ",".join(languages))
print(f"languages={','.join(f'{k}:{v}' for k, v in spoken.most_common()) or 'none'} lines={kept}")
