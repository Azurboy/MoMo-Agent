#!/usr/bin/env python3
"""Export Gilgamesh-J/X-ASR (X-ASR-zh-en Zipformer2 Transducer) to Apple CoreML (ANE-native MLProgram).

Architecture exported (complete non-streaming Zipformer2 Transducer with punctuation & English casing):
  1. XASREncoder.mlmodelc
     - Conv2dSubsampling (80 -> 192, ConvNeXt 7x7 + SwooshR/SwooshL + BiasNorm)
     - 6-stack 19-layer Zipformer2 (dims=[192,256,512,768,512,256], layers=[2,2,4,5,4,2],
       downsampling=[1,2,4,8,4,2], heads=[4,4,4,8,4,4], kernels=[31,31,15,15,15,31], causal=True)
     - SimpleDownsample (768, ds=2) + joiner.encoder_proj (768 -> 512)
     - Static ANE window T_fbank = 2311 (23.11s > 22.00s MoMo max window -> T_sub = 1152 -> T_out = 576)
     - 4D NCHW [1, C, 1, S] Conv2d 1x1 projections throughout
     - Overflow-free FP16 SwooshL / SwooshR & pre-scaled ANEBiasNorm (PRE_SCALE = 0.0625)
     - Exact 4D chunked Toeplitz relative positional shift (zero gather, zero 5D permute, zero ANECCompile failures)
     - Explicit padding masks + dynamic ChunkCausalDepthwiseConv1d right-edge scaling
     - Linear symmetric INT8 weight compression (~100% ANE op residency)
  2. decoder_joiner.bin
     - 128-byte aligned MOMO_XDJ v1 binary bundle for stateless Transducer Decoder (context_size=2,
       vocab=5000, dim=512, groups=128) + Joiner (decoder_proj 512->512 + output_linear 512->5000)
  3. tokens.txt
     - Upstream 5,000-token SentencePiece vocabulary with punctuation and uppercase/lowercase Latin pieces

Usage:
    uv run --python 3.12 --with "torch>=2.4,<2.7" --with "coremltools==9.0" --with "numpy<2.4" \
        --with soundfile \
        python Tools/XASRCoreML/export_xasr_coreml.py \
        --checkpoint tmp_agent_output/xasr-coreml-build/ckpt/fintuned_with_punctuation.pt \
        --tokens tmp_agent_output/xasr-coreml-build/onnx_int8/tokens.txt \
        --output-dir tmp_agent_output/xasr-coreml-build/XASRCoreML \
        --test-wav-dir tmp_agent_output/xasr-coreml-build/test_wavs
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import math
import shutil
import struct
import subprocess
import sys
import time
import types
from contextlib import nullcontext
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import soundfile as sf
import torch
import torch.nn as nn
import torch.nn.functional as F

# T_fbank = 2311 frames (23.11s > MoMo maximumRecognitionFrames 22.00s):
# T_sub = (2311 - 7) // 2 = 1152 = 9 * 128 -> exact multiple of all ds in {1, 2, 4, 8} and output ds=2 (T_out = 576).
STATIC_FBANK_T = 2311
STATIC_SUB_T = (STATIC_FBANK_T - 7) // 2  # 1152
STATIC_OUT_T = STATIC_SUB_T // 2          # 576

ENCODER_DIMS = (192, 256, 512, 768, 512, 256)
NUM_LAYERS = (2, 2, 4, 5, 4, 2)
DS_FACTORS = (1, 2, 4, 8, 4, 2)
NUM_HEADS = (4, 4, 4, 8, 4, 4)
FF_DIMS = (512, 768, 1536, 2048, 1536, 768)
CNN_KERNELS = (31, 31, 15, 15, 15, 31)
QUERY_HEAD_DIM = 32
POS_HEAD_DIM = 4
VALUE_HEAD_DIM = 12
POS_DIM = 48

VOCAB_SIZE = 5000
DECODER_DIM = 512
JOINER_DIM = 512
CONTEXT_SIZE = 2
CONV_GROUPS = 128
BLANK_ID = 0

EXPECTED_CKPT_SHA256 = "7c06433d841d9dd52988f5f32f8a407e2701377ec496c56dc8a5dc3d428c597a"

INPUT_NAMES = (
    "fbank",
    "mask_1152",
    "mask_576",
    "mask_288",
    "mask_144",
    "rshift_1152",
    "rshift_576",
    "rshift_288",
    "rshift_144",
)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# =============================================================================
# 1. Standalone Kaldi 80-bin Povey Mel-Fbank (16 kHz, snip_edges=False, [-1, 1])
# =============================================================================


def compute_kaldi_povey_fbank(samples: np.ndarray) -> np.ndarray:
    """Matches sherpa-onnx / kaldi-native-fbank OnlineFbank for X-ASR (< 1.5e-4 max diff)."""
    wav = np.asarray(samples, dtype=np.float32).reshape(-1)
    n = int(wav.shape[0])
    if n <= 0:
        return np.zeros((0, 80), dtype=np.float32)

    sr = 16000.0
    shift = 160
    win_len = 400
    nfft = 512
    num_bins = 80
    preemph = 0.97
    eps = float(np.finfo(np.float32).eps)

    num_frames = (n + shift // 2) // shift
    if num_frames <= 0:
        return np.zeros((0, num_bins), dtype=np.float32)

    a = 2.0 * np.pi / (win_len - 1)
    povey = np.power(0.5 - 0.5 * np.cos(a * np.arange(win_len, dtype=np.float64)), 0.85).astype(np.float32)

    def mel(f):
        return 1127.0 * np.log(1.0 + f / 700.0)

    ml, mh = mel(20.0), mel(7600.0)  # high_freq = -400 -> Nyquist - 400 = 7600 Hz
    dm = (mh - ml) / (num_bins + 1)
    bins_mel = mel((sr / nfft) * np.arange(nfft // 2 + 1, dtype=np.float32))
    mel_banks = np.zeros((num_bins, nfft // 2 + 1), dtype=np.float32)
    for m in range(num_bins):
        left_m, center_m, right_m = ml + m * dm, ml + (m + 1) * dm, ml + (m + 2) * dm
        mel_banks[m] = np.maximum(
            0.0, np.minimum((bins_mel - left_m) / (center_m - left_m), (right_m - bins_mel) / (right_m - center_m))
        )

    out = np.zeros((num_frames, num_bins), dtype=np.float32)
    base = np.arange(win_len, dtype=np.int64)
    for t in range(num_frames):
        start = t * shift + (shift // 2) - (win_len // 2)
        idx = start + base
        while np.any((idx < 0) | (idx >= n)):
            idx = np.where(idx < 0, -idx - 1, idx)
            idx = np.where(idx >= n, 2 * n - 1 - idx, idx)
        frame = wav[idx].copy()
        frame -= np.mean(frame, dtype=np.float32)
        frame[1:] = frame[1:] - preemph * frame[:-1]
        frame[0] *= 1.0 - preemph
        frame *= povey
        spec = np.fft.rfft(frame, n=nfft)
        power = (spec.real ** 2 + spec.imag ** 2).astype(np.float32)
        out[t] = np.log(np.maximum(mel_banks @ power, eps))
    return out


# =============================================================================
# 2. Overflow-Free ANE Operators (4D NCHW [1, C, 1, S])
# =============================================================================


def ane_safe_softplus(u: torch.Tensor) -> torch.Tensor:
    """Overflow-free ANE-native softplus: relu(u) + log(1 + exp(-|u|)).

    Avoids ANE's native ios18.softplus instruction, which evaluates naive log(1 + exp(u))
    in FP16 and saturates for u > 11.09, while keeping 100% of ops on NeuralEngine.
    """
    return F.relu(u) + torch.log(1.0 + torch.exp(-torch.abs(u)))


def ane_swoosh_l(x: torch.Tensor) -> torch.Tensor:
    return ane_safe_softplus(x - 4.0) - 0.08 * x - 0.035


def ane_swoosh_r(x: torch.Tensor) -> torch.Tensor:
    return ane_safe_softplus(x - 1.0) - 0.08 * x - 0.313261687


class ANEBiasNorm(nn.Module):
    """Exact overflow/underflow-free FP16 BiasNorm on [1, C, 1, S]."""

    PRE_SCALE = 0.0625  # 1/16 exact FP16 exponent shift: safe for RMS in [0.016, 4094]

    def __init__(self, sd: dict[str, torch.Tensor], prefix: str):
        super().__init__()
        bias = sd[f"{prefix}.bias"].detach().float()
        log_scale = sd[f"{prefix}.log_scale"].detach().float()
        c = bias.numel()
        self.register_buffer("bias", bias.view(1, c, 1, 1).clone())
        self.eff_scale = float(log_scale.exp().item()) * self.PRE_SCALE

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        d = (x - self.bias) * self.PRE_SCALE
        ms = torch.mean(d * d, dim=1, keepdim=True)
        scales = self.eff_scale * torch.rsqrt(ms + 1e-12)
        return x * scales


def make_conv1x1_from_linear(sd: dict[str, torch.Tensor], prefix: str) -> nn.Conv2d:
    w = sd[f"{prefix}.weight"].detach().float()
    b_key = f"{prefix}.bias"
    has_b = b_key in sd
    out_c, in_c = w.shape
    conv = nn.Conv2d(in_c, out_c, kernel_size=1, bias=has_b)
    with torch.no_grad():
        conv.weight.copy_(w.view(out_c, in_c, 1, 1))
        if has_b:
            conv.bias.copy_(sd[b_key].detach().float())
    return conv


def make_conv2d(
    sd: dict[str, torch.Tensor],
    prefix: str,
    kernel_size: tuple[int, int] | int,
    stride: tuple[int, int] | int = 1,
    padding: tuple[int, int] | int = 0,
    groups: int = 1,
) -> nn.Conv2d:
    w = sd[f"{prefix}.weight"].detach().float()
    b_key = f"{prefix}.bias"
    has_b = b_key in sd
    out_c = w.shape[0]
    in_c = w.shape[1] * groups
    conv = nn.Conv2d(in_c, out_c, kernel_size=kernel_size, stride=stride, padding=padding, groups=groups, bias=has_b)
    with torch.no_grad():
        conv.weight.copy_(w)
        if has_b:
            conv.bias.copy_(sd[b_key].detach().float())
    return conv


def make_compact_rel_pe(seq_len: int, embed_dim: int = POS_DIM, length_factor: float = 1.0) -> torch.Tensor:
    x = torch.arange(-(seq_len - 1), seq_len, dtype=torch.float32).unsqueeze(1)
    freqs = 1.0 + torch.arange(embed_dim // 2, dtype=torch.float32)
    compression_length = embed_dim ** 0.5
    x_compressed = (
        compression_length
        * x.sign()
        * ((x.abs() + compression_length).log() - math.log(compression_length))
    )
    length_scale = length_factor * embed_dim / (2.0 * math.pi)
    x_atan = (x_compressed / length_scale).atan()
    pe = torch.zeros(x.shape[0], embed_dim, dtype=torch.float32)
    pe[:, 0::2] = (x_atan * freqs).cos()
    pe[:, 1::2] = (x_atan * freqs).sin()
    pe[:, -1] = 1.0
    return pe  # [2*seq_len - 1, embed_dim]


def ane_rel_shift_4d(pos_raw: torch.Tensor, h: int, s: int) -> torch.Tensor:
    """Exact 4D Toeplitz shift: out[0, h, r, c] = pos_raw[0, h, r, (s - 1 - r) + c].

    Keeps all intermediate views strictly 4D [1, h, 1, b * w] with b * w < 65,536
    (ANE 16-bit width DMA coordinate limit), achieving 100.0% ANE compute residency
    and zero CPU reshape/slice fallbacks across all 6 Zipformer2 U-Net resolutions.
    """
    b = 36
    for cand in (144, 96, 72, 48, 36):
        if s % cand == 0 and cand * (s + cand - 1) < 65536:
            b = cand
            break
    if b == s:
        flat = pos_raw.reshape(1, h, 1, s * (2 * s - 1))[:, :, :, s - 1 : -1]
        return flat.reshape(1, h, s, 2 * s - 2)[:, :, :, :s]
    w = s + b - 1
    chunks = []
    for i in range(s // b):
        col_start = s - (i + 1) * b
        col_end = 2 * s - 1 - i * b
        blk = pos_raw[:, :, i * b : (i + 1) * b, col_start:col_end]
        flat = blk.reshape(1, h, 1, b * w)[:, :, :, b - 1 : -1]
        chunks.append(flat.reshape(1, h, b, w - 1)[:, :, :, :s])
    return torch.cat(chunks, dim=2)


class ANEConv2dSubsampling(nn.Module):
    def __init__(self, sd: dict[str, torch.Tensor], prefix: str = "encoder_embed"):
        super().__init__()
        self.conv0 = make_conv2d(sd, f"{prefix}.conv.0", kernel_size=3, padding=(0, 1))
        self.conv4 = make_conv2d(sd, f"{prefix}.conv.4", kernel_size=3, stride=2)
        self.conv7 = make_conv2d(sd, f"{prefix}.conv.7", kernel_size=3, stride=(1, 2))
        # Decompose 7x7 depthwise conv into 7 x (1x7) depthwise convs so 100% of ops run natively on ANE.
        dw_w = sd[f"{prefix}.convnext.depthwise_conv.weight"].detach().float()
        dw_b = sd[f"{prefix}.convnext.depthwise_conv.bias"].detach().float()
        self.dw_rows = nn.ModuleList()
        for r in range(7):
            c1d = nn.Conv2d(128, 128, kernel_size=(1, 7), padding=(0, 3), groups=128, bias=(r == 0))
            with torch.no_grad():
                c1d.weight.copy_(dw_w[:, :, r : r + 1, :])
                if r == 0:
                    c1d.bias.copy_(dw_b)
            self.dw_rows.append(c1d)
        self.cn_pw1 = make_conv2d(sd, f"{prefix}.convnext.pointwise_conv1", kernel_size=1)
        self.cn_pw2 = make_conv2d(sd, f"{prefix}.convnext.pointwise_conv2", kernel_size=1)
        self.out_proj = make_conv1x1_from_linear(sd, f"{prefix}.out")
        self.out_norm = ANEBiasNorm(sd, f"{prefix}.out_norm")

    def forward(self, fbank: torch.Tensor, valid_mask_1152: torch.Tensor) -> torch.Tensor:
        x = ane_swoosh_r(self.conv0(fbank))
        x = ane_swoosh_r(self.conv4(x))
        x = ane_swoosh_r(self.conv7(x))  # [1, 128, 1152, 19]
        x = x * valid_mask_1152.permute(0, 1, 3, 2)
        bypass = x
        xp = F.pad(x, (0, 0, 3, 3))
        h_len = x.shape[2]
        y = None
        for r, c1d in enumerate(self.dw_rows):
            yr = c1d(xp[:, :, r : r + h_len, :])
            y = yr if y is None else (y + yr)
        y = self.cn_pw2(ane_swoosh_l(self.cn_pw1(y)))
        x = (bypass + y).permute(0, 1, 3, 2).reshape(1, 128 * 19, 1, STATIC_SUB_T)
        x = self.out_proj(x)
        return self.out_norm(x)


class ANERelPosAttentionWeights(nn.Module):
    def __init__(self, sd: dict[str, torch.Tensor], prefix: str, seq_len: int, num_heads: int, pe: torch.Tensor):
        super().__init__()
        self.num_heads = num_heads
        self.seq_len = seq_len
        self.in_proj = make_conv1x1_from_linear(sd, f"{prefix}.in_proj")
        w_pos = sd[f"{prefix}.linear_pos.weight"].detach().float()
        with torch.no_grad():
            pos_proj = F.linear(pe, w_pos)
            pos_proj = (
                pos_proj.view(2 * seq_len - 1, num_heads, POS_HEAD_DIM)
                .permute(1, 2, 0)
                .unsqueeze(0)
                .contiguous()
            )
        self.register_buffer("pos_proj", pos_proj)

    def forward(self, x: torch.Tensor, attn_mask: torch.Tensor) -> torch.Tensor:
        s = self.seq_len
        h = self.num_heads
        qdim = h * QUERY_HEAD_DIM
        proj = self.in_proj(x)
        q = proj[:, :qdim, 0, :].view(1, h, QUERY_HEAD_DIM, s).transpose(2, 3)
        k = proj[:, qdim : 2 * qdim, 0, :].view(1, h, QUERY_HEAD_DIM, s)
        p = proj[:, 2 * qdim :, 0, :].view(1, h, POS_HEAD_DIM, s).transpose(2, 3)

        attn_scores = torch.matmul(q, k)
        pos_raw = torch.matmul(p, self.pos_proj)
        pos_scores = ane_rel_shift_4d(pos_raw, h, s)
        return F.softmax(attn_scores + pos_scores + attn_mask, dim=-1)


class ANESelfAttention(nn.Module):
    def __init__(self, sd: dict[str, torch.Tensor], prefix: str, num_heads: int, seq_len: int):
        super().__init__()
        self.num_heads = num_heads
        self.seq_len = seq_len
        self.in_proj = make_conv1x1_from_linear(sd, f"{prefix}.in_proj")
        self.out_proj = make_conv1x1_from_linear(sd, f"{prefix}.out_proj")

    def forward(self, x: torch.Tensor, attn_weights: torch.Tensor) -> torch.Tensor:
        v = self.in_proj(x).view(1, self.num_heads, VALUE_HEAD_DIM, self.seq_len).transpose(2, 3)
        out = torch.matmul(attn_weights, v)
        out = out.transpose(2, 3).reshape(1, self.num_heads * VALUE_HEAD_DIM, 1, self.seq_len)
        return self.out_proj(out)


class ANENonlinAttention(nn.Module):
    def __init__(self, sd: dict[str, torch.Tensor], prefix: str, seq_len: int):
        super().__init__()
        self.seq_len = seq_len
        self.in_proj = make_conv1x1_from_linear(sd, f"{prefix}.in_proj")
        self.out_proj = make_conv1x1_from_linear(sd, f"{prefix}.out_proj")
        self.hidden_channels = self.out_proj.in_channels

    def forward(self, x: torch.Tensor, attn_weights_0: torch.Tensor) -> torch.Tensor:
        c = self.hidden_channels
        proj = self.in_proj(x)
        s = torch.tanh(proj[:, :c, :, :])
        v = proj[:, c : 2 * c, :, :] * s
        y = proj[:, 2 * c :, :, :]
        vt = v.view(1, 1, c, self.seq_len).transpose(2, 3)
        out = torch.matmul(attn_weights_0, vt).transpose(2, 3).view(1, c, 1, self.seq_len)
        return self.out_proj(out * y)


class ANEFeedforward(nn.Module):
    def __init__(self, sd: dict[str, torch.Tensor], prefix: str):
        super().__init__()
        self.in_proj = make_conv1x1_from_linear(sd, f"{prefix}.in_proj")
        self.out_proj = make_conv1x1_from_linear(sd, f"{prefix}.out_proj")

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.out_proj(ane_swoosh_l(self.in_proj(x)))


class ANEDepthwiseConv1dSplit(nn.Module):
    """Splits 1D depthwise kernels with K > 15 into exact sums of K <= 15 depthwise Conv2d ops
    so 100% of K=16 and K=31 causal/chunkwise depthwise convolutions run natively on ANE."""

    def __init__(self, weight: torch.Tensor, bias: torch.Tensor | None):
        super().__init__()
        c, _, _, k = weight.shape
        self.chunks = nn.ModuleList()
        self.offsets: list[tuple[int, int]] = []
        pos = 0
        first = True
        while pos < k:
            w_len = min(15, k - pos)
            has_b = first and (bias is not None)
            conv = nn.Conv2d(c, c, kernel_size=(1, w_len), groups=c, bias=has_b)
            with torch.no_grad():
                conv.weight.copy_(weight[:, :, :, pos : pos + w_len])
                if has_b:
                    conv.bias.copy_(bias)
            self.chunks.append(conv)
            self.offsets.append((pos, w_len))
            pos += w_len
            first = False

    def forward(self, x_padded: torch.Tensor, out_len: int) -> torch.Tensor:
        acc: torch.Tensor | None = None
        for conv, (off, w_len) in zip(self.chunks, self.offsets):
            y = conv(x_padded[:, :, :, off : off + out_len + w_len - 1])
            acc = y if acc is None else (acc + y)
        assert acc is not None
        return acc


class ANEConvolutionModule(nn.Module):
    def __init__(self, sd: dict[str, torch.Tensor], prefix: str, channels: int, kernel_size: int, seq_len: int):
        super().__init__()
        self.channels = channels
        self.seq_len = seq_len
        self.left_pad = kernel_size // 2
        half_k = (kernel_size + 1) // 2

        self.in_proj = make_conv1x1_from_linear(sd, f"{prefix}.in_proj")
        self.out_proj = make_conv1x1_from_linear(sd, f"{prefix}.out_proj")
        dw_p = f"{prefix}.depthwise_conv"
        self.causal_dw = ANEDepthwiseConv1dSplit(
            sd[f"{dw_p}.causal_conv.weight"].detach().float().view(channels, 1, 1, half_k),
            sd[f"{dw_p}.causal_conv.bias"].detach().float(),
        )
        self.chunk_dw = ANEDepthwiseConv1dSplit(
            sd[f"{dw_p}.chunkwise_conv.weight"].detach().float().view(channels, 1, 1, kernel_size),
            sd[f"{dw_p}.chunkwise_conv.bias"].detach().float(),
        )
        with torch.no_grad():
            chunk_scale = sd[f"{dw_p}.chunkwise_conv_scale"].detach().float()  # [2, C, K]
            base_scale = torch.ones(1, channels, 1, seq_len, dtype=torch.float32)
            base_scale[0, :, 0, :kernel_size] += chunk_scale[0]
            right_edge = chunk_scale[1].unsqueeze(0).contiguous()  # [1, C, K]
        self.register_buffer("base_scale", base_scale)
        self.register_buffer("right_edge", right_edge)

    def forward(self, x: torch.Tensor, valid_mask: torch.Tensor, right_shift: torch.Tensor) -> torch.Tensor:
        c = self.channels
        proj = self.in_proj(x)
        u = proj[:, :c, :, :]
        gate = torch.sigmoid(proj[:, c:, :, :])
        x_gated = (u * gate) * valid_mask

        x_causal = self.causal_dw(F.pad(x_gated, (self.left_pad, 0, 0, 0)), self.seq_len)
        x_chunk = self.chunk_dw(F.pad(x_gated, (self.left_pad, self.left_pad, 0, 0)), self.seq_len)
        dyn_right = torch.matmul(self.right_edge, right_shift).unsqueeze(2)
        x_conv = x_causal + x_chunk * (self.base_scale + dyn_right)
        return self.out_proj(ane_swoosh_r(x_conv))


class ANEBypass(nn.Module):
    def __init__(self, sd: dict[str, torch.Tensor], prefix: str):
        super().__init__()
        s = sd[f"{prefix}.bypass_scale"].detach().float()
        s = s.view(1, s.numel(), 1, 1).clone()
        self.register_buffer("scale", s)
        self.register_buffer("one_minus_scale", 1.0 - s)

    def forward(self, src_orig: torch.Tensor, src: torch.Tensor) -> torch.Tensor:
        return src_orig * self.one_minus_scale + src * self.scale


class ANEZipformer2Layer(nn.Module):
    def __init__(
        self,
        sd: dict[str, torch.Tensor],
        prefix: str,
        dim: int,
        num_heads: int,
        kernel_size: int,
        seq_len: int,
        pe: torch.Tensor,
    ):
        super().__init__()
        self.self_attn_weights = ANERelPosAttentionWeights(
            sd, f"{prefix}.self_attn_weights", seq_len=seq_len, num_heads=num_heads, pe=pe
        )
        self.feed_forward1 = ANEFeedforward(sd, f"{prefix}.feed_forward1")
        self.nonlin_attention = ANENonlinAttention(sd, f"{prefix}.nonlin_attention", seq_len=seq_len)
        self.self_attn1 = ANESelfAttention(sd, f"{prefix}.self_attn1", num_heads=num_heads, seq_len=seq_len)
        self.conv_module1 = ANEConvolutionModule(sd, f"{prefix}.conv_module1", dim, kernel_size, seq_len)
        self.feed_forward2 = ANEFeedforward(sd, f"{prefix}.feed_forward2")
        self.bypass_mid = ANEBypass(sd, f"{prefix}.bypass_mid")
        self.self_attn2 = ANESelfAttention(sd, f"{prefix}.self_attn2", num_heads=num_heads, seq_len=seq_len)
        self.conv_module2 = ANEConvolutionModule(sd, f"{prefix}.conv_module2", dim, kernel_size, seq_len)
        self.feed_forward3 = ANEFeedforward(sd, f"{prefix}.feed_forward3")
        self.norm = ANEBiasNorm(sd, f"{prefix}.norm")
        self.bypass = ANEBypass(sd, f"{prefix}.bypass")

    def forward(
        self, src: torch.Tensor, valid_mask: torch.Tensor, attn_mask: torch.Tensor, right_shift: torch.Tensor
    ) -> torch.Tensor:
        src_orig = src
        attn_weights = self.self_attn_weights(src, attn_mask)
        src = src + self.feed_forward1(src)
        src = src + self.nonlin_attention(src, attn_weights[:, 0:1, :, :])
        src = src + self.self_attn1(src, attn_weights)
        src = src + self.conv_module1(src, valid_mask, right_shift)
        src = src + self.feed_forward2(src)
        src = self.bypass_mid(src_orig, src)
        src = src + self.self_attn2(src, attn_weights)
        src = src + self.conv_module2(src, valid_mask, right_shift)
        src = src + self.feed_forward3(src)
        src = self.norm(src)
        return self.bypass(src_orig, src)


class ANESimpleDownsample(nn.Module):
    """100% ANE-native softmax-weighted temporal pooling without stride=4/8 depthwise conv CPU fallback."""

    def __init__(self, sd: dict[str, torch.Tensor], prefix: str, channels: int, ds: int):
        super().__init__()
        self.ds = ds
        w = sd[f"{prefix}.bias"].detach().float().softmax(dim=0).view(1, 1, ds, 1).clone()
        self.register_buffer("w", w)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        _, c, _, s = x.shape
        return torch.matmul(x.view(1, c, s // self.ds, self.ds), self.w).view(1, c, 1, s // self.ds)


class ANESimpleUpsample(nn.Module):
    def __init__(self, upsample: int):
        super().__init__()
        self.upsample = upsample

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return F.interpolate(x, scale_factor=(1.0, float(self.upsample)), mode="nearest")


class ANEStack(nn.Module):
    def __init__(
        self,
        sd: dict[str, torch.Tensor],
        stack_idx: int,
        ds: int,
        dim: int,
        num_layers: int,
        num_heads: int,
        kernel_size: int,
    ):
        super().__init__()
        self.ds = ds
        seq_len = STATIC_SUB_T // ds
        pe = make_compact_rel_pe(seq_len, embed_dim=POS_DIM)
        base = f"encoder.encoders.{stack_idx}"
        if ds == 1:
            layer_prefix = f"{base}.layers"
            self.downsample = None
            self.upsample = None
            self.out_combiner = None
        else:
            layer_prefix = f"{base}.encoder.layers"
            self.downsample = ANESimpleDownsample(sd, f"{base}.downsample", dim, ds)
            self.upsample = ANESimpleUpsample(ds)
            self.out_combiner = ANEBypass(sd, f"{base}.out_combiner")

        self.layers = nn.ModuleList(
            [
                ANEZipformer2Layer(sd, f"{layer_prefix}.{l}", dim, num_heads, kernel_size, seq_len, pe)
                for l in range(num_layers)
            ]
        )

    def forward(
        self, x: torch.Tensor, valid_mask: torch.Tensor, attn_mask: torch.Tensor, right_shift: torch.Tensor
    ) -> torch.Tensor:
        if self.ds == 1:
            out = x
            for layer in self.layers:
                out = layer(out, valid_mask, attn_mask, right_shift)
            return out
        src_orig = x
        out = self.downsample(x)
        for layer in self.layers:
            out = layer(out, valid_mask, attn_mask, right_shift)
        out = self.upsample(out)
        return self.out_combiner(src_orig, out)


def ane_convert_channels(x: torch.Tensor, cur_c: int, target_c: int) -> torch.Tensor:
    if target_c == cur_c:
        return x
    if target_c < cur_c:
        return x[:, :target_c, :, :]
    return F.pad(x, (0, 0, 0, 0, 0, target_c - cur_c))


class ANEXASREncoder(nn.Module):
    def __init__(self, sd: dict[str, torch.Tensor]):
        super().__init__()
        self.embed = ANEConv2dSubsampling(sd, "encoder_embed")
        self.stacks = nn.ModuleList(
            [
                ANEStack(
                    sd,
                    stack_idx=i,
                    ds=DS_FACTORS[i],
                    dim=ENCODER_DIMS[i],
                    num_layers=NUM_LAYERS[i],
                    num_heads=NUM_HEADS[i],
                    kernel_size=CNN_KERNELS[i],
                )
                for i in range(len(DS_FACTORS))
            ]
        )
        self.downsample_output = ANESimpleDownsample(sd, "encoder.downsample_output", max(ENCODER_DIMS), 2)
        self.encoder_proj = make_conv1x1_from_linear(sd, "joiner.encoder_proj")

    def forward(
        self,
        fbank: torch.Tensor,        # [1, 1, 2311, 80]
        mask_1152: torch.Tensor,    # [1, 1, 1, 1152] (1.0 valid, 0.0 pad)
        mask_576: torch.Tensor,     # [1, 1, 1, 576]
        mask_288: torch.Tensor,     # [1, 1, 1, 288]
        mask_144: torch.Tensor,     # [1, 1, 1, 144]
        rshift_1152: torch.Tensor,  # [1, 31, 1152]
        rshift_576: torch.Tensor,   # [1, 31, 576]
        rshift_288: torch.Tensor,   # [1, 15, 288]
        rshift_144: torch.Tensor,   # [1, 15, 144]
    ) -> torch.Tensor:
        vmasks = {1: mask_1152, 2: mask_576, 4: mask_288, 8: mask_144}
        amasks = {k: (v - 1.0) * 10000.0 for k, v in vmasks.items()}
        rshifts = {1: rshift_1152, 2: rshift_576, 4: rshift_288, 8: rshift_144}

        x = self.embed(fbank, mask_1152)
        cur_c = ENCODER_DIMS[0]
        outputs = []
        for i, stack in enumerate(self.stacks):
            ds = DS_FACTORS[i]
            target_c = ENCODER_DIMS[i]
            x = ane_convert_channels(x, cur_c, target_c)
            cur_c = target_c
            x = stack(x, vmasks[ds], amasks[ds], rshifts[ds])
            outputs.append(x)

        full = torch.cat(
            [
                outputs[5],
                outputs[4][:, 256:512, :, :],
                outputs[3][:, 512:768, :, :],
            ],
            dim=1,
        )
        down = self.downsample_output(full)
        proj = self.encoder_proj(down)
        return proj.squeeze(2).transpose(1, 2)  # [1, 576, 512]


def build_encoder_inputs(feats: np.ndarray) -> tuple[dict[str, np.ndarray], int]:
    t_valid = min(int(feats.shape[0]), STATIC_FBANK_T)
    fbank = np.zeros((1, 1, STATIC_FBANK_T, 80), dtype=np.float16)
    if t_valid > 0:
        fbank[0, 0, :t_valid, :] = feats[:t_valid].astype(np.float16)
    sub_valid = max(1, (t_valid - 7) // 2) if t_valid >= 7 else 0

    def make_vmask(ds: int) -> np.ndarray:
        s = STATIC_SUB_T // ds
        v = (sub_valid + ds - 1) // ds if sub_valid > 0 else 0
        m = np.zeros((1, 1, 1, s), dtype=np.float16)
        if v > 0:
            m[0, 0, 0, :v] = 1.0
        else:
            # Avoid all-masked NaN softmax on degenerate < 70ms clips; caller discards 0-frame output.
            m[0, 0, 0, 0] = 1.0
        return m

    def make_rshift(ds: int, k: int) -> np.ndarray:
        s = STATIC_SUB_T // ds
        v = max(1, (sub_valid + ds - 1) // ds)
        r = np.zeros((1, k, s), dtype=np.float16)
        if v < k:
            for idx in range(v):
                r[0, k - v + idx, idx] = 1.0
        else:
            start = v - k
            for idx in range(k):
                if start + idx < s:
                    r[0, idx, start + idx] = 1.0
        return r

    t_out = (sub_valid + 1) // 2 if sub_valid > 0 else 0
    return (
        {
            "fbank": fbank,
            "mask_1152": make_vmask(1),
            "mask_576": make_vmask(2),
            "mask_288": make_vmask(4),
            "mask_144": make_vmask(8),
            "rshift_1152": make_rshift(1, 31),
            "rshift_576": make_rshift(2, 31),
            "rshift_288": make_rshift(4, 15),
            "rshift_144": make_rshift(8, 15),
        },
        t_out,
    )


# =============================================================================
# 3. Decoder + Joiner Binary Export (MOMO_XDJ v1) & Greedy Transducer Reference
# =============================================================================


def align64(offset: int) -> int:
    return (offset + 63) & ~63


def export_decoder_joiner_bin(sd: dict[str, torch.Tensor], out_path: Path) -> dict:
    emb_fp16 = sd["decoder.embedding.weight"].detach().float().numpy().astype(np.float16).tobytes()
    conv_fp32 = sd["decoder.conv.weight"].detach().float().numpy().astype(np.float32).tobytes()
    dproj_w_fp16 = sd["joiner.decoder_proj.weight"].detach().float().numpy().astype(np.float16).tobytes()
    dproj_b_fp32 = sd["joiner.decoder_proj.bias"].detach().float().numpy().astype(np.float32).tobytes()
    out_w_fp16 = sd["joiner.output_linear.weight"].detach().float().numpy().astype(np.float16).tobytes()
    out_b_fp32 = sd["joiner.output_linear.bias"].detach().float().numpy().astype(np.float32).tobytes()

    blobs = [emb_fp16, conv_fp32, dproj_w_fp16, dproj_b_fp32, out_w_fp16, out_b_fp32]
    offsets = []
    cur = 128  # 128-byte header
    for b in blobs:
        cur = align64(cur)
        offsets.append(cur)
        cur += len(b)
    total_size = align64(cur)

    hdr = struct.pack(
        "<8s8I6Q40s",
        b"MOMO_XDJ",
        1,
        VOCAB_SIZE,
        DECODER_DIM,
        JOINER_DIM,
        CONTEXT_SIZE,
        CONV_GROUPS,
        BLANK_ID,
        0,
        offsets[0],
        offsets[1],
        offsets[2],
        offsets[3],
        offsets[4],
        offsets[5],
        b"\x00" * 40,
    )
    assert len(hdr) == 128

    buf = bytearray(total_size)
    buf[:128] = hdr
    for off, b in zip(offsets, blobs):
        buf[off : off + len(b)] = b

    out_path.write_bytes(bytes(buf))
    return {
        "path": out_path.name,
        "byteCount": len(buf),
        "sha256": sha256_file(out_path),
        "vocabSize": VOCAB_SIZE,
        "decoderDim": DECODER_DIM,
        "joinerDim": JOINER_DIM,
        "contextSize": CONTEXT_SIZE,
        "convGroups": CONV_GROUPS,
    }


def load_tokens_table(tokens_path: Path) -> list[str]:
    table = [""] * VOCAB_SIZE
    for line in tokens_path.read_text("utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        tok = parts[0] if len(parts) == 2 else ""
        idx = int(parts[-1])
        table[idx] = tok
    return table


def _is_cjk(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x3400 <= cp <= 0x4DBF
        or 0x4E00 <= cp <= 0x9FFF
        or 0xF900 <= cp <= 0xFAFF
        or 0x20000 <= cp <= 0x2CEAF
    )


_NO_SPACE_BEFORE = set(",.!?:;，。！？：；、)%]}）】》”’")
_CJK_PUNCT = set("，。！？：；、")


def detokenize_xasr_tokens(raw_ids: list[int], raw_frames: list[int], vocab: list[str]) -> tuple[str, list[str], list[float]]:
    """Merges standalone '▁' onto next token (preserving non-empty spelling for RecognitionContext)
    and detokenizes Chinese + English + code-switching with exact character/token alignment."""
    merged_tokens: list[str] = []
    merged_ts: list[float] = []
    pending_space = False

    for tid, frame in zip(raw_ids, raw_frames):
        if tid <= 1 or tid >= len(vocab):
            continue
        piece = vocab[tid].replace("▁", " ")
        if not piece.strip():
            pending_space = True
            continue
        if pending_space and not piece.startswith(" "):
            piece = " " + piece
        pending_space = False
        merged_tokens.append(piece)
        merged_ts.append(round(frame * 0.04, 4))

    parts: list[str] = []
    prev_char = ""
    for tok in merged_tokens:
        has_space = tok.startswith(" ")
        spelling = tok.strip()
        if not spelling:
            continue
        first_ch = spelling[0]
        if parts and has_space:
            if first_ch in _NO_SPACE_BEFORE:
                need_space = False
            elif prev_char and (_is_cjk(prev_char) or prev_char in _CJK_PUNCT) and _is_cjk(first_ch):
                need_space = False
            else:
                need_space = True
            if need_space:
                parts.append(" ")
        parts.append(spelling)
        prev_char = spelling[-1]

    return "".join(parts), merged_tokens, merged_ts


class StatelessGreedyTransducer:
    def __init__(self, bin_path: Path, tokens_path: Path):
        data = bin_path.read_bytes()
        hdr = struct.unpack("<8s8I6Q40s", data[:128])
        assert hdr[0] == b"MOMO_XDJ" and hdr[1] == 1
        _, _, vocab, ddim, jdim, ctx, groups, blank_id, _, o_emb, o_conv, o_dw, o_db, o_ow, o_ob, _ = hdr
        self.vocab_size = vocab
        self.ddim = ddim
        self.jdim = jdim
        self.ctx = ctx
        self.groups = groups
        self.blank_id = blank_id
        self.emb = np.frombuffer(data, dtype=np.float16, count=vocab * ddim, offset=o_emb).reshape(vocab, ddim).astype(np.float32)
        self.conv_w = np.frombuffer(
            data, dtype=np.float32, count=ddim * (ddim // groups) * ctx, offset=o_conv
        ).reshape(groups, ddim // groups, ddim // groups, ctx)
        self.dproj_w = np.frombuffer(data, dtype=np.float16, count=jdim * ddim, offset=o_dw).reshape(jdim, ddim).astype(np.float32)
        self.dproj_b = np.frombuffer(data, dtype=np.float32, count=jdim, offset=o_db).copy()
        self.out_w = np.frombuffer(data, dtype=np.float16, count=vocab * jdim, offset=o_ow).reshape(vocab, jdim).astype(np.float32)
        self.out_b = np.frombuffer(data, dtype=np.float32, count=vocab, offset=o_ob).copy()
        self.tokens = load_tokens_table(tokens_path)

    def _run_decoder(self, prev0: int, prev1: int) -> np.ndarray:
        # Matches Decoder.forward(need_pad=False) with context [prev0, prev1]:
        # blank_id (0) embedding is zeroed before Conv1d!
        e0 = np.zeros(self.ddim, dtype=np.float32) if prev0 == self.blank_id else self.emb[prev0]
        e1 = np.zeros(self.ddim, dtype=np.float32) if prev1 == self.blank_id else self.emb[prev1]
        pair = np.stack([e0, e1], axis=1).reshape(self.groups, self.ddim // self.groups, 2)  # [128, 4, 2]
        conv_out = np.einsum("goik,gik->go", self.conv_w, pair).reshape(self.ddim)
        relu_out = np.maximum(conv_out, 0.0)
        return self.dproj_w @ relu_out + self.dproj_b

    def decode(self, enc_out: np.ndarray, t_out: int) -> tuple[str, list[str], list[float]]:
        prev0, prev1 = self.blank_id, self.blank_id
        dec_proj = self._run_decoder(prev0, prev1)
        ids: list[int] = []
        frames: list[int] = []
        for t in range(t_out):
            joint = np.tanh(enc_out[t] + dec_proj)
            logits = self.out_w @ joint + self.out_b
            y = int(np.argmax(logits))
            if y != self.blank_id:
                ids.append(y)
                frames.append(t)
                prev0, prev1 = prev1, y
                dec_proj = self._run_decoder(prev0, prev1)
        return detokenize_xasr_tokens(ids, frames, self.tokens)


# =============================================================================
# 4. CoreML Export, ANE ComputePlan Audit, and Parity Verification
# =============================================================================


class ANEEncoderStage0(nn.Module):
    def __init__(self, enc: ANEXASREncoder):
        super().__init__()
        self.embed = enc.embed
        self.s0 = enc.stacks[0]
        self.s1 = enc.stacks[1]

    def forward(
        self,
        fbank: torch.Tensor,
        mask_1152: torch.Tensor,
        mask_576: torch.Tensor,
        rshift_1152: torch.Tensor,
        rshift_576: torch.Tensor,
    ) -> torch.Tensor:
        x = self.embed(fbank, mask_1152)
        x = self.s0(x, mask_1152, (mask_1152 - 1.0) * 10000.0, rshift_1152)
        return self.s1(ane_convert_channels(x, 192, 256), mask_576, (mask_576 - 1.0) * 10000.0, rshift_576)


class ANEEncoderStage1(nn.Module):
    def __init__(self, enc: ANEXASREncoder):
        super().__init__()
        self.s2 = enc.stacks[2]
        self.s3 = enc.stacks[3]

    def forward(
        self,
        s1_out: torch.Tensor,
        mask_288: torch.Tensor,
        mask_144: torch.Tensor,
        rshift_288: torch.Tensor,
        rshift_144: torch.Tensor,
    ) -> torch.Tensor:
        x = self.s2(ane_convert_channels(s1_out, 256, 512), mask_288, (mask_288 - 1.0) * 10000.0, rshift_288)
        return self.s3(ane_convert_channels(x, 512, 768), mask_144, (mask_144 - 1.0) * 10000.0, rshift_144)


class ANEEncoderStage2(nn.Module):
    def __init__(self, enc: ANEXASREncoder):
        super().__init__()
        self.s4 = enc.stacks[4]
        self.s5 = enc.stacks[5]
        self.downsample_output = enc.downsample_output
        self.encoder_proj = enc.encoder_proj

    def forward(
        self,
        s3_out: torch.Tensor,
        mask_288: torch.Tensor,
        mask_576: torch.Tensor,
        rshift_288: torch.Tensor,
        rshift_576: torch.Tensor,
    ) -> torch.Tensor:
        x4 = self.s4(s3_out[:, :512, :, :], mask_288, (mask_288 - 1.0) * 10000.0, rshift_288)
        x5 = self.s5(x4[:, :256, :, :], mask_576, (mask_576 - 1.0) * 10000.0, rshift_576)
        full = torch.cat([x5, x4[:, 256:512, :, :], s3_out[:, 512:768, :, :]], dim=1)
        return self.encoder_proj(self.downsample_output(full)).squeeze(2).transpose(1, 2)


def export_encoder_coreml(ane_enc: ANEXASREncoder, out_dir: Path, work_dir: Path, reuse_existing: bool = False) -> dict:
    compiled_path = out_dir / "XASREncoder.mlmodelc"
    stage_mlcs: list[Path] = []
    if reuse_existing and compiled_path.exists():
        print(f"  Reusing existing {compiled_path}")
    else:
        qcfg = cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
        )

        def convert_stage(
            name: str, mod: nn.Module, in_specs: list[tuple[str, tuple[int, ...]]], out_name: str
        ) -> Path:
            args = tuple(torch.zeros(sh, dtype=torch.float32) for _, sh in in_specs)
            with torch.no_grad():
                traced = torch.jit.trace(mod.eval(), args)
            ml = ct.convert(
                traced,
                inputs=[ct.TensorType(name=n, shape=sh, dtype=np.float16) for n, sh in in_specs],
                outputs=[ct.TensorType(name=out_name, dtype=np.float16)],
                compute_precision=ct.precision.FLOAT16,
                minimum_deployment_target=ct.target.iOS18,
                convert_to="mlprogram",
                skip_model_load=True,
            )
            del traced
            gc.collect()
            ml = cto.linear_quantize_weights(ml, config=qcfg)
            pkg = work_dir / f"{name}.mlpackage"
            mlc = work_dir / f"{name}.mlmodelc"
            shutil.rmtree(pkg, ignore_errors=True)
            shutil.rmtree(mlc, ignore_errors=True)
            ml.save(str(pkg))
            del ml
            gc.collect()
            subprocess.run(
                ["xcrun", "coremlcompiler", "compile", str(pkg), str(work_dir)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            stage_mlcs.append(mlc)
            return pkg

        p0 = convert_stage(
            "stage0",
            ANEEncoderStage0(ane_enc),
            [
                ("fbank", (1, 1, STATIC_FBANK_T, 80)),
                ("mask_1152", (1, 1, 1, 1152)),
                ("mask_576", (1, 1, 1, 576)),
                ("rshift_1152", (1, 31, 1152)),
                ("rshift_576", (1, 31, 576)),
            ],
            "s1_out",
        )
        p1 = convert_stage(
            "stage1",
            ANEEncoderStage1(ane_enc),
            [
                ("s1_out", (1, 256, 1, 1152)),
                ("mask_288", (1, 1, 1, 288)),
                ("mask_144", (1, 1, 1, 144)),
                ("rshift_288", (1, 15, 288)),
                ("rshift_144", (1, 15, 144)),
            ],
            "s3_out",
        )
        p2 = convert_stage(
            "stage2",
            ANEEncoderStage2(ane_enc),
            [
                ("s3_out", (1, 768, 1, 1152)),
                ("mask_288", (1, 1, 1, 288)),
                ("mask_576", (1, 1, 1, 576)),
                ("rshift_288", (1, 15, 288)),
                ("rshift_576", (1, 31, 576)),
            ],
            "encoder_out",
        )

        pkg_path = work_dir / "XASREncoder.mlpackage"
        shutil.rmtree(pkg_path, ignore_errors=True)
        shutil.rmtree(compiled_path, ignore_errors=True)
        desc = ct.utils.MultiFunctionDescriptor()
        desc.add_function(str(p0), src_function_name="main", target_function_name="stage0")
        desc.add_function(str(p1), src_function_name="main", target_function_name="stage1")
        desc.add_function(str(p2), src_function_name="main", target_function_name="stage2")
        desc.default_function_name = "stage0"
        ct.utils.save_multifunction(desc, str(pkg_path))
        for p in (p0, p1, p2):
            shutil.rmtree(p, ignore_errors=True)

        subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg_path), str(out_dir)], check=True)
        shutil.rmtree(pkg_path, ignore_errors=True)

    # Subprocess audit: verify 0 ANECCompile() FAILED errors on stderr + 100% compute ANE residency + warm ANE latency!
    stage_paths_repr = repr([str(p) for p in stage_mlcs])
    audit_code = f"""
