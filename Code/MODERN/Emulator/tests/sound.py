"""Sound cases of tests/run.py: `sound` and `audio-playback`.

`sound` boots the probe program (sound.asm) in its own MAME process per probe and
runs a sound.lua body.  Audio is captured with MAME's -wavwrite at 192 kHz
(independent of the host speaker; the run uses -sound none), the register events
and phases come from the Lua side (events.tsv), and the checks below read both.

  bus      Lua writes: every tone channel of every chip alone, the mirrors, the unwired
           ports, four chips at once and each silenced alone, the attenuation steps, the
           noise generator against a model of the SN76489A (and not the
           SN76489), the DAC codes, loud mixes (peaks)
  guest    real Z80 instructions: OTIR into PSG ports (the READY stretch) and into the DAC,
           IN over E0h-FFh while a tone sounds, OUT (C),A through mirrors, a machine reset
           with a tone sounding and the DAC high

`audio-playback` runs the real sndtest, sntview and VGMPlayer from a card image on the
production KonaOS image (run_playback) and checks the audio and the
register events they produce."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import wave

import numpy as np

import mame_args

HERE = Path(__file__).resolve().parent
PROBES = {"sound": ("bus", "guest"), "audio-playback": ("sndtest", "sntview", "vgmplay")}
RATE = 192000
CLOCK = 3579545            # Y1, the PSG clock
CPU_CLOCK = 10_000_000

# The mix (zephyr80.cpp mix_gain): the inverting stages' 10 kOhm over the input
# resistor, left and right averaged, times 0.66.
SCALE = 0.66


def gain(left, right):
    return SCALE * 0.5 * (10.0 / left + 10.0 / right)


PSG_GAIN = [gain(33, 33), gain(33, 33), gain(22, 47), gain(47, 22)]
DAC_GAIN = gain(47, 47)
CHANNEL_LEVEL = 0x7fff // 4 / 32768     # one SN76496-family channel at attenuation 0


def sha(data):
    return hashlib.sha256(data).hexdigest()


def assemble(output):
    """Build the probe flash image from sound.asm with the SDCC tools."""
    build = output / "sound_probe"
    build.mkdir(parents=True, exist_ok=True)
    rel, ihx, image = build / "sound.rel", build / "sound.ihx", build / "sound.bin"
    for command in (["sdasz80", "-o", "-l", "-s", str(rel), str(HERE / "sound.asm")],
                    ["sdldz80", "-n", "-i", str(ihx), str(rel)],
                    ["makebin", str(ihx), str(image)]):
        subprocess.run(command, check=True, capture_output=True, text=True)
    return image


def mame_command(mame, image, case_dir, deadline, wav, extra=()):
    return [str(mame.resolve()), "zephyr80", "-noreadconfig", "-skip_gameinfo", "-video", "none", "-sound", "none",
            "-nothrottle", "-seconds_to_run", str(deadline + 2), "-samplerate", str(RATE), "-wavwrite", str(wav),
            "-cfg_directory", str(case_dir / "cfg"), "-nvram_directory", str(case_dir / "nvram"),
            "-state_directory", str(case_dir / "sta"), "-snapshot_directory", str(case_dir / "snap"),
            "-flash", str(image), "-autoboot_script", str(HERE / "harness.lua"), "-autoboot_delay", "0",
            *mame_args.EXTRA, *extra]


def run_mame(command, environment, wall, case_dir, body):
    """One MAME process; returns (ok, exit code, log)."""
    start = time.monotonic()
    try:
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=wall)
        code, log = result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as exc:
        code = 124
        log = (exc.stdout or b"").decode(errors="replace") + f"\nWALL TIMEOUT after {wall} seconds\n"
    log += f"RUN wall {time.monotonic() - start:.3f} s\n"
    (case_dir / "mame.log").write_text(log)
    verdicts = [line for line in log.splitlines() if re.match(rf"(PASS|FAIL) harness {re.escape(body)}: ", line)]
    return code == 0 and len(verdicts) == 1 and verdicts[0].startswith("PASS"), code, log


# Audio analysis ----------------------------------------------------------------------

class Audio:
    """The captured PCM as floats (full scale 1.0) with the offset between the event
    clock and the audio clock from the DAC calibration step."""

    def __init__(self, wav, latency=0.0):
        with wave.open(str(wav)) as w:
            self.rate = w.getframerate()
            assert w.getnchannels() == 1 and w.getsampwidth() == 2
            self.x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
        self.latency = latency

    def window(self, t0, t1):
        a = max(0, int(round((t0 + self.latency) * self.rate)))
        b = min(len(self.x), int(round((t1 + self.latency) * self.rate)))
        return self.x[a:b]

    def calibrate(self, step_time, level):
        """The audio time of the step to `level` the events say happened at `step_time`."""
        a = int(max(0, (step_time - 0.02) * self.rate))
        b = int((step_time + 0.1) * self.rate)
        seg = self.x[a:b]
        hit = np.nonzero(seg > level * 0.5)[0]
        if not len(hit):
            raise AssertionError("no calibration step in the audio")
        i = hit[0]
        # interpolate the crossing
        y0, y1 = seg[i - 1], seg[i]
        frac = (level * 0.5 - y0) / (y1 - y0) if y1 != y0 else 0.0
        self.latency = (a + i - 1 + frac) / self.rate - step_time
        return self.latency


def crossings(x, rate, threshold, rising=True):
    """Interpolated times (s, relative to the window) where x crosses threshold."""
    above = x > threshold
    idx = np.nonzero(above[1:] != above[:-1])[0]
    times = []
    for i in idx:
        if above[i + 1] == rising:
            y0, y1 = x[i], x[i + 1]
            times.append((i + (threshold - y0) / (y1 - y0)) / rate)
    return np.array(times)


def tone_frequency(x, rate):
    """Frequency of a unipolar square wave: rising crossings of the mid level."""
    lo, hi = np.percentile(x, 2), np.percentile(x, 98)
    if hi - lo < 1e-4:
        return None
    t = crossings(x, rate, (lo + hi) / 2)
    if len(t) < 4:
        return None
    return (len(t) - 1) / (t[-1] - t[0])


def goertzel(x, rate, freq):
    """Amplitude of the component at `freq` (Hann window)."""
    n = np.arange(len(x))
    w = np.hanning(len(x))
    phase = np.exp(-2j * math.pi * freq * n / rate)
    return abs(np.sum(x * w * phase)) / np.sum(w) * 2


# Events ------------------------------------------------------------------------------

def read_events(path):
    writes, reads, phases, other = [], [], [], []
    for line in path.read_text().splitlines()[1:]:
        f = line.split("\t")
        if f[0] == "W":
            writes.append((float(f[1]), int(f[2], 16), int(f[3], 16)))
        elif f[0] == "R":
            reads.append((float(f[1]), int(f[2], 16), int(f[3], 16)))
        elif f[0] == "P":
            phases.append({"t0": float(f[1]), "name": f[2], "params": f[3], "t1": float(f[4]), "pre": float(f[5])})
        else:
            other.append(f)
    return writes, reads, phases, other


def param(params, key, default=None):
    m = re.search(rf"{key}=(\w+)", params)
    return m.group(1) if m else default


# The SN76489A noise model ------------------------------------------------------------
#
# A shift register of 16 bits plus the feedback stage: reset to the feedback mask, it
# shifts right each noise period, the new bit entering at the top is the XOR of the two
# tap bits (white) or the first tap alone (periodic); the output is the low bit.  The
# SN76489A taps bits 2 and 3 of a 17-bit register (mask 10000h) and is not inverted; the
# SN76489 is a 15-bit register (mask 4000h) with taps 0 and 1, inverted.

VARIANTS = {"SN76489A": (0x10000, 0x04, 0x08, False), "SN76489": (0x4000, 0x01, 0x02, True)}


def noise_bits(variant, white, count):
    mask, tap1, tap2, negate = VARIANTS[variant]
    rng, out = mask, []
    for _ in range(count):
        feedback = bool(rng & tap1) != (bool(rng & tap2) and white)
        rng >>= 1
        if feedback:
            rng |= mask
        out.append((rng & 1) ^ (1 if negate else 0))
    return out


def decode_noise(x, rate, step_s, t_ctl, count):
    """Bits of a noise capture whose shift period is `step_s`; `t_ctl` is the window time of
    the control write.  The grid comes from the edges."""
    lo, hi = np.percentile(x, 1), np.percentile(x, 99)
    mid = (lo + hi) / 2
    edges = np.sort(np.concatenate([crossings(x, rate, mid, True), crossings(x, rate, mid, False)]))
    if not len(edges):
        return []
    grid = (edges[0] - t_ctl) % step_s
    bits = []
    t = t_ctl + grid + step_s / 2
    while t < len(x) / rate - step_s / 2 and len(bits) < count:
        bits.append(int(x[int(t * rate)] > mid))
        t += step_s
    return bits


def best_alignment(bits, variant, white, span=200):
    """(offset, matches, overlap) of the best alignment of the decoded bits into the model.
    A positive offset skips shifts the capture's first bit already follows; a negative one
    ignores the leading bits seen before the first shift (the old period still counting)."""
    ref = noise_bits(variant, white, len(bits) + span)
    best, best_score = (0, 0, 0), None
    for off in range(-span, span):
        lo = max(0, -off)
        pairs = [(bits[i], ref[i + off]) for i in range(lo, len(bits))]
        if len(pairs) < 40:
            continue
        hit = sum(1 for p, q in pairs if p == q)
        score = hit - 4 * (len(pairs) - hit)
        if best_score is None or score > best_score:
            best, best_score = (off, hit, len(pairs)), score
    return best


# Checks ------------------------------------------------------------------------------

class Checks:
    def __init__(self):
        self.items = []

    def add(self, name, ok, detail):
        self.items.append({"check": name, "pass": bool(ok), "detail": detail})
        return ok

    @property
    def ok(self):
        return all(i["pass"] for i in self.items)

    def lines(self):
        return [f"CHECK {'PASS' if i['pass'] else 'FAIL'} {i['check']}: {i['detail']}" for i in self.items]


GUARD = 0.004


def settle(ph, a=0.35, b=0.0):
    """The steady part of a phase: skip the first `a` of it and the last `b`, and always the
    last few milliseconds (the resampler's pre-ringing before the next phase's first step)."""
    span = ph["t1"] - ph["t0"]
    return ph["t0"] + a * span, ph["t1"] - max(b * span, GUARD)


def calibrate(audio, writes):
    first = next(w for w in writes if w[1] == 0xe4 and w[2] == 0xff)
    return audio.calibrate(first[0], DAC_GAIN * (0xff - 128) / 128)


def expected_frequency(divisor):
    return CLOCK / (32.0 * divisor)


def analyse_bus(wav, events):
    c = Checks()
    writes, reads, phases, _ = read_events(events)
    audio = Audio(wav)
    lat = calibrate(audio, writes)
    c.add("audio clock", abs(lat) < 0.05, f"DAC step in the audio {lat * 1000:.3f} ms after its write")
    by = lambda name: [p for p in phases if p["name"] == name]

    # Silence: exactly zero.
    quiet = by("quiet")
    worst = max(np.abs(audio.window(*settle(p, 0.3))).max() for p in quiet)
    c.add("silence", worst < 2 / 32768, f"{len(quiet)} quiet phases, largest sample {worst * 32768:.2f} LSB")

    # Tone periods: every channel of every chip alone, and the mirrors.
    worst_error, count = 0.0, 0
    for p in by("tone"):
        chip, channel, div = int(param(p["params"], "chip")), int(param(p["params"], "channel")), int(param(p["params"], "divisor"))
        x = audio.window(*settle(p))
        f = tone_frequency(x, audio.rate)
        want = expected_frequency(div)
        err = abs(f - want) / want if f else 1.0
        worst_error, count = max(worst_error, err), count + 1
        amp = np.percentile(x, 98) - np.percentile(x, 2)
        level = CHANNEL_LEVEL * PSG_GAIN[chip]
        c.add(f"tone chip {chip} channel {channel} port {param(p['params'], 'port')}", err < 0.002 and abs(amp - level) / level < 0.03,
              f"divisor {div}: {f:.2f} Hz against {want:.2f} Hz ({err * 100:.3f} %), swing {amp * 32768:.0f} against {level * 32768:.0f} LSB")
    c.add("tone periods", worst_error < 0.002 and count == 12 + 12, f"{count} tones, worst error {worst_error * 100:.3f} %")

    # Unwired ports: no sound.
    for p in by("unwired"):
        x = audio.window(*settle(p, 0.2))
        c.add("unwired ports 5-7 and mirrors", np.abs(x).max() < 2 / 32768, f"largest sample {np.abs(x).max() * 32768:.2f} LSB")

    # Isolation: four chips at once, then each silenced alone.
    together = by("together")[0]
    freqs = [expected_frequency(d) for d in (211, 257, 307, 359)]
    base = [goertzel(audio.window(*settle(together, 0.3)), audio.rate, f) for f in freqs]
    c.add("four chips at once", all(b > 0.2 * CHANNEL_LEVEL * g for b, g in zip(base, PSG_GAIN)),
          "fundamentals " + ", ".join(f"{f:.1f} Hz {b * 32768:.0f} LSB" for f, b in zip(freqs, base)))
    for k, p in enumerate(by("drop")):
        now = [goertzel(audio.window(*settle(p, 0.3)), audio.rate, f) for f in freqs]
        gone = now[k] < 0.02 * base[k]
        # Chips silenced earlier stay gone; the later ones are unchanged.
        later_ok = all(abs(now[j] - base[j]) < 0.1 * base[j] for j in range(k + 1, 4))
        earlier_ok = all(now[j] < 0.02 * base[j] for j in range(k))
        c.add(f"isolation: silence chip {k} alone", gone and later_ok and earlier_ok,
              "after: " + ", ".join(f"chip {j} {now[j] / base[j] * 100:.1f} %" for j in range(4)))

    # Attenuation: 2 dB steps, 15 off.
    levels = []
    for p in by("attenuation"):
        x = audio.window(*settle(p, 0.4))
        levels.append(np.percentile(x, 98) - np.percentile(x, 2))
    ok, detail = True, []
    for att, lv in enumerate(levels):
        want = CHANNEL_LEVEL * PSG_GAIN[0] * (10 ** (-att / 10)) if att < 15 else 0.0
        good = abs(lv - want) <= max(0.03 * want, 2 / 32768)
        ok = ok and good
        detail.append(f"{att}:{lv * 32768:.0f}/{want * 32768:.0f}")
    c.add("attenuation steps (2 dB, 15 = off)", ok and len(levels) == 16, "swing/expected LSB " + " ".join(detail))

    # DAC mapping.
    ok, rows = True, []
    for p in by("dac"):
        code = int(param(p["params"], "code"), 16)
        x = audio.window(*settle(p, 0.5))
        mean = x.mean()
        want = DAC_GAIN * (code - 128) / 128
        good = abs(np.median(x) - want) < 0.0001 and abs(mean - want) < 0.0004 and x.std() < 0.0002
        ok = ok and good
        rows.append(f"{code:02X}@{param(p['params'], 'port')}:{mean * 32768:+.0f}/{want * 32768:+.0f}")
    c.add("DAC mapping (80h = zero, offset binary)", ok and len(rows) == 10, "level/expected LSB " + " ".join(rows))

    # Noise against the models.
    clock_step = lambda period: period * 16 / CLOCK
    noises = by("noise")
    results = {}
    for p in noises:
        control = int(param(p["params"], "control"), 16)
        rate = control & 3
        white = bool(control & 4)
        # the control write time of this phase is the last write of the control byte at or before t1
        t_ctl = max(w[0] for w in writes if w[1] & 7 == 0 + (3 if "chip=3" in p["params"] else 0) and w[2] == control and w[0] <= p["t0"])
        period = 768 if rate == 3 else 1 << (5 + rate)
        x = audio.window(t_ctl, p["t1"])
        bits = decode_noise(x, audio.rate, clock_step(period), 0.0, 400)
        a_off, a_hit, a_over = best_alignment(bits, "SN76489A", white)
        b_off, b_hit, b_over = best_alignment(bits, "SN76489", white)
        results[p["params"]] = (len(bits), a_off, a_hit, a_over, b_hit, b_over)
        if "periodic" in p["params"]:
            # The datasheet's 15-bit ring: one set bit in every 15 shifts.
            tail = bits[30:]
            ring = len(tail) > 45 and all(tail[i] == tail[i + 15] for i in range(len(tail) - 15)) and sum(tail[:15]) == 1
            c.add("periodic noise repeats every 15 shifts", ring, f"{len(tail)} bits from the 31st, period 15: {ring}")
        c.add(f"noise {p['params']}", len(bits) >= 60 and a_hit == a_over >= 60 and b_hit < 0.9 * b_over,
              f"{len(bits)} bits (shift period {clock_step(period) * 1e6:.1f} us): SN76489A model matches {a_hit} of {a_over} at offset {a_off}, SN76489 model {b_hit} of {b_over}")

    # Loud mixes: peaks (informational) and no clipping.
    bound = CHANNEL_LEVEL * 4 * sum(PSG_GAIN)
    peaks = {}
    for p in by("loud"):
        x = audio.window(*settle(p, 0.25))
        peaks[p["params"]] = (float(x.max()), float(x.min()))
    ok = bool(peaks) and all(hi < 0.999 and lo > -0.999 for hi, lo in peaks.values())
    c.add("loud mixes do not clip", ok, "; ".join(f"{k}: max {hi:+.4f} min {lo:+.4f}" for k, (hi, lo) in peaks.items())
          + f"; four chips x four channels x level {CHANNEL_LEVEL:.5f} x gains = {bound:.4f}, the DAC adds {DAC_GAIN * 127 / 128:.4f} high or {-DAC_GAIN:.4f} low")
    return c, {"latency_s": lat, "noise": {k: list(v) for k, v in results.items()}, "peaks": peaks,
               "gains": {"psg": PSG_GAIN, "dac": DAC_GAIN}}


def analyse_guest(wav, events):
    c = Checks()
    writes, reads, phases, other = read_events(events)
    audio = Audio(wav)
    lat = calibrate_guest(audio, writes)
    by = lambda name: [p for p in phases if p["name"] == name]

    # OTIR: the interval between consecutive writes.  Four PSG ports take the READY
    # stretch (32 PSG clocks), the DAC does not.
    ready = 32.0 / CLOCK
    iteration = 21 / CPU_CLOCK
    psg_p, dac_p = by("otir")[0], by("otir")[1]
    psg_w = [w for w in writes if psg_p["pre"] <= w[0] <= psg_p["t0"]]
    psg_w = [w for w in psg_w if w[1] in (0xe0, 0xe1, 0xe2, 0xe3)]
    sequence = [w[2] for w in psg_w]
    c.add("OTIR into the PSG ports: all bytes arrive in order", sequence == [0x9f, 0xbf, 0xdf, 0xff] * 4, f"{len(psg_w)} writes {bytes(sequence).hex()}")
    inner = [b[0] - a[0] for a, b in zip(psg_w, psg_w[1:]) if a[1] == b[1]]
    ok = bool(inner) and all(ready * 0.99 <= d <= ready + 3 * iteration for d in inner)
    c.add("OTIR into one PSG: READY stretch", ok,
          f"{len(inner)} intervals {min(inner) * 1e6:.2f}-{max(inner) * 1e6:.2f} us; 32 PSG clocks = {ready * 1e6:.2f} us, an OTIR iteration {iteration * 1e6:.2f} us")
    dac_w = [w for w in writes if dac_p["pre"] <= w[0] <= dac_p["t0"] and w[1] == 0xe4]
    inner = [b[0] - a[0] for a, b in zip(dac_w, dac_w[1:])]
    c.add("OTIR into the DAC: no stretch", len(dac_w) == 8 and all(abs(d - iteration) < 0.3e-6 for d in inner),
          f"{len(dac_w)} writes, intervals {min(inner) * 1e6:.2f}-{max(inner) * 1e6:.2f} us against {iteration * 1e6:.2f} us")

    # Reads: the idle controller latches (7Fh), no write events, the tone undisturbed.
    scan = next(o for o in other if o[0] == "S")
    c.add("IN over E0h-FFh reads 7Fh (idle latches)", scan[2] == "7F" * 32, f"scan {scan[2]}")
    scan_reads = [r for r in reads if r[0] <= float(scan[1])]
    c.add("reads seen by the bus", len(scan_reads) >= 32 and all(r[2] == 0x7f for r in scan_reads), f"{len(scan_reads)} reads, all 7Fh")
    p = by("reads")[0]
    t_scan = float(scan[1])
    f_before = tone_frequency(audio.window(p["t0"] + 0.05, t_scan - 0.005), audio.rate)
    f_after = tone_frequency(audio.window(t_scan + 0.02, t_scan + 0.1), audio.rate)
    want = expected_frequency(254)
    c.add("reads leave the tone untouched", all(f and abs(f - want) / want < 0.002 for f in (f_before, f_after)),
          f"{f_before:.2f} Hz before, {f_after:.2f} Hz after, {want:.2f} Hz expected")
    writes_in_scan = [w for w in writes if p["t0"] + 0.1 < w[0] < t_scan + 0.1]
    c.add("reads cause no writes", not writes_in_scan, f"{len(writes_in_scan)} writes around the scan")

    # OUT (C),A through the mirrors.
    g = by("guest-out")
    f = tone_frequency(audio.window(*settle(g[0])), audio.rate)
    want = expected_frequency(300)
    c.add("OUT (C),A chip 3 through F3h", f and abs(f - want) / want < 0.002, f"{f:.2f} Hz against {want:.2f} Hz")
    level = audio.window(*settle(g[1], 0.5)).mean()
    want_level = DAC_GAIN * 0.5
    c.add("OUT (C),A DAC through FCh", abs(level - want_level) < 0.0004, f"{level * 32768:.0f} against {want_level * 32768:.0f} LSB")

    # Reset: the DAC register clears, the PSG keeps playing.
    pre = by("pre-reset")[0]
    post = by("post-reset")[0]
    x_pre, x_post = audio.window(*settle(pre, 0.4)), audio.window(*settle(post, 0.4))
    low_pre, low_post = np.percentile(x_pre, 3), np.percentile(x_post, 3)
    f_post = tone_frequency(x_post, audio.rate)
    want = expected_frequency(300)
    c.add("reset clears the DAC register", abs(low_pre - DAC_GAIN * 127 / 128) < 0.0006 and abs(low_post + DAC_GAIN) < 0.0006,
          f"low level {low_pre * 32768:+.0f} LSB before (FFh), {low_post * 32768:+.0f} after (00h = {-DAC_GAIN * 32768:+.0f})")
    c.add("reset leaves the PSG playing", f_post and abs(f_post - want) / want < 0.002, f"{f_post:.2f} Hz after the reset, {want:.2f} Hz expected")
    quiet = by("quiet")
    worst = max(np.abs(audio.window(*settle(q, 0.3))).max() for q in quiet)
    c.add("silence after the silence sequence", worst < 2 / 32768, f"{len(quiet)} quiet phases, largest sample {worst * 32768:.2f} LSB")
    return c, {"latency_s": lat}


def calibrate_guest(audio, writes):
    """The guest run has no cal pulse; align on the first DAC write that raises the level (the
    OTIR into the DAC: 90h)."""
    dac = [w for w in writes if w[1] == 0xe4 and w[2] == 0x90]
    return audio.calibrate(dac[0][0], DAC_GAIN * (0x90 - 128) / 128)


# Probe runners -----------------------------------------------------------------------

def run_probe(mame, case_dir, which):
    case_dir.mkdir(parents=True, exist_ok=True)
    image = assemble(case_dir)
    body = {"bus": "sound-bus", "guest": "sound-guest"}[which]
    deadline = {"bus": 40, "guest": 12}[which]
    wav = case_dir / "audio.wav"
    command = mame_command(mame, image, case_dir, deadline, wav)
    environment = dict(os.environ, HARNESS_CASE=body, HARNESS_SCRIPT=str(HERE / "sound.lua"),
                       HARNESS_DIR=str(case_dir), HARNESS_DEADLINE=str(deadline))
    (case_dir / "manifest.json").write_text(json.dumps({
        "body": body, "command": command, "probe_image": str(image), "probe_sha256": sha(image.read_bytes()),
        "audio": {"rate": RATE, "capture": "-wavwrite with -sound none"},
        "limits": {"emulated_seconds": deadline, "wall_seconds": 300}}, indent=2) + "\n")
    ok, code, log = run_mame(command, environment, 300, case_dir, body)
    info = {"probe_sha256": sha(image.read_bytes())}
    checks = Checks()
    if ok:
        try:
            checks, more = (analyse_bus if which == "bus" else analyse_guest)(wav, case_dir / "events.tsv")
            info.update(more)
            info["wav_sha256"] = sha(wav.read_bytes())
            info["wav_bytes"] = wav.stat().st_size
        except Exception as exc:  # an analysis failure is a failure of the probe, with the reason
            checks.add("analysis", False, f"{type(exc).__name__}: {exc}")
    log += "\n".join(checks.lines()) + "\n"
    (case_dir / "checks.json").write_text(json.dumps(checks.items, indent=2) + "\n")
    return ok and checks.ok and bool(checks.items), code, log, command, info


def run(case, mame, inputs, output, cases=None):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for probe in cases or PROBES[case]:
        case_dir = output / probe
        if case_dir.exists():
            shutil.rmtree(case_dir)
        start = time.monotonic()
        ok, code, log, command, info = run_probe(mame, case_dir, probe)
        wall = time.monotonic() - start
        (output / f"{probe}.log").write_text(log)
        lines = log.splitlines()
        emulated = [float(m) for m in re.findall(r"^TRACE emulated ([0-9.]+) s", log, re.M)]
        results.append({"case": probe, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
                        "emulated_seconds": round(sum(emulated), 6) if emulated else None,
                        "verdict": " / ".join(l for l in lines if re.match(r"(PASS|FAIL|RESULT)( harness)? ", l)) or None,
                        "traces": [l for l in lines if l.startswith(("TRACE ", "CHECK ", "RUN wall", "Average speed"))],
                        "diagnostics": [l for l in lines if l.startswith("DIAG ")],
                        "log": str(output / f"{probe}.log"), "command": command, **info})
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results


# audio-playback -----------------------------------------------------------------------

def make_card(card, files):
    import card_backends
    import fat_fixture as fat
    tree = {"/BIN/": None}
    tree.update(files)
    fat.make_image(card, 16, 16, 4)
    card_backends.fill_image(card, tree)
    return tree


class Psg:
    """One SN76489A's registers as the guest bytes set them (conventional bytes: bit 7 is the
    latch bit, bits 6-4 the register, bits 3-0 the data; a data byte completes a tone)."""

    def __init__(self):
        self.reg = 0
        self.divisor = [0, 0, 0]
        self.attenuation = [15, 15, 15, 15]   # silent until written (the model state, not the chip's)
        self.noise = 0

    def write(self, byte):
        if byte & 0x80:
            self.reg = (byte >> 4) & 7
            value = byte & 15
            if self.reg in (0, 2, 4):
                c = self.reg // 2
                self.divisor[c] = (self.divisor[c] & 0x3f0) | value
            elif self.reg == 6:
                self.noise = value
            else:
                self.attenuation[self.reg // 2] = value
        elif self.reg in (0, 2, 4):
            c = self.reg // 2
            self.divisor[c] = (self.divisor[c] & 15) | ((byte & 0x3f) << 4)
        elif self.reg == 6:
            self.noise = byte & 15
        else:
            self.attenuation[self.reg // 2] = byte & 15

    def tones(self):
        """[(channel, frequency, level)] of the audible tone channels (level before the mix)."""
        out = []
        for c in range(3):
            if self.attenuation[c] < 15:
                n = self.divisor[c] or 0x400
                out.append((c, CLOCK / (32.0 * n), CHANNEL_LEVEL * 10 ** (-self.attenuation[c] / 10)))
        return out

    def noisy(self):
        return self.attenuation[3] < 15


# An event-driven model of the SN76489A fed by the register events ------------------------
#
# Used to render, from the writes a guest made, the waveform the chips should produce
# (ideal square waves on the chip's own count grid, no filtering).  The counting rule is the
# chip datasheet's: a count every 16 clocks; a tone channel toggles when its counter,
# decremented each count, reaches zero and reloads the period; the noise channel shifts its
# register on the same rule.  It is a second statement of the algorithm of sound.py's noise
# model, not MAME's code.  Where the counts fall is the stock device's, because the capture
# is that device's: MAME runs the chip as a stream at the integer rate CLOCK // 2
# (sound.cpp's u32 sample rate: 1,789,772 Hz, 0.28 ppm below CLOCK / 2), counts on stream
# samples 8n + 7 (sn76496.cpp starts its divider at 7 and counts when it reaches 0), and
# applies a write after the stream sample its time falls in (sound_stream::update
# generates samples up to and including the current one first).  With an ideal grid the
# counters drift a count from the chip's within about 20 s, and a tone write whose latch
# and data bytes land on either side of a reload then reloads differently in the two: the
# channel's phase parts for good although every period and level agrees.

STREAM_RATE = CLOCK // 2      # the stock chip's stream: one sample per two clocks
COUNT_SAMPLES = 8             # stream samples per count (16 clocks)
COUNT_PHASE = 7               # the first count's stream sample


def count_index(t):
    """How many counts of the stock chip's grid have run before a write at time `t` takes
    effect (counts at stream samples 8n + 7, n = 0, 1, ...; the write after sample floor(t R))."""
    return (math.floor(t * STREAM_RATE) - COUNT_PHASE) // COUNT_SAMPLES + 1


def count_time(step):
    """The time of count number `step` (1-based, as ChipModel.advance numbers them)."""
    return (COUNT_SAMPLES * (step - 1) + COUNT_PHASE) / STREAM_RATE

NEVER = 10 ** 12


class ChipModel:
    def __init__(self):
        self.reg = [0] * 8
        self.last = 0
        self.period = [0x400, 0x400, 0x400, 0]
        self.count = [0, 0, 0, NEVER]   # the noise period is 0 until set: it then shifts every count (not rendered)
        self.out = [0, 0, 0, 0]
        self.attenuation = [0, 0, 0, 0]
        self.rng = 0x10000
        self.step = 0

    def write(self, byte):
        if byte & 0x80:
            self.last = (byte >> 4) & 7
            self.reg[self.last] = (self.reg[self.last] & 0x3f0) | (byte & 15)
        r = self.last
        if r in (0, 2, 4):
            if not byte & 0x80:
                self.reg[r] = (self.reg[r] & 15) | ((byte & 0x3f) << 4)
            self.period[r // 2] = self.reg[r] or 0x400
            if r == 4 and (self.reg[6] & 3) == 3:
                self.period[3] = self.period[2] * 2
                if self.count[3] > NEVER // 2:
                    self.count[3] = 1
        elif r in (1, 3, 5, 7):
            self.attenuation[r // 2] = byte & 15
            if not byte & 0x80:
                self.reg[r] = (self.reg[r] & 0x3f0) | (byte & 15)
        else:
            if not byte & 0x80:
                self.reg[6] = (self.reg[6] & 0x3f0) | (byte & 15)
            n = self.reg[6]
            self.period[3] = self.period[2] * 2 if (n & 3) == 3 else 1 << (5 + (n & 3))
            self.rng = 0x10000
            if self.count[3] > NEVER // 2:
                self.count[3] = 1

    def level(self, channel):
        a = self.attenuation[channel]
        return 0.0 if a == 15 else CHANNEL_LEVEL * 10 ** (-a / 10)

    def total(self):
        return sum(self.level(c) for c in range(4) if self.out[c])

    def advance(self, target, emit):
        """Run the counts up to step `target`; emit(step) after each toggle."""
        while self.step < target:
            nxt = min(self.step + max(self.count[c], 1) for c in range(4))
            nxt = min(nxt, target)
            delta = nxt - self.step
            self.step = nxt
            for c in range(4):
                self.count[c] -= delta
                if self.count[c] <= 0:
                    if c < 3:
                        self.out[c] ^= 1
                    else:
                        feedback = bool(self.rng & 0x04) != (bool(self.rng & 0x08) and bool(self.reg[6] & 4))
                        self.rng >>= 1
                        if feedback:
                            self.rng |= 0x10000
                        self.out[3] = self.rng & 1
                    self.count[c] = self.period[c]
                    emit(self.step)


def render(writes, t_end):
    """The ideal mono waveform's change list for the writes: [(time, level)] sorted by time,
    chips mixed with the card's gains and the DAC added."""
    chips = [ChipModel() for _ in range(4)]
    parts = [0.0] * 4
    changes = []
    dac_level = 0.0
    events = [(t, p & 7, b) for t, p, b in writes if (p & 7) <= 4]  # in the guest's order

    def mix():
        return sum(PSG_GAIN[k] * parts[k] for k in range(4)) + dac_level

    for t, port, byte in events:
        target = count_index(t)
        for k, chip in enumerate(chips):
            def emit(step, k=k, chip=chip):
                total = chip.total()
                if total != parts[k]:
                    parts[k] = total
                    changes.append((count_time(step), mix()))
            chip.advance(target, emit)
        if port == 4:
            dac_level = DAC_GAIN * (byte - 128) / 128
        else:
            chips[port].write(byte)
            parts[port] = chips[port].total()
        changes.append((t, mix()))
    for k, chip in enumerate(chips):
        def emit(step, k=k, chip=chip):
            total = chip.total()
            if total != parts[k]:
                parts[k] = total
                changes.append((count_time(step), mix()))
        chip.advance(count_index(t_end), emit)
    changes.sort(key=lambda c: c[0])
    return changes


