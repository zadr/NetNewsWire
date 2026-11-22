"""Shared pieces for converting Nemotron 3 Diarization to Core ML and checking the conversion.

- `DiarizationStep`: the network that runs once per chunk, rewritten with plain ops over the official weights,
  for fixed shapes [prefix slots | chunk slots] so that it traces and converts cleanly.
- `log_mel`: NumPy front-end equivalent to the official `NemotronAsrStreamingFeatureExtractor` (offline/center=True).
- `SpeakerCache` / `diarize_offline`: NumPy port of the official offline chunk loop and Arrival-Order Speaker Cache.
  This is the logic the Swift side (`Sources/SpeakerDiarization`) implements around the Core ML model.
"""

import math

import numpy as np
import torch
from torch import nn

SAMPLE_RATE = 16000
N_FFT = 512
WIN_LENGTH = 400
HOP_LENGTH = 160
PREEMPHASIS = 0.97
LOG_GUARD = 2.0**-24
SUBSAMPLING = 8
HIDDEN = 512
NUM_SPEAKERS = 8


# --------------------------------------------------------------------------------------------------------------------
# Core ML network
# --------------------------------------------------------------------------------------------------------------------


class DiarizationStep(nn.Module):
    """
    One chunk step of the official model, on fixed-size inputs.

    The encoder window is `[prefix | chunk]`: `prefix_slots` slots for the speaker-cache + FIFO embeddings,
    right-aligned (padding on the left), then `chunk_slots` slots for the chunk and its look-ahead, left-aligned
    (padding on the right). `mask` flags the valid slots. RoPE positions are `arange(prefix_slots + chunk_slots)`:
    the valid frames stay contiguous, so their relative offsets (all RoPE sees) are those of the reference, whose
    positions restart at 0 on every chunk.
    """

    def __init__(self, hf_model, prefix_slots: int, chunk_slots: int):
        super().__init__()
        tower = hf_model.model.audio_tower
        self.prefix_slots = prefix_slots
        self.chunk_slots = chunk_slots
        self.embed = tower.embedder.projection
        self.input_layer_norm = tower.input_layer_norm
        self.layers = tower.layers
        self.layer_norm = tower.layer_norm
        self.proj = hf_model.model.proj
        self.upsampler = hf_model.model.upsampler.conv
        self.classifier = hf_model.classifier
        self.num_heads = tower.config.num_attention_heads
        self.head_dim = tower.config.hidden_size // self.num_heads

        n = prefix_slots + chunk_slots
        inv_freq = tower.rotary_emb.inv_freq.double()
        freqs = torch.arange(n, dtype=torch.float64)[:, None] * inv_freq[None, :]
        emb = torch.cat([freqs, freqs], dim=-1)
        self.register_buffer("cos", emb.cos().float()[None, None], persistent=False)
        self.register_buffer("sin", emb.sin().float()[None, None], persistent=False)

    def rotate_half(self, x):
        half = self.head_dim // 2
        return torch.cat([-x[..., half:], x[..., :half]], dim=-1)

    # shapes are fixed (batch 1, prefix_slots + chunk_slots) and kept as Python ints so that tracing records no
    # shape arithmetic
    def attention(self, layer, x, bias):
        attn = layer.self_attn
        n = self.prefix_slots + self.chunk_slots
        q = attn.q_proj(x).view(1, n, self.num_heads, self.head_dim).transpose(1, 2)
        k = attn.k_proj(x).view(1, n, self.num_heads, self.head_dim).transpose(1, 2)
        v = attn.v_proj(x).view(1, n, self.num_heads, self.head_dim).transpose(1, 2)
        q = q * self.cos + self.rotate_half(q) * self.sin
        k = k * self.cos + self.rotate_half(k) * self.sin
        scores = torch.matmul(q, k.transpose(2, 3)) * (self.head_dim**-0.5) + bias
        out = torch.matmul(torch.softmax(scores, dim=-1), v)
        out = out.transpose(1, 2).reshape(1, n, self.num_heads * self.head_dim)
        return attn.o_proj(out)

    def forward(self, prefix_embeds, chunk_features, mask, window_mask):
        # prefix_embeds (1, P, 512), chunk_features (1, K*8, 128) log-mel, mask (1, P+K) attention mask: 1.0 valid /
        # 0.0 padding, window_mask (1, P+K): slots inside the reference window, which equals `mask` except on an
        # encoder frame the processor masked at the very end of the audio
        b = 1
        chunk_embeds = self.embed(chunk_features.reshape(b, self.chunk_slots, SUBSAMPLING * 128))
        x = torch.cat([prefix_embeds, chunk_embeds], dim=1)
        bias = ((mask - 1.0) * 1e4)[:, None, None, :]

        h = self.input_layer_norm(x)
        for layer in self.layers:
            h = h + self.attention(layer, layer.layer_norm1(h), bias)
            h = h + layer.mlp(layer.layer_norm2(h))
        h = self.layer_norm(h)

        # zero the padding slots so that the k=3 sub-pixel conv sees the zero padding the reference sees at the
        # edges of its (unpadded) window
        p = self.proj(h) * window_mask[..., None]
        n = self.prefix_slots + self.chunk_slots
        u = self.upsampler(p.transpose(1, 2)).transpose(1, 2).reshape(b, n * SUBSAMPLING, self.proj.out_features)
        logits = self.classifier(u)

        probs = torch.sigmoid(logits).reshape(b, n, SUBSAMPLING, NUM_SPEAKERS).mean(dim=2) * mask[..., None]
        chunk_logits = logits[:, self.prefix_slots * SUBSAMPLING :]
        return chunk_embeds, probs, chunk_logits