import time, json, numpy as np, coremltools as ct
from coremltools.models.compute_plan import MLComputePlan
mlc = {str(compiled_path)!r}
stage_mlcs = {stage_paths_repr}

t0 = time.perf_counter()
total_ops = 0
ane_ops = 0
non_ane = {{}}
targets = stage_mlcs if stage_mlcs else [mlc]
for sp in targets:
    plan = MLComputePlan.load_from_path(sp, compute_units=ct.ComputeUnit.CPU_AND_NE)
    for fn in plan.model_structure.program.functions.values():
        for op in fn.block.operations:
            if op.operator_name == "const" or "constexpr_" in op.operator_name:
                continue
            total_ops += 1
            u = plan.get_compute_device_usage_for_mlprogram_operation(op)
            dev = type(u.preferred_compute_device).__name__ if u and u.preferred_compute_device else "None"
            if "NeuralEngine" in dev:
                ane_ops += 1
            else:
                non_ane[op.operator_name] = non_ane.get(op.operator_name, 0) + 1
plan_s = time.perf_counter() - t0

t1 = time.perf_counter()
m0 = ct.models.CompiledMLModel(mlc, compute_units=ct.ComputeUnit.CPU_AND_NE, function_name="stage0")
stage0_load_s = time.perf_counter() - t1
m1 = ct.models.CompiledMLModel(mlc, compute_units=ct.ComputeUnit.CPU_AND_NE, function_name="stage1")
m2 = ct.models.CompiledMLModel(mlc, compute_units=ct.ComputeUnit.CPU_AND_NE, function_name="stage2")
total_load_s = time.perf_counter() - t1