def sample_changes(changes, t0, t1, rate):
    """The change list as samples on the audio grid over [t0, t1)."""
    times = np.array([c[0] for c in changes])
    levels = np.array([c[1] for c in changes])
    grid = t0 + np.arange(int((t1 - t0) * rate)) / rate
    idx = np.searchsorted(times, grid, side="right") - 1
    return np.where(idx >= 0, levels[np.clip(idx, 0, None)], 0.0)


def window_pair(changes, audio, t, span, lag):
    x = audio.window(t, t + span)
    y = sample_changes(changes, t - lag / audio.rate, t + span - lag / audio.rate, audio.rate)
    n = min(len(x), len(y))
    return x[:n], y[:n]


def best_lag(changes, audio, t0, t1, span=0.1, limit=12):
    """The audio's delay against the ideal waveform in samples (the resampler's), the lag that
    maximises the summed correlation over up to 40 active windows spread over [t0, t1]."""
    starts = np.linspace(t0, t1 - span, 40)
    best, best_sum = 0, -1e9
    for lag in range(-limit, limit + 1):
        total = 0.0
        for t in starts:
            x, y = window_pair(changes, audio, t, span, lag)
            if x.std() > 1e-6 and y.std() > 1e-6:
                total += np.corrcoef(x, y)[0, 1]
        if total > best_sum:
            best, best_sum = lag, total
    return best


