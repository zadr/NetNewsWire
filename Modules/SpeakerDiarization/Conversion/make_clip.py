"""Makes a multi-speaker test clip from macOS text-to-speech voices, with no downloaded audio.

usage: python -I make_clip.py OUT_WAV [--minutes M]

Without --minutes: the parity reference clip, about 50 s, three voices taking turns with short pauses and one
stretch where two voices talk over each other. With --minutes: a longer clip for timing, four voices taking turns
until it is at least M minutes long.

Output is 16 kHz mono 16-bit PCM WAV. The mix is deterministic for a given set of `say` voices (the voices
themselves can change between macOS releases, which is fine: the clip is only ever compared against itself).
"""

import argparse
import os
import subprocess
import tempfile
import wave

import numpy as np

SAMPLE_RATE = 16000

# Voices that ship with macOS. The first available ones are used.
PREFERRED_VOICES = ["Daniel", "Samantha", "Fred", "Karen", "Moira", "Rishi", "Tessa", "Ralph", "Kathy", "Albert"]

LINES = [
    "Welcome back to the show. Today we are talking about reading the web with feeds, and why they still matter.",
    "Thanks for having me. I have been using a feed reader every single morning for something like fifteen years.",
    "Same here. What I like most is that nobody decides for me what shows up, or in which order.",
    "Right, and there is no algorithm guessing what will keep me scrolling. I just see what I subscribed to.",
    "Let me jump in, because I think podcasts are the best example. Every podcast app is really a feed reader.",
    "That is a great point. The enclosure in the feed is the episode, and the app simply downloads it.",
    "And now some readers can even transcribe the episodes on device, which makes them searchable.",
    "Which brings up a hard problem: figuring out who is speaking, and when, without sending audio anywhere.",
    "It is surprisingly tricky when people interrupt each other, or when two voices overlap for a moment.",
    "Exactly, like right now. Anyway, before we run out of time, let me tell you about our next episode.",
    "Oh, I almost forgot. Thank you to everyone who wrote in last week with questions about syncing.",
    "We read every message, even when it takes us a while to answer. Keep them coming.",
]

# (speaker, line, pause before the turn in seconds; negative: start that long before the previous turn ends)
REFERENCE_TURNS = [
    (0, 0, 0.3),
    (1, 1, 0.6),
    (2, 2, 0.5),
    (1, 3, 0.7),
    (2, 4, -1.6),
    (0, 5, 0.6),
    (1, 6, 0.8),
    (0, 7, 0.5),
]


def available_voices():
    out = subprocess.run(["say", "-v", "?"], check=True, capture_output=True, text=True).stdout
    names = set()
    for line in out.splitlines():
        # "Name   en_US    # sample", where Name may be followed by its language, as in "Daniel (English (UK))"
        head = line.split("#", 1)[0].rstrip()
        parts = head.rsplit(None, 1)
        if len(parts) == 2:
            names.add(parts[0].split(" (", 1)[0].strip())
    return names


def pick_voices(count):
    names = available_voices()
    voices = [v for v in PREFERRED_VOICES if v in names]
    if len(voices) < count:
        raise SystemExit(f"make_clip: need {count} of the macOS voices {PREFERRED_VOICES}, found {voices}")
    return voices[:count]


def speak(voice, text, tmp):
    path = os.path.join(tmp, "turn.wav")
    subprocess.run(["say", "-v", voice, "--file-format=WAVE", "--data-format=LEI16@16000", "-o", path, text],
                   check=True)
    with wave.open(path, "rb") as w:
        assert w.getframerate() == SAMPLE_RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        audio = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64) / 32768.0
    # same loudness for every voice
    rms = np.sqrt(np.mean(audio**2)) if len(audio) else 0.0
    return audio * (0.1 / rms) if rms > 0 else audio


def mix(turns, voices, lines):
    pieces = []
    position = 0.0
    previous_end = 0.0
    with tempfile.TemporaryDirectory() as tmp:
        for speaker, line, pause in turns:
            audio = speak(voices[speaker], lines[line], tmp)
            start = previous_end + pause
            pieces.append((int(round(start * SAMPLE_RATE)), audio))
            previous_end = start + len(audio) / SAMPLE_RATE
            position = max(position, previous_end)
    total = int(round((position + 0.5) * SAMPLE_RATE))
    out = np.zeros(total)
    for start, audio in pieces:
        out[start : start + len(audio)] += audio
    out *= 0.8 / np.abs(out).max()
    return np.round(out * 32767).astype("<i2")


def long_turns(minutes, num_speakers):
    # Rough length of a turn, to know when to stop; the clip is checked afterwards.
    turns = []
    seconds = 0.0
    i = 0
    while seconds < minutes * 60 + 30:
        speaker = (i * 7 + i // num_speakers) % num_speakers
        if turns and turns[-1][0] == speaker:
            speaker = (speaker + 1) % num_speakers
        pause = -1.2 if i % 9 == 8 else 0.4 + 0.1 * (i % 5)
        turns.append((speaker, i % len(LINES), pause))
        seconds += 6.0
        i += 1
    return turns


def write_wav(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(samples.tobytes())


def make_reference_clip(path):
    write_wav(path, mix(REFERENCE_TURNS, pick_voices(3), LINES))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_wav")
    ap.add_argument("--minutes", type=float)
    args = ap.parse_args()
    if args.minutes:
        write_wav(args.out_wav, mix(long_turns(args.minutes, 4), pick_voices(4), LINES))
    else:
        make_reference_clip(args.out_wav)
    with wave.open(args.out_wav, "rb") as w:
        print(f"{args.out_wav}: {w.getnframes() / SAMPLE_RATE:.1f} s")


if __name__ == "__main__":
    main()