# --------------------------------------------------------------------------------------------------------------------
# Front-end
# --------------------------------------------------------------------------------------------------------------------


def hann_window_in_fft() -> np.ndarray:
    """Symmetric (periodic=False) 400-point Hann window, zero-padded and centered in 512 points like torch.stft."""
    n = np.arange(WIN_LENGTH, dtype=np.float64)
    w = 0.5 - 0.5 * np.cos(2.0 * np.pi * n / (WIN_LENGTH - 1))
    out = np.zeros(N_FFT, dtype=np.float64)
    left = (N_FFT - WIN_LENGTH) // 2
    out[left : left + WIN_LENGTH] = w
    return out


def log_mel(audio: np.ndarray, mel_filters: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """
    Offline front-end. `audio` float32 mono 16 kHz, `mel_filters` (128, 257) Slaney filter bank.
    Returns features (T, 128) with T = len // 160 + 1, and the mel-frame mask (T,) whose last frame is 0.
    """
    x = audio.astype(np.float32)
    length = len(x)
    y = np.empty_like(x)
    y[0] = x[0]
    y[1:] = x[1:] - np.float32(PREEMPHASIS) * x[:-1]
    padded = np.pad(y, (N_FFT // 2, N_FFT // 2))
    num_frames = 1 + length // HOP_LENGTH
    idx = np.arange(N_FFT)[None, :] + HOP_LENGTH * np.arange(num_frames)[:, None]
    frames = padded[idx].astype(np.float64) * hann_window_in_fft()[None, :]
    spec = np.fft.rfft(frames, n=N_FFT, axis=1)
    power = (spec.real**2 + spec.imag**2).astype(np.float32)
    mel = power @ mel_filters.T.astype(np.float32)
    feats = np.log(mel + np.float32(LOG_GUARD)).astype(np.float32)
    num_valid = length // HOP_LENGTH
    mask = (np.arange(num_frames) < num_valid).astype(np.float32)
    feats *= mask[:, None]
    return feats, mask


# --------------------------------------------------------------------------------------------------------------------
# Offline chunk loop + Arrival-Order Speaker Cache (port of the Transformers implementation)
# --------------------------------------------------------------------------------------------------------------------


def stable_topk_indices(x, k, axis):
    """
    Indices of the k largest values along `axis`, ties broken by lowest index. `torch.topk(sorted=False)` breaks
    ties in an implementation-defined order, and exact ties do occur (frames whose pooled probability is exactly 1.0),
    so the reference is run with the same rule (see `patch_stable_topk`).
    """
    return np.argsort(-x, axis=axis, kind="stable").take(np.arange(k), axis=axis)


def patch_stable_topk():
    """Makes `torch.topk` break ties by lowest index, as `stable_topk_indices` does."""

    def topk(x, k, dim=-1, largest=True, sorted=True):
        assert largest
        idx = torch.argsort(x, dim=dim, descending=True, stable=True).narrow(dim, 0, k)
        return x.gather(dim, idx), idx

    torch.topk = topk


class SpeakerCache:
    def __init__(self, silence_embeds, fifo_length, update_period, cache_length=264, silence_frames=1,
                 score_threshold=0.25, latest_boost=0.05, strong_rate=0.75, weak_rate=1.5, min_pos_rate=0.5,
                 num_speakers=NUM_SPEAKERS):
        self.silence_embeds = silence_embeds.astype(np.float32)
        self.fifo_length = fifo_length
        self.update_period = update_period
        self.cache_length = cache_length
        self.silence_frames = silence_frames
        self.score_threshold = score_threshold
        self.latest_boost = latest_boost
        self.num_speakers = num_speakers
        budget = cache_length // num_speakers - silence_frames
        self.min_positive = math.floor(budget * min_pos_rate)
        self.num_strong = math.floor(budget * strong_rate)
        self.num_weak = math.floor(budget * weak_rate)
        self.cache_embeds = np.zeros((0, HIDDEN), np.float32)
        self.cache_probs = np.zeros((0, num_speakers), np.float32)
        self.fifo_embeds = np.zeros((0, HIDDEN), np.float32)
        self.compressed = False

    @property
    def prefix(self):
        return np.concatenate([self.cache_embeds, self.fifo_embeds], axis=0)

    def update(self, chunk_embeds, step_probs):
        """
        chunk_embeds: (num_chunk_frames, 512) encoder inputs of the chunk frames (no look-ahead).
        step_probs: (num_prefix + num_window_chunk, 8) pooled probs of the valid window frames, prefix first.
        """
        nc, nf = len(self.cache_embeds), len(self.fifo_embeds)
        num_chunk = len(chunk_embeds)
        fifo_embeds = np.concatenate([self.fifo_embeds, chunk_embeds], axis=0)
        n = len(fifo_embeds)
        popped = 0
        if n > self.fifo_length:
            popped = min(max(self.update_period, n - self.fifo_length), n)
        if popped:
            chunk_start = nc + nf
            fifo_probs = np.concatenate([step_probs[nc : nc + nf], step_probs[chunk_start : chunk_start + num_chunk]])
            stored = self.cache_probs if self.compressed else step_probs[:nc]
            cache_embeds = np.concatenate([self.cache_embeds, fifo_embeds[:popped]])
            cache_probs = np.concatenate([stored, fifo_probs[:popped]])
            fifo_embeds = fifo_embeds[popped:]
            if len(cache_embeds) > self.cache_length:
                cache_embeds, cache_probs = self._compress(cache_embeds, cache_probs)
                self.compressed = True
            self.cache_embeds, self.cache_probs = cache_embeds.astype(np.float32), cache_probs.astype(np.float32)
        self.fifo_embeds = fifo_embeds.astype(np.float32)

    def _scores(self, probs):
        t = self.score_threshold
        t = np.float32(t)
        lp = np.log(np.maximum(probs, t))
        lc = np.log(np.maximum(np.float32(1.0) - probs, t))
        scores = lp - lc + lc.sum(axis=-1, keepdims=True) - np.float32(math.log(0.5))
        is_speech = probs > 0.5
        scores = np.where(is_speech, scores, -np.inf)
        is_pos = scores > 0
        enough = is_pos.sum(axis=0, keepdims=True) >= self.min_positive
        scores = np.where(~is_pos & is_speech & enough, -np.inf, scores)
        return scores

    @staticmethod
    def _boost(scores, k, boost):
        # per speaker (column): add `boost` to its k best frames, lowest index first on ties; -inf stays -inf
        idx = stable_topk_indices(scores, k, axis=0)
        out = scores.copy()
        np.add.at(out, (idx, np.arange(scores.shape[1])[None, :].repeat(k, 0)), boost)
        return out

    def _compress(self, embeds, probs):
        num_frames, num_spk = probs.shape
        # float32 like the reference: near-equal scores at the top-k boundary must order the same way
        scores = self._scores(probs.astype(np.float32)).astype(np.float32)
        scores[self.cache_length :] += np.float32(self.latest_boost)
        scores = self._boost(scores, self.num_strong, np.float32(-2.0 * math.log(0.5)))
        scores = self._boost(scores, self.num_weak, np.float32(-math.log(0.5)))
        scores = np.concatenate([scores, np.full((self.silence_frames, num_spk), np.inf)], axis=0)
        embeds = np.concatenate([embeds, self.silence_embeds[None, :]], axis=0)
        probs = np.concatenate([probs, np.zeros((1, num_spk), probs.dtype)], axis=0)
        num_scored = num_frames + self.silence_frames
        sentinel = num_scored * num_spk
        flat = scores.T.reshape(-1)  # speaker-major
        top = stable_topk_indices(flat, self.cache_length, axis=0)
        top = np.where(flat[top] == -np.inf, sentinel, top)
        top = np.sort(top)
        frame_idx = np.where(top == sentinel, num_frames, np.minimum(top % num_scored, num_frames))
        return embeds[frame_idx], probs[frame_idx]


def diarize_offline(step, features, mel_mask, silence_embeds, prefix_slots=304, chunk_slots=380,
                    chunk_length=340, right_context=40, fifo_length=40, update_period=300):
    """
    Offline diarization of a whole recording with a fixed-shape `step` (Core ML or torch).

    step(prefix (1,P,512), chunk_features (1,K*8,128), mask (1,P+K), window_mask (1,P+K)) -> (chunk_embeds (1,K,512),
    probs (1,P+K,8), chunk_logits (1,K*8,8)), as `DiarizationStep`.
    Returns logits (T, 8) at the mel frame rate, T = len(features).
    """
    num_mel = len(features)
    pad = -num_mel % SUBSAMPLING
    feats = np.pad(features, ((0, pad), (0, 0)))
    num_embeds = len(feats) // SUBSAMPLING
    embed_mask = mel_mask[::SUBSAMPLING]

    cache = SpeakerCache(silence_embeds, fifo_length, update_period)
    out = []
    for start in range(0, num_embeds, chunk_length):
        end = min(start + chunk_length, num_embeds)
        num_chunk = end - start
        win_end = min(end + right_context, num_embeds)
        num_win = win_end - start
        prefix = cache.prefix
        num_prefix = len(prefix)
        assert num_prefix <= prefix_slots and num_win <= chunk_slots

        prefix_in = np.zeros((1, prefix_slots, HIDDEN), np.float32)
        prefix_in[0, prefix_slots - num_prefix :] = prefix
        chunk_in = np.zeros((1, chunk_slots * SUBSAMPLING, 128), np.float32)
        chunk_in[0, : num_win * SUBSAMPLING] = feats[start * SUBSAMPLING : win_end * SUBSAMPLING]
        mask = np.zeros((1, prefix_slots + chunk_slots), np.float32)
        mask[0, prefix_slots - num_prefix : prefix_slots] = 1.0
        window_mask = mask.copy()
        mask[0, prefix_slots : prefix_slots + num_win] = embed_mask[start:win_end]
        window_mask[0, prefix_slots : prefix_slots + num_win] = 1.0

        chunk_embeds, probs, chunk_logits = step(prefix_in, chunk_in, mask, window_mask)
        step_probs = np.concatenate([probs[0, prefix_slots - num_prefix : prefix_slots],
                                     probs[0, prefix_slots : prefix_slots + num_win]])
        cache.update(chunk_embeds[0, :num_chunk], step_probs)
        out.append(chunk_logits[0, : num_chunk * SUBSAMPLING])
    return np.concatenate(out)[:num_mel]


def segments_from_probs(probs, mask=None, threshold=0.5, frame_s=HOP_LENGTH / SAMPLE_RATE):
    active = probs > threshold
    if mask is not None:
        active &= mask[:, None] > 0
    segs = []
    for spk in range(active.shape[1]):
        a = np.concatenate([[0], active[:, spk].astype(np.int8), [0]])
        d = np.diff(a)
        for s, e in zip(np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]):
            segs.append((round(s * frame_s, 2), round(e * frame_s, 2), spk))
    return sorted(segs)


def frame_der(ref_active, hyp_active):
    """
    Frame-level DER between two (T, S) boolean activity matrices with the same (arrival-order) speaker labels,
    no collar, overlap scored: (missed + false alarm + confusion) / reference speech.
    """
    n_ref = ref_active.sum(1)
    n_hyp = hyp_active.sum(1)
    n_correct = (ref_active & hyp_active).sum(1)
    total = n_ref.sum()
    miss = np.maximum(n_ref - n_hyp, 0).sum()
    fa = np.maximum(n_hyp - n_ref, 0).sum()
    conf = (np.minimum(n_ref, n_hyp) - n_correct).sum()
    return (miss + fa + conf) / max(total, 1), dict(miss=int(miss), fa=int(fa), conf=int(conf), ref=int(total))