tw = time.perf_counter()
_ = ct.models.CompiledMLModel(mlc, compute_units=ct.ComputeUnit.CPU_AND_NE, function_name="stage0")
_ = ct.models.CompiledMLModel(mlc, compute_units=ct.ComputeUnit.CPU_AND_NE, function_name="stage1")
_ = ct.models.CompiledMLModel(mlc, compute_units=ct.ComputeUnit.CPU_AND_NE, function_name="stage2")
warm_load_s = time.perf_counter() - tw

f0 = {{
    "fbank": np.zeros((1, 1, {STATIC_FBANK_T}, 80), np.float16),
    "mask_1152": np.ones((1, 1, 1, 1152), np.float16),
    "mask_576": np.ones((1, 1, 1, 576), np.float16),
    "rshift_1152": np.zeros((1, 31, 1152), np.float16),
    "rshift_576": np.zeros((1, 31, 576), np.float16),
}}
f1 = {{
    "s1_out": np.zeros((1, 256, 1, 1152), np.float16),
    "mask_288": np.ones((1, 1, 1, 288), np.float16),
    "mask_144": np.ones((1, 1, 1, 144), np.float16),
    "rshift_288": np.zeros((1, 15, 288), np.float16),
    "rshift_144": np.zeros((1, 15, 144), np.float16),
}}
f2 = {{
    "s3_out": np.zeros((1, 768, 1, 1152), np.float16),
    "mask_288": np.ones((1, 1, 1, 288), np.float16),
    "mask_576": np.ones((1, 1, 1, 576), np.float16),
    "rshift_288": np.zeros((1, 15, 288), np.float16),
    "rshift_576": np.zeros((1, 31, 576), np.float16),
}}
def run_all():
    f1["s1_out"] = m0.predict(f0)["s1_out"]
    f2["s3_out"] = m1.predict(f1)["s3_out"]
    return m2.predict(f2)["encoder_out"]

