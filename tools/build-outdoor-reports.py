#!/usr/bin/env python3
"""Render Crowfield's outdoor versions from the credited game recordings."""

import math
from pathlib import Path
import struct
import wave


AUDIO = Path(__file__).resolve().parents[1] / "assets" / "audio"

# Each reflection has a delay, a gain relative to the report, and a low-pass
# cutoff. Use short, uneven groups so there is no repeating slap or room ring.
DISTANCES = {
    "mid": (4300, 0.93, (
        (0.044, 0.18, 2700), (0.072, 0.13, 2300), (0.103, -0.12, 2050),
        (0.145, 0.10, 1700), (0.193, -0.085, 1450), (0.251, 0.07, 1200),
    )),
    "far": (2200, 0.77, (
        (0.042, 0.19, 2100), (0.066, -0.18, 1800), (0.095, 0.22, 1500),
        (0.131, 0.15, 1410), (0.176, -0.14, 1180), (0.223, 0.12, 1090),
        (0.279, -0.10, 950), (0.343, 0.09, 860),
    )),
}


def low_pass(samples, cutoff, rate):
    omega = math.tau * cutoff / rate
    cosine = math.cos(omega)
    alpha = math.sin(omega) / math.sqrt(2)
    a0 = 1 + alpha
    b0 = (1 - cosine) / (2 * a0)
    b1 = 2 * b0
    a1 = -2 * cosine / a0
    a2 = (1 - alpha) / a0
    x1 = x2 = y1 = y2 = 0.0
    result = []
    for x0 in samples:
        y0 = b0 * (x0 + x2) + b1 * x1 - a1 * y1 - a2 * y2
        result.append(y0)
        x2, x1 = x1, x0
        y2, y1 = y1, y0
    return result


def energy(samples):
    return sum(sample * sample for sample in samples)


def render(samples, rate, settings):
    cutoff, attack_level, taps = settings
    source = samples + [0.0] * round(0.02 * rate)
    report = low_pass(source, cutoff, rate)
    report.extend([0.0] * round(taps[-1][0] * rate))
    for delay, level, echo_cutoff in taps:
        reflection = low_pass(source, echo_cutoff, rate)
        offset = round(delay * rate)
        for index, sample in enumerate(reflection):
            report[offset + index] += level * sample

    # Match the direct portion and cap peaks at the original's maximum.
    # Leave an extended, quiet decay instead of boosting the whole tail.
    attack = round(0.095 * rate)
    matched = attack_level * math.sqrt(energy(samples[:attack]) / energy(report[:attack]))
    gain = min(matched, max(map(abs, samples)) / max(map(abs, report)))
    fade = round(0.035 * rate)
    for index in range(fade):
        report[-index - 1] *= index / fade
    return [round(sample * gain) for sample in report]


def main():
    for path in sorted(AUDIO.glob("*-shot.wav")):
        with wave.open(str(path), "rb") as source:
            channels, width, rate, count, _, _ = source.getparams()
            if channels != 1 or width != 2:
                raise ValueError(f"Expected mono 16-bit PCM in {path}")
            samples = list(struct.unpack(f"<{count}h", source.readframes(count)))
        for name, settings in DISTANCES.items():
            report = render(samples, rate, settings)
            with wave.open(str(path.with_stem(f"{path.stem}-{name}")), "wb") as output:
                output.setparams((1, 2, rate, len(report), "NONE", "not compressed"))
                output.writeframes(struct.pack(f"<{len(report)}h", *report))


if __name__ == "__main__":
    main()