def compare_playback(writes, audio, t0, t1, span=0.1):
    """Per span-long window: the correlation of the capture with the model's ideal waveform
    and the ratio of their swings, after one global delay.  Returns ([(window start, correlation,
    ratio)], lag in samples)."""
    changes = render(writes, t1 + 0.05)
    lag = best_lag(changes, audio, t0, t1, span)
    out = []
    t = t0
    while t + span <= t1:
        x, y = window_pair(changes, audio, t, span, lag)
        if x.std() > 1e-6 and y.std() > 1e-6:
            out.append((t, float(np.corrcoef(x, y)[0, 1]), float(x.std() / y.std())))
        elif x.std() <= 1e-6 and y.std() <= 1e-6:
            out.append((t, 1.0, 1.0))
        else:
            out.append((t, 0.0, 0.0))
        t += span
    return out, lag


# The clients ---------------------------------------------------------------------------

CLIENTS = ("sndtest", "sntview", "vgmplay")
EXE_INPUTS = {"sndtest": "sndtest", "sntview": "sntview", "vgmplay": "vgmplay"}


def manifest_name(exe):
    """The program's name from its build manifest (exepack's <name>/<name>.json next to the packed
    program), the name it is installed and run under."""
    manifest = exe.parent / exe.stem / (exe.stem + ".json")
    if not manifest.is_file():
        raise FileNotFoundError(f"build manifest {manifest} is missing for {exe}")
    name = json.loads(manifest.read_text())["name"]
    if name != exe.name:
        raise ValueError(f"{manifest} names {name}, not {exe.name}")
    return name