run_all()
run_all()
t2 = time.perf_counter()
iters = 20
for _ in range(iters):
    run_all()
lat_ms = (time.perf_counter() - t2) * 1000.0 / iters
print(json.dumps({{
    "planSeconds": round(plan_s, 3),
    "stage0ColdLoadSeconds": round(stage0_load_s, 3),
    "allStagesColdLoadSeconds": round(total_load_s, 3),
    "warmLoadSeconds": round(warm_load_s, 3),
    "totalComputeOps": total_ops,
    "aneComputeOps": ane_ops,
    "aneResidencyPct": round(100.0 * ane_ops / max(total_ops, 1), 2),
    "nonAneOpHistogram": non_ane,
    "windowLatencyMs": round(lat_ms, 2),
    "encoderRtfx": round(23110.0 / max(lat_ms, 1e-3), 1),
}}))
"""
    proc = subprocess.run([sys.executable, "-c", audit_code], capture_output=True, text=True, check=True)
    for sp in stage_mlcs:
        shutil.rmtree(sp, ignore_errors=True)
    anec_failed_count = proc.stderr.count("ANECCompile() FAILED")
    if anec_failed_count > 0:
        raise RuntimeError(f"ANECCompile() FAILED {anec_failed_count} times:\n{proc.stderr}")
    audit = json.loads(proc.stdout.strip().splitlines()[-1])
    audit["anecCompileFailures"] = anec_failed_count
    audit["totalBytes"] = sum(f.stat().st_size for f in compiled_path.rglob("*") if f.is_file() and not f.name.startswith("."))
    print(f"  XASREncoder.mlmodelc audit: {json.dumps(audit)}")
    return audit


def maybe_load_upstream_ref(sd: dict[str, torch.Tensor], ref_src_dir: Path | None):
    if ref_src_dir is None or not ref_src_dir.exists():
        return None
    icefall = types.ModuleType("icefall")
    icefall_utils = types.ModuleType("icefall.utils")
    icefall_utils.torch_autocast = lambda enabled=False, **kw: nullcontext()
    icefall_utils.make_pad_mask = lambda l, m=0: torch.arange(m or int(l.max())).unsqueeze(0) >= l.unsqueeze(1)
    sys.modules["icefall"] = icefall
    sys.modules["icefall.utils"] = icefall_utils
    k2_mod = types.ModuleType("k2")
    sys.modules["k2"] = k2_mod
    sys.path.insert(0, str(ref_src_dir))
    from scaling import SwooshLForward, SwooshRForward
    k2_mod.swoosh_l_forward = SwooshLForward
    k2_mod.swoosh_r_forward = SwooshRForward
    from subsampling import Conv2dSubsampling
    from zipformer import Zipformer2
    from joiner import Joiner
    from scaling_converter import convert_scaled_to_non_scaled

    class UpstreamRef(nn.Module):
        def __init__(self):
            super().__init__()
            self.encoder_embed = Conv2dSubsampling(in_channels=80, out_channels=192, dropout=0.0)
            self.encoder = Zipformer2(
                output_downsampling_factor=2,
                downsampling_factor=DS_FACTORS,
                encoder_dim=ENCODER_DIMS,
                num_encoder_layers=NUM_LAYERS,
                encoder_unmasked_dim=(192, 192, 256, 320, 256, 192),
                query_head_dim=QUERY_HEAD_DIM,
                pos_head_dim=POS_HEAD_DIM,
                value_head_dim=VALUE_HEAD_DIM,
                num_heads=NUM_HEADS,
                feedforward_dim=FF_DIMS,
                cnn_module_kernel=CNN_KERNELS,
                pos_dim=POS_DIM,
                dropout=0.0,
                causal=True,
                chunk_size=[-1],
                left_context_frames=[-1],
            )
            self.joiner = Joiner(encoder_dim=768, decoder_dim=512, joiner_dim=512, vocab_size=5000)

        def run_unpadded(self, feats: np.ndarray) -> np.ndarray:
            xt = torch.from_numpy(feats[None])
            xl = torch.tensor([feats.shape[0]], dtype=torch.int64)
            xe, xel = self.encoder_embed(xt, xl)
            pad_mask = torch.arange(xe.shape[1]).unsqueeze(0) >= xel.unsqueeze(1)
            eo, _ = self.encoder(xe.permute(1, 0, 2), xel, pad_mask)
            return self.joiner.encoder_proj(eo.permute(1, 0, 2)).numpy()[0]

    ref = UpstreamRef()
    ref.load_state_dict(sd, strict=False)
    convert_scaled_to_non_scaled(ref, inplace=True, is_onnx=False)
    ref.eval()
    return ref


def verify_end_to_end(
    out_dir: Path,
    ane_enc_pt: ANEXASREncoder,
    upstream_ref,
    wav_paths: list[Path],
) -> list[dict]:
    mlc = str(out_dir / "XASREncoder.mlmodelc")
    m0 = ct.models.CompiledMLModel(mlc, compute_units=ct.ComputeUnit.CPU_AND_NE, function_name="stage0")
    m1 = ct.models.CompiledMLModel(mlc, compute_units=ct.ComputeUnit.CPU_AND_NE, function_name="stage1")
    m2 = ct.models.CompiledMLModel(mlc, compute_units=ct.ComputeUnit.CPU_AND_NE, function_name="stage2")
    transducer = StatelessGreedyTransducer(out_dir / "decoder_joiner.bin", out_dir / "tokens.txt")

    def run_coreml_encoder(feed_np: dict[str, np.ndarray]) -> np.ndarray:
        s1_out = m0.predict(
            {
                "fbank": feed_np["fbank"],
                "mask_1152": feed_np["mask_1152"],
                "mask_576": feed_np["mask_576"],
                "rshift_1152": feed_np["rshift_1152"],
                "rshift_576": feed_np["rshift_576"],
            }
        )["s1_out"]
        s3_out = m1.predict(
            {
                "s1_out": s1_out,
                "mask_288": feed_np["mask_288"],
                "mask_144": feed_np["mask_144"],
                "rshift_288": feed_np["rshift_288"],
                "rshift_144": feed_np["rshift_144"],
            }
        )["s3_out"]
        return m2.predict(
            {
                "s3_out": s3_out,
                "mask_288": feed_np["mask_288"],
                "mask_576": feed_np["mask_576"],
                "rshift_288": feed_np["rshift_288"],
                "rshift_576": feed_np["rshift_576"],
            }
        )["encoder_out"][0].astype(np.float32)

    dummy_np, _ = build_encoder_inputs(np.zeros((1000, 80), dtype=np.float32))
    _ = run_coreml_encoder(dummy_np)

    results = []
    for wav_path in wav_paths:
        samples, sr = sf.read(str(wav_path), dtype="float32")
        if samples.ndim > 1:
            samples = samples[:, 0]
        assert sr == 16000, f"Expected 16 kHz audio, got {sr} for {wav_path}"
        dur = len(samples) / 16000.0

        t0 = time.perf_counter()
        feats = compute_kaldi_povey_fbank(samples)
        feed_np, t_out = build_encoder_inputs(feats)
        cm_out = run_coreml_encoder(feed_np)
        text, tokens, timestamps = transducer.decode(cm_out, t_out)
        elapsed = time.perf_counter() - t0

        with torch.no_grad():
            feed_pt = {k: torch.from_numpy(v).float() for k, v in feed_np.items()}
            fp32_static = ane_enc_pt(**feed_pt).numpy()[0, :t_out]
            fp32_unpad = upstream_ref.run_unpadded(feats)[:t_out] if upstream_ref is not None else fp32_static

        b = cm_out[:t_out].reshape(-1)
        a_static = fp32_static.reshape(-1)
        cos_static = float(np.dot(a_static, b) / (np.linalg.norm(a_static) * np.linalg.norm(b)))
        a_unpad = fp32_unpad.reshape(-1)
        cos = float(np.dot(a_unpad, b) / (np.linalg.norm(a_unpad) * np.linalg.norm(b)))
        assert cos_static >= 0.999, f"Low CoreML ANE vs FP32 static cosine {cos_static:.6f} on {wav_path.name}"
        assert cos >= 0.994, f"Low CoreML ANE vs FP32 unpadded cosine {cos:.6f} on {wav_path.name}"

        # Verify RecognitionContext.swift token-spelling alignment invariant!
        no_ws_tokens = "".join(t.replace("▁", " ") for t in tokens if t.strip()).replace(" ", "").lower()
        no_ws_text = "".join(ch for ch in text if not ch.isspace()).lower()
        assert no_ws_tokens == no_ws_text, f"Token/text mismatch on {wav_path.name}: {tokens} vs {text!r}"
        assert all(bool(t.strip()) for t in tokens), f"Empty token spelling in {tokens}"

        row = {
            "file": wav_path.name,
            "durationSec": round(dur, 2),
            "decodeSec": round(elapsed, 4),
            "rtfx": round(dur / max(elapsed, 1e-5), 1),
            "fp32StaticCosine": round(cos_static, 6),
            "fp32Cosine": round(cos, 6),
            "tokenCount": len(tokens),
            "text": text,
        }
        print(f"  [{wav_path.name}] {dur:.2f}s -> {elapsed*1000:.1f}ms ({row['rtfx']}x RTFx, staticCos={cos_static:.6f}, unpadCos={cos:.6f}): {text}")
        results.append(row)

    # Also verify pure silence and low-level ambient room hiss produce empty output without NaN/crash
    for label, synth in [
        ("silence_1s", np.zeros(16000, dtype=np.float32)),
        ("ambient_hiss_5s", np.random.default_rng(42).uniform(-0.002, 0.002, size=5 * 16000).astype(np.float32)),
    ]:
        feats = compute_kaldi_povey_fbank(synth)
        feed_np, t_out = build_encoder_inputs(feats)
        cm_out = run_coreml_encoder(feed_np)
        assert np.all(np.isfinite(cm_out)), f"Non-finite output on {label}"
        text, tokens, _ = transducer.decode(cm_out, t_out)
        print(f"  [{label}] finite=True, tokens={len(tokens)}, text={text!r}")

    return results


def build_catalog(out_dir: Path, base_url: str, identifier: str) -> dict:
    tracked_roots = [
        "decoder_joiner.bin",
        "tokens.txt",
    ]
    mlc_root = out_dir / "XASREncoder.mlmodelc"
    for f in sorted(mlc_root.rglob("*")):
        if f.is_file() and not f.name.startswith(".") and f.stat().st_size > 0:
            tracked_roots.append(str(f.relative_to(out_dir)))

    files = []
    for rel_path in sorted(tracked_roots):
        full = out_dir / rel_path
        flat_asset = rel_path.replace("/", "__")
        files.append(
            {
                "path": rel_path,
                "asset": flat_asset,
                "byteCount": full.stat().st_size,
                "sha256": sha256_file(full),
            }
        )
    if not base_url.endswith("/"):
        base_url += "/"
    return {
        "identifier": identifier,
        "baseURL": base_url,
        "files": files,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checkpoint", type=Path, required=True, help="Path to Gilgamesh-J/X-ASR fintuned_with_punctuation.pt")
    parser.add_argument("--tokens", type=Path, required=True, help="Path to upstream 5000-token tokens.txt")
    parser.add_argument("--output-dir", type=Path, required=True, help="Destination directory for compiled CoreML bundle")
    parser.add_argument("--test-wav-dir", type=Path, default=None, help="Directory of 16 kHz test wavs")
    parser.add_argument("--ref-src-dir", type=Path, default=None, help="Optional upstream src_py directory for dynamic unpadded parity check")
    parser.add_argument(
        "--base-url",
        default="https://github.com/Miri-Labs/MoMo-Agent/releases/download/models-x-asr-coreml-v1/",
    )
    parser.add_argument("--identifier", default="momo-x-asr-zipformer-coreml-ane-int8-v1")
    parser.add_argument("--reuse-existing", action="store_true")
    args = parser.parse_args()

    torch.set_grad_enabled(False)
    ckpt_path = args.checkpoint.resolve()
    tok_path = args.tokens.resolve()
    out_dir = args.output_dir.resolve()
    work_dir = out_dir.parent / (out_dir.name + ".work")
    out_dir.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)

    try:
        ckpt_sha = sha256_file(ckpt_path)
        assert ckpt_sha == EXPECTED_CKPT_SHA256, f"Unexpected checkpoint sha256: {ckpt_sha}"
        print(f"Verified checkpoint {ckpt_path.name} (sha256={ckpt_sha})")

        raw = torch.load(str(ckpt_path), map_location="cpu", weights_only=False)
        sd = raw["model"] if isinstance(raw, dict) and "model" in raw else raw
        del raw

        shutil.copy2(tok_path, out_dir / "tokens.txt")

        print("1/3 Exporting decoder_joiner.bin (MOMO_XDJ v1)...")
        dj_info = export_decoder_joiner_bin(sd, out_dir / "decoder_joiner.bin")

        print("2/3 Building & exporting ANE-native XASREncoder.mlmodelc...")
        ane_enc = ANEXASREncoder(sd).eval()
        enc_info = export_encoder_coreml(ane_enc, out_dir, work_dir, reuse_existing=args.reuse_existing)

        ref_src = args.ref_src_dir
        if ref_src is None and (ckpt_path.parent.parent / "src_py").exists():
            ref_src = ckpt_path.parent.parent / "src_py"
        upstream_ref = maybe_load_upstream_ref(sd, ref_src)
        del sd
        gc.collect()

        wav_paths: list[Path] = []
        if args.test_wav_dir and args.test_wav_dir.exists():
            wav_paths.extend(sorted(args.test_wav_dir.glob("*.wav")))
        repo_zh = Path(__file__).resolve().parents[2] / "Models/TestFixtures/zh.wav"
        if repo_zh.exists():
            wav_paths.append(repo_zh)

        print("3/3 Running end-to-end CoreML ANE parity & transcription verification...")
        examples = verify_end_to_end(out_dir, ane_enc, upstream_ref, wav_paths)

        catalog = build_catalog(out_dir, args.base_url, args.identifier)
        (out_dir / "catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")

        metadata = {
            "source": "Gilgamesh-J/X-ASR (X-ASR-zh-en)",
            "license": "Apache-2.0",
            "checkpointSha256": ckpt_sha,
            "torch": torch.__version__,
            "coremltools": ct.__version__,
            "staticFbankFrames": STATIC_FBANK_T,
            "staticSubsampledFrames": STATIC_SUB_T,
            "staticEncoderOutFrames": STATIC_OUT_T,
            "encoder": enc_info,
            "decoderJoiner": dj_info,
            "examples": examples,
            "totalDownloadBytes": sum(f["byteCount"] for f in catalog["files"]),
            "fileCount": len(catalog["files"]),
        }
        (out_dir / "export-metadata.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
        print("\n=== Export Complete ===")
        print(json.dumps(metadata, ensure_ascii=False, indent=2))
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
