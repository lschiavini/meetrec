# /// script
# dependencies = ["mlx-whisper"]
# ///
"""Transcribe one audio file to timestamped text lines.

usage: transcribe.py AUDIO OUT_TXT [--model REPO] [--vocabulary TEXT] [--offset SECONDS]
"""
import argparse

import mlx_whisper

parser = argparse.ArgumentParser()
parser.add_argument("audio")
parser.add_argument("out")
parser.add_argument("--model", default="mlx-community/whisper-large-v3-turbo")
parser.add_argument("--vocabulary", default="", help="names and jargon the model should expect")
parser.add_argument("--offset", type=float, default=0.0, help="seconds to add to every timestamp")
args = parser.parse_args()

result = mlx_whisper.transcribe(
    args.audio,
    path_or_hf_repo=args.model,
    verbose=None,
    condition_on_previous_text=False,
    initial_prompt=args.vocabulary or None,
)

kept = 0
with open(args.out, "w") as out:
    for segment in result["segments"]:
        text = segment["text"].strip()
        # On silence the model invents filler such as "Thank you."; it marks those segments itself.
        if not text or segment.get("no_speech_prob", 0) > 0.6:
            continue
        start = int(segment["start"] + args.offset)
        out.write(f"[{start // 60:02d}:{start % 60:02d}] {text}\n")
        kept += 1

print(f"language={result.get('language')} lines={kept}")