def console_text(transcript):
    return transcript.read_text() if transcript.is_file() else ""


def last_time(marks, name):
    return max(t for t, n in marks if n == name)


def final_state(writes, upto=None):
    chips = [Psg() for _ in range(4)]
    dac = None
    for t, p, b in writes:
        if upto is not None and t > upto:
            break
        if (p & 7) < 4:
            chips[p & 7].write(b)
        elif (p & 7) == 4:
            dac = b
    return chips, dac


def silent_end(c, audio, writes, t_from, t_to, what):
    chips, dac = final_state(writes)
    x = audio.window(t_from, t_to)
    quiet = all(a == 15 for chip in chips for a in chip.attenuation)
    c.add(f"{what}: every voice off and the DAC at 80h", quiet and dac == 0x80,
          f"attenuations {[chip.attenuation for chip in chips]}, last DAC write {dac:02X}" if dac is not None else "no DAC write")
    c.add(f"{what}: no sound after the exit", np.abs(x).max() < 2 / 32768,
          f"largest sample {np.abs(x).max() * 32768:.2f} LSB over {t_to - t_from:.2f} s")


def correlation_check(c, writes, audio, t0, t1, what):
    """Compare the capture with the ideal rendering of the writes: every window correlates at
    0.9 or better with a swing within 3 %."""
    res, lag = compare_playback(writes, audio, t0, t1)
    corr = np.array([r[1] for r in res])
    ratio = np.array([r[2] for r in res if r[1] > 0])
    ok = len(res) > 20 and corr.min() >= 0.9 and ratio.min() >= 0.97 and ratio.max() <= 1.03
    c.add(f"{what}: audio against the registers' ideal waveform", ok,
          f"{len(res)} windows of 0.1 s after a {lag / audio.rate * 1e6:.1f} us delay: correlation min {corr.min():.3f} 5th percentile {np.percentile(corr, 5):.3f} median {np.median(corr):.3f}; swing ratio {ratio.min():.3f}-{ratio.max():.3f}")
    return {"lag_us": lag / audio.rate * 1e6, "windows": len(res), "corr_min": float(corr.min()), "corr_median": float(np.median(corr)),
            "ratio_min": float(ratio.min()), "ratio_max": float(ratio.max())}


def framing(writes, t0, t1):
    """Per chip, the writes in [t0, t1]; chips with no stream see only the driver's and library's own."""
    out = [[] for _ in range(4)]
    for t, p, b in writes:
        if t0 <= t <= t1 and (p & 7) < 4:
            out[p & 7].append(b)
    return out


def note_divisor(note):
    """libsnd's divisor for a note number: round(3579545 / (32 * 440 * 2 ** ((note - 48) / 12))), 1-1023
    (the SDK's A440 table is indexed so that note 48 (SND_A4) sounds 440 Hz and note 39 is SND_C4)."""
    return max(1, min(1023, round(CLOCK / (32.0 * 440.0 * 2 ** ((note - 48) / 12)))))


def analyse_client(client, case_dir, wav):
    c = Checks()
    writes, reads, _, other = read_events(case_dir / "events.tsv")
    marks = [(float(o[1]), o[2]) for o in other if o[0] == "X"]
    audio = Audio(wav)
    text = console_text(case_dir / "transcript.txt")
    info = {}
    t_done = last_time(marks, "done")
    c.add("reads of E0h-FFh", all(r[2] == 0x7f for r in reads), f"{len(reads)} reads, all 7Fh (idle latches)")
    if client == "vgmplay":
        t0, t1 = last_time(marks, "launch"), last_time(marks, "prompt")
        report = re.search(r"Timer events ([0-9A-F]+)\s+ticks ([0-9A-F]+)\s+bytes ([0-9A-F]+)\s+writes ([0-9A-F]+)", text)
        under = re.search(r"Underruns (\d+)\s+missed events (\d+)", text)
        c.add("VGMPlayer report", bool(report and under) and under.group(1) == "0" and under.group(2) == "0",
              (report.group(0) + "; " + under.group(0)) if report and under else "no report on the console")
        per = framing(writes, t0, t1)
        n0, others = len(per[0]), [len(p) for p in per[1:]]
        stream = n0 - others[0]
        c.add("PSG0 writes are the player's and nothing else", report is not None and others[0] == others[1] == others[2]
              and stream == int(report.group(4), 16),
              f"chip 0 took {n0} writes, chips 1-3 {others} (the driver's and library's own); the difference {stream} against the report's {int(report.group(4), 16) if report else '?'}")
        c.add("stream bytes reach only PSG0", all(b in (0x9f, 0xbf, 0xdf, 0xff, 0x80, 0x00, 0xa0, 0xc0, 0xe0) for p in per[1:] for b in p),
              "chips 1-3 saw only the silence and initialisation bytes")
        info["correlation"] = correlation_check(c, writes, audio, t0, t1, "VGMPlayer")
        silent_end(c, audio, writes, last_time(marks, "prompt") + 0.2, t_done, "VGMPlayer")
        info["report"] = report.group(0) if report else None
    elif client == "sntview":
        t0 = last_time(marks, "play")
        pause, resume, quit_ = last_time(marks, "pause"), last_time(marks, "resume"), last_time(marks, "quit")   # the key presses
        stats = re.search(r"sntview: underruns (\d+), overruns (\d+), missed ticks (\d+)", text)
        c.add("sntview report", bool(stats) and stats.group(1) == "0" and stats.group(3) == "0", stats.group(0) if stats else "no report on the console")
        playing = [(t, p, b) for t, p, b in writes if t0 + 0.1 < t < pause - 0.05 and (p & 7) < 4]
        c.add("sound while playing", len(playing) > 200 and np.abs(audio.window(t0 + 1, pause - 0.1)).max() > 0.02,
              f"{len(playing)} PSG writes, peak {np.abs(audio.window(t0 + 1, pause - 0.1)).max():.3f}")
        gap = [(t, p, b) for t, p, b in writes if pause + 0.25 < t < resume - 0.02 and (p & 7) < 4]
        held = audio.window(pause + 0.25, resume - 0.02)
        c.add("pause: no writes, no sound", not gap and np.abs(held).max() < 2 / 32768,
              f"{len(gap)} PSG writes and largest sample {np.abs(held).max() * 32768:.2f} LSB between {pause + 0.25:.2f} s and {resume - 0.02:.2f} s")
        after = [(t, p, b) for t, p, b in writes if resume + 0.2 < t < quit_ and (p & 7) < 4]
        c.add("resume: playing again", len(after) > 50, f"{len(after)} PSG writes after the resume")
        info["correlation"] = correlation_check(c, writes, audio, t0, last_time(marks, "prompt"), "sntview")
        silent_end(c, audio, writes, last_time(marks, "prompt") + 0.2, t_done, "sntview")
        info["report"] = stats.group(0) if stats else None
    else:
        starts = {n[6:]: t for t, n in marks if n.startswith("start ")}
        ends = {n[4:]: t for t, n in marks if n.startswith("end ")}
        # The console lines scroll off; the transcript keeps each mode's screen.
        for want in ("sndtest: tones PASS", "sndtest: adsr PASS", "sndtest: noise PASS", "sndtest: noise busy -4",
                     "sndtest: noise rate3 0", "sndtest: noise tone2 -4", "sndtest: modes PASS", "sndtest: catchup PASS",
                     "sndtest: catchup overruns 34", "sndtest: close PASS", "sndtest: exit PASS", "sndtest: zvg PASS state 5 "):
            c.add(f"console: {want.strip()}", want in text, "in the transcript" if want in text else "missing")
        # tones: the held chord's divisors on each chip before the close.
        t0, t1 = starts["tones"], ends["tones"]
        markers = [t for t, p, b in writes if (p & 7) == 4 and b == 0xa5 and t0 <= t <= t1]
        chips, _ = final_state(writes, markers[-1])
        # sndtest tones holds SND_C4, E4, G4, C5, E5, G5, C6, E6, G6, C7, E7, G7 = notes 39, 43, 46, 51, ...
        notes = [39, 43, 46, 51, 55, 58, 63, 67, 70, 75, 79, 82]
        ok, rows = True, []
        for k, chip in enumerate(chips):
            for ch in range(3):
                want = note_divisor(notes[3 * k + ch])
                good = chip.divisor[ch] == want and chip.attenuation[ch] == 0
                ok = ok and good
                rows.append(f"{k}.{ch}:{chip.divisor[ch]}/{want}")
        c.add("tones: twelve notes on the four chips (divisor/expected, attenuation 0)", ok and len(markers) == 6, " ".join(rows) + f"; {len(markers)} markers")
        # noise: the control bytes sndtest's noise mode writes to chip 0: periodic rate 1 twice (the forced
        # rewrite) then white rate 3.
        n0, n1 = starts["noise"], ends["noise"]
        ctl = [b for t, p, b in writes if n0 <= t <= n1 and (p & 7) == 0 and 0xe0 <= b <= 0xe7]
        c.add("noise: control bytes E1 E1 E7 (the second E1 is the forced retrigger)", ctl[:3] == [0xe1, 0xe1, 0xe7] if ctl else False, f"control writes {[hex(b) for b in ctl]}")
        # zvg: the player's writes against its report.
        z0, z1 = starts["zvg " + "/fs/WRAPS.ZVG 0"], ends["zvg " + "/fs/WRAPS.ZVG 0"]
        report = re.search(r"sndtest: zvg PASS state (\d+) events (\d+) ticks (\d+) writes (\d+)", text)
        per = framing(writes, z0, z1)
        stream = len(per[0]) - len(per[1])
        c.add("zvg: PSG0 writes are the stream's", report is not None and stream == int(report.group(4)) and len(per[1]) == len(per[2]) == len(per[3]),
              f"chip 0 {len(per[0])} writes, chips 1-3 {[len(p) for p in per[1:]]}; the difference {stream} against the report's {report.group(4) if report else '?'}")
        info["correlation"] = correlation_check(c, writes, audio, z0, z1, "sndtest zvg")
        silent_end(c, audio, writes, ends["zvg " + "/fs/WRAPS.ZVG 0"] + 0.2, t_done, "sndtest")
        info["zvg_report"] = report.group(0) if report else None
    # the boot's power-on state: the PSGs sound until the driver silences them
    first_silence = min(t for t, p, b in writes if (p & 7) < 4 and b == 0x9f)
    boot = audio.window(0.1, first_silence - 0.01)
    info["power_on"] = {"silenced_at_s": first_silence, "peak_before": float(np.abs(boot).max()) if len(boot) else 0.0}
    return c, info


def run_client(mame, inputs, case_dir, client):
    case_dir.mkdir(parents=True, exist_ok=True)
    exes = {n: inputs[EXE_INPUTS[n]] for n in CLIENTS}
    names = {n: manifest_name(p) for n, p in exes.items()}
    tree = {f"/BIN/{names[n].upper()}": p.read_bytes() for n, p in exes.items()}
    tree["/NIGHT.ZTR"] = inputs["ztr"].read_bytes()
    tree["/NIGHT.ZVG"] = inputs["zvg"].read_bytes()
    tree["/WRAPS.ZVG"] = inputs["wraps"].read_bytes()
    card = case_dir / "card.img"
    make_card(card, tree)
    import guest_font
    font = case_dir / "font.bin"
    guest_font.write("konaos", inputs["konaos"], font)
    body = f"playback-{client}"
    deadline = {"sndtest": 100, "sntview": 70, "vgmplay": 50}[client]
    wav = case_dir / "audio.wav"
    command = mame_command(mame, inputs["konaos"], case_dir, deadline, wav, extra=("-card", str(card)))
    program = lambda n: names[n][:-4]
    environment = dict(os.environ, HARNESS_CASE=body, HARNESS_SCRIPT=str(HERE / "sound.lua"), HARNESS_DIR=str(case_dir),
                       HARNESS_DEADLINE=str(deadline), HARNESS_FONT=str(font), HARNESS_SNDTEST=program("sndtest"),
                       HARNESS_SNTVIEW=program("sntview"), HARNESS_VGMPLAY=program("vgmplay"), HARNESS_ZTR="/fs/NIGHT.ZTR",
                       HARNESS_ZVG="/fs/NIGHT.ZVG", HARNESS_WRAPS="/fs/WRAPS.ZVG")
    media = {"card": str(card), "files": {k: {"bytes": len(v), "sha256": sha(v)} for k, v in tree.items()}}
    (case_dir / "manifest.json").write_text(json.dumps({
        "body": body, "command": command, "programs": names, "media": media,
        "assets": {"/NIGHT.ZTR": str(inputs["ztr"]), "/NIGHT.ZVG": str(inputs["zvg"]), "/WRAPS.ZVG": str(inputs["wraps"])},
        "audio": {"rate": RATE, "capture": "-wavwrite with -sound none"},
        "limits": {"emulated_seconds": deadline, "wall_seconds": 400}}, indent=2) + "\n")
    ok, code, log = run_mame(command, environment, 400, case_dir, body)
    info = {"programs": names, "media": media["files"]}
    checks = Checks()
    if ok:
        try:
            checks, more = analyse_client(client, case_dir, wav)
            info.update(more)
            info["wav_sha256"] = sha(wav.read_bytes())
            info["wav_bytes"] = wav.stat().st_size
        except Exception as exc:
            import traceback
            checks.add("analysis", False, f"{type(exc).__name__}: {exc}\n{traceback.format_exc()}")
    log += "\n".join(checks.lines()) + "\n"
    (case_dir / "checks.json").write_text(json.dumps(checks.items, indent=2) + "\n")
    return ok and checks.ok and bool(checks.items), code, log, command, info


def run_playback(case, mame, inputs, output, cases=None):
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for client in cases or CLIENTS:
        case_dir = output / client
        if case_dir.exists():
            shutil.rmtree(case_dir)
        start = time.monotonic()
        ok, code, log, command, info = run_client(mame, inputs, case_dir, client)
        wall = time.monotonic() - start
        (output / f"{client}.log").write_text(log)
        lines = log.splitlines()
        emulated = [float(m) for m in re.findall(r"^TRACE emulated ([0-9.]+) s", log, re.M)]
        results.append({"case": client, "pass": ok, "exit": code, "wall_seconds": round(wall, 3),
                        "emulated_seconds": round(sum(emulated), 6) if emulated else None,
                        "verdict": " / ".join(l for l in lines if re.match(r"(PASS|FAIL|RESULT)( harness)? ", l)) or None,
                        "traces": [l for l in lines if l.startswith(("TRACE ", "CHECK ", "RUN wall", "Average speed"))],
                        "diagnostics": [l for l in lines if l.startswith("DIAG ")],
                        "log": str(output / f"{client}.log"), "command": command, **info})
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return results
