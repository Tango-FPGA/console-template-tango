#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""vproc_audio.py -- the Template's Audio test (rtl/tango_core_template.v audio_test(): a +-8192 square) through the
framework's audio filter (sys/tango_audio_filter.v: MiSTer's IIR at the file's rate, the 48 kHz hand-over, the DC
blocker), modelled with sys/build_tools/iir_model.py on the RTL's own schedule, against an HDMI audio capture of the
board (the capture card's ALSA device: 48 kHz, S16_LE, stereo).

  vproc_audio.py model --tone 440 [--afilter <file>] [--secs 0.6] --out <model.wav>
  vproc_audio.py compare <capture.wav> --tone 440 [--afilter <file>] [--ref <capture.wav> --ref-afilter <file|->]
                 [--plot <spectrum.png>] [--json <out.json>]
    --afilter: the Filters_Audio file the build loaded (sys/build_tools/vproc_preset.py --afilter), relative to
               <filters>/Filters_Audio; absent or '-': nothing loaded = the filter's power-up coefficients
               (MiSTer's built-in ones)
    compare: (1) the capture against the model in time over two tone periods (the model's steady state, aligned by
             cross-correlation, the tone's phase against the 48 kHz strobes searched to a clock; one gain fitted:
             the capture card's level is not the HDMI stream's); (2) the level of each odd harmonic of the tone as
             the energy within 40 Hz of it, capture vs model (at the fitted gain); with --ref, the same for a
             second capture (e.g. the filter not loaded) and the change per harmonic, capture vs model (the
             filter's effect on silicon; the gains cancel).  A typical USB capture card is not
             sample-exact: about -6.6 dB, L and R 0.6 % apart, and its own 48 kHz clock 1600 ppm off the HDMI
             stream's, resampled, so lines move by a few Hz and a time-domain fit drifts after a few periods.
  vproc_audio.py mix <capture.wav> --tone 440 [--afilter <file>] [--volume <byte>] [--audvol <byte>] [--stereo-mix <0-3>]
                 [--left-only] [--plot <png>] [--json <out.json>]
    MiSTer's mix stage (iir_model.Mix: aud_mix_top, audio_out.sv 281-345) after the filter: the core volume byte of 0x39
    ({boost[6:5], att[4:0]}), the global volume (0x26), the core's Stereo Mix; --left-only: the Template's Audio test
    value 5 (the tone on AUDIO_L, AUDIO_R silent).  Both channels' odd harmonics against the model's at one fitted gain,
    and the level of the right channel against the left at the fundamental (the cross-feed).
    PASS (mix): both channels' harmonics above -70 dBFS within 1.5 dB, the R / L ratio within 0.5 dB.
  vproc_audio.py cycle <capture.wav> --tone 440 [--json <out.json>]
    A build with vproc_preset.py --afilter <file> --afilter-cycle A,B (the in-core OSD's Custom <-> Internal toggling
    on a loop; every load mutes 8192 samples, so with A < 171 ms only the Internal stretches sound): each audible
    stretch on its own -- the share of its energy within 40 Hz of the tone's odd harmonics (the filtered tone: the
    power-up filter is flat to 15 kHz), and its strongest line.  PASS: every stretch's share >= 0.9 (an IIR left in a
    previous filter's state oscillates: seen as a 9.6 kHz limit cycle with the tone as sidebands).
    PASS: every odd harmonic above -70 dBFS within 1.5 dB of the model at the fitted gain, and with --ref, every
          change between the two captures within 1 dB of the model's (harmonics above -70 dBFS in both).  The
          time-domain residual is reported, not judged: this bench's card is neither sample-exact nor on the HDMI
          stream's clock.
"""
import argparse, json, os, sys, wave
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.join(HERE, '..', 'sys', 'build_tools'), os.path.join(HERE, '..', '..', 'sys', 'build_tools')):
    sys.path.insert(0, _p)                   # this repository's sys/ (submodule), or one level up
import iir_model as IM
import vproc_preset as VP

CLK = 74_250_000
HALF = {1000: 37125, 440: 84375}            # half-period counters of audio_test (rtl/tango_core_template.v)
LAT = 4                                      # a step's output reaches y_l 4 clocks after the step (tango_audio_filter S1..S5)
DEFAULTS = dict(rate=7056000, cx=4258969, cx0=3, cx1=3, cx2=1, cy0=-6216759, cy1=6143386, cy2=-2023767)

def coeffs_for(afilter, root, volume=0):
    """what tango_vproc_regs holds after the transfers vproc_preset.py makes for this file (or its power-up values)"""
    if (not afilter or afilter == '-') and not volume:
        return dict(DEFAULTS), 'power-up coefficients (nothing loaded)'
    cfg = {'volume': volume}
    if afilter and afilter != '-':
        cfg['afilter'] = afilter
        if not root:
            sys.exit('vproc_audio.py: --root (or FILTERS): the folder of MiSTer\'s filter files, for ' + afilter)
    xs, _ = VP.transfers(cfg, root, 0)
    t = [x for x in xs if len(x) >= 3 and x[1] == 0x39][-1]
    d = t[2:]
    c = dict(DEFAULTS); att = d[0] & 31
    def be(a, b):
        v = 0
        for q in d[a:b]: v = (v << 8) | q
        return v
    n = len(d)
    if n >= 5: c['rate'] = be(1, 5)
    if n >= 10: c['cx'] = be(5, 10)
    if n >= 11: c['cx0'] = d[10]
    if n >= 12: c['cx1'] = d[11]
    if n >= 13: c['cx2'] = d[12]
    for i, k in enumerate(('cy0', 'cy1', 'cy2')):
        if n >= 16 + 3 * i: c[k] = IM.s(be(13 + 3 * i, 16 + 3 * i), 24)
    c['cx'] = (c['cx'] & ((1 << 40) - 1)) >> att
    return c, (afilter if afilter and afilter != '-' else 'the power-up filter') + (', core volume 0x%02X' % volume if volume else '')

def steps(tone, c, secs):
    """the filter's steps: the clock of each (the accumulator wraps), and the IIR's output after it (one channel:
    AUDIO_L = AUDIO_R); the square starts low at clock 0"""
    rate = min(c['rate'], 7_425_000)
    half = HALF[tone]
    nsteps = int(secs * rate)
    k = np.arange(1, nsteps + 1, dtype=np.int64)
    cl = (k * CLK + rate - 1) // rate
    inp = np.where(((cl // half) & 1) == 1, 0x2000, 0xE000)
    iir = IM.IIR(c['cx'], c['cx0'], c['cx1'], c['cx2'], c['cy0'] & 0xFFFFFF, c['cy1'] & 0xFFFFFF, c['cy2'] & 0xFFFFFF)
    step = iir.step
    y = np.empty(nsteps, dtype=np.int64)
    for i, v in enumerate(inp.tolist()):
        y[i] = step(0, v)
    return cl, y

def outputs(cl, y, shift, j0, n):
    """the HDMI-side samples j0 .. j0+n-1 (48 kHz strobes at (j*12375+7)//8, each taking the latest IIR output, the DC
    blocker one strobe later), with the square shifted by <shift> clocks against the strobes (the board's phase
    between the core's tone and the framework's 48 kHz is whatever its reset gave)"""
    j = np.arange(j0 - 1, j0 + n, dtype=np.int64)
    d = (j * 12375 + 7) // 8 - shift
    idx = np.searchsorted(cl + LAT, d, side='right') - 1
    h = np.where(idx >= 0, y[np.clip(idx, 0, None)], 0)
    dc = IM.DC(); out = np.empty(n, dtype=np.int64)
    pre = np.arange(max(1, j0 - 24000), j0 - 1, dtype=np.int64)       # 0.5 s of the blocker's own settling first
    dp = (pre * 12375 + 7) // 8 - shift
    ip = np.searchsorted(cl + LAT, dp, side='right') - 1
    for v in np.where(ip >= 0, y[np.clip(ip, 0, None)], 0).tolist():
        dc.step(v)
    hl = h.tolist()
    for i in range(n):
        out[i] = IM.s(dc.step(hl[i]), 16)
    return out

def read_wav(path):
    w = wave.open(path)
    assert w.getsampwidth() == 2, 'S16 only'
    a = np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.int64)
    ch = w.getnchannels()
    a = a.reshape(-1, ch)
    return a, w.getframerate()

def write_wav(path, x):
    w = wave.open(path, 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
    s = np.clip(x, -32768, 32767).astype('<i2')
    w.writeframes(np.stack([s, s], axis=1).tobytes()); w.close()

def harmonics(x, tone, fs=48000, f0=None):
    """the level (dBFS) of each odd harmonic m of the tone: the energy within +-40 Hz of m * tone (Hann window, power
    summed: a capture card that resamples smears and shifts a line by a few Hz, which a single bin misses)"""
    n = len(x)
    win = np.hanning(n)
    X = np.fft.rfft(x * win)
    p = np.abs(X) ** 2 / (np.sum(win ** 2) * n / 2) / (32768.0 ** 2) * 2          # sine of amplitude A -> A^2/2 / FS^2 ... per bin
    f = np.fft.rfftfreq(n, 1 / fs)
    out = []
    for m in range(1, 200, 2):
        fh = tone * m
        if fh > 21000: break
        sel = (f >= fh - 40) & (f <= fh + 40)
        e = p[sel].sum()                                   # = (A / FS)^2 for a sine of amplitude A
        out.append((fh, 10 * np.log10(max(e, 1e-24))))
    sp = np.abs(X) / (win.sum() / 2) / 32768.0
    return out, f, 20 * np.log10(np.maximum(sp, 1e-12))

def tone_freq(x, tone, fs=48000, blk=4800):
    """the tone's frequency in the capture's own samples: the phase of the fundamental per block, its slope"""
    t = np.arange(len(x)) / fs; ph = []
    for k in range(0, len(x) - blk, blk):
        seg = x[k:k + blk] - x[k:k + blk].mean(); tt = t[k:k + blk]
        A = np.vstack([np.sin(2 * np.pi * tone * tt), np.cos(2 * np.pi * tone * tt)]).T
        sol, *_ = np.linalg.lstsq(A, seg, rcond=None); ph.append(np.arctan2(sol[1], sol[0]))
    ph = np.unwrap(np.array(ph))
    return tone + np.polyfit(np.arange(len(ph)) * blk / fs, ph, 1)[0] / (2 * np.pi)

def align(cap, period):
    """best circular alignment of one model period inside the capture (cross-correlation over 4 periods)"""
    n = len(period)
    seg = cap[:4 * n]
    ref = np.tile(period, 4)
    best = None
    F = np.fft.rfft(seg.astype(float)); G = np.fft.rfft(ref.astype(float))
    cc = np.fft.irfft(F * np.conj(G), len(seg))
    sh = int(np.argmax(cc[:n]))
    return sh

def plot(curves, marks, path, title):
    from PIL import Image, ImageDraw
    W, H, L, B, T = 1100, 520, 60, 40, 30
    im = Image.new('RGB', (W, H), 'white'); d = ImageDraw.Draw(im)
    fl, fh, dl, dh = 100.0, 24000.0, -110.0, 0.0
    X = lambda f: L + (W - L - 20) * (np.log10(f) - np.log10(fl)) / (np.log10(fh) - np.log10(fl))
    Y = lambda v: T + (H - B - T) * (dh - min(max(v, dl), dh)) / (dh - dl)
    d.rectangle([L, T, W - 20, H - B], outline='black'); d.text((L, 8), title, fill='black')
    for v in range(-100, 1, 20):
        d.line([(L, Y(v)), (W - 20, Y(v))], fill=(225, 225, 225)); d.text((8, Y(v) - 6), '%d dB' % v, fill='black')
    for f in (100, 200, 500, 1000, 2000, 5000, 10000, 20000):
        d.line([(X(f), T), (X(f), H - B)], fill=(225, 225, 225)); d.text((X(f) - 10, H - B + 6), '%g' % (f / 1000) + 'k', fill='black')
    for i, (lab, col, f, s) in enumerate(curves):            # the envelope: the highest bin in each pixel column
        m = (f >= fl) & (f <= fh)
        xs = np.floor(X(f[m])).astype(int); vs = s[m]
        top = {}
        for xx, vv in zip(xs.tolist(), vs.tolist()):
            if vv > top.get(xx, -1e9): top[xx] = vv
        pts = [(xx + 0.5 * i, Y(top[xx])) for xx in sorted(top)]
        d.line(pts, fill=col, width=1)
        d.text((W - 380, T + 6 + 14 * i), lab, fill=col)
    for lab, col, hs in marks:
        for fq, v in hs:
            x, y = X(fq), Y(v); d.ellipse([x - 3, y - 3, x + 3, y + 3], outline=col)
    im.save(path)

def mix_main(a):
    c, what = coeffs_for(a.afilter, a.root, a.volume)
    boost = (a.volume >> 5) & 3
    print('vproc_audio: %d Hz square%s, filter %s; boost %d, global volume 0x%02X, Stereo Mix %d'
          % (a.tone, ' on the left only' if a.left_only else '', what, boost, a.audvol, a.stereo_mix))
    cl, y = steps(a.tone, c, a.secs)
    n = 48000 * 2 // 5                                                     # 0.4 s of steady state
    j0 = int(a.secs * 48000) - n - 64
    dcl = outputs(cl, y, 0, j0, n + 64)
    dcr = np.zeros_like(dcl) if a.left_only else dcl.copy()
    mx = IM.Mix(); ol, orr = [], []
    prev = [0, 0]
    for l, r in zip(dcl.tolist(), dcr.tolist()):
        o = mx.step(prev, a.audvol, boost, a.stereo_mix)                   # the stages read the sample before
        ol.append(IM.s(o[0], 16)); orr.append(IM.s(o[1], 16)); prev = [l & 0xFFFF, r & 0xFFFF]
    ml = np.array(ol[64:], dtype=float); mr = np.array(orr[64:], dtype=float)
    per = int(round(48000 * (11 if a.tone == 440 else 1) / a.tone))
    reps = 48000 * 4 // per
    ml = np.tile(ml[-per:], reps); mr = np.tile(mr[-per:], reps)
    cap, fs = read_wav(a.wav)
    assert fs == 48000 and cap.shape[1] == 2
    L = cap[len(cap) // 4:, 0].astype(float); R = cap[len(cap) // 4:, 1].astype(float)
    n4 = min(len(L), 48000 * 4) // per * per
    hl, fl_, sl = harmonics(L[:n4], a.tone); hr, fr_, sr = harmonics(R[:n4], a.tone)
    ml_h, fm, sml = harmonics(ml, a.tone); mr_h, _, smr = harmonics(mr, a.tone)
    gdb = hl[0][1] - ml_h[0][1]                                             # one gain: the card's, from L's fundamental
    worst = 0.0; rows = []
    for (f, cl_), (_, cr_), (_, ml_), (_, mr_) in zip(hl, hr, ml_h, mr_h):
        for cv, mv in ((cl_, ml_ + gdb), (cr_, mr_ + gdb)):
            if mv > -70: worst = max(worst, abs(cv - mv))
        rows.append(dict(f=f, capture_l=round(float(cl_), 2), model_l=round(float(ml_ + gdb), 2),
                         capture_r=round(float(cr_), 2), model_r=round(float(mr_ + gdb), 2)))
    rc, rm = hr[0][1] - hl[0][1], mr_h[0][1] - ml_h[0][1]
    print('vproc_audio: the card\'s gain %.2f dB (fitted on the left fundamental)' % gdb)
    for r in rows[:8]:
        print('   %6d Hz  L capture %7.2f model %7.2f   R capture %7.2f model %7.2f dBFS'
              % (r['f'], r['capture_l'], r['model_l'], r['capture_r'], r['model_r']))
    print('vproc_audio: right / left at %d Hz: %.2f dB on silicon, %.2f dB in the model; harmonics above -70 dBFS within %.2f dB'
          % (a.tone, rc, rm, worst))
    ok = worst <= 1.5 and abs(rc - rm) <= 0.5
    if a.plot:
        plot([('capture L', (0, 0, 200), fl_, sl), ('capture R', (0, 150, 0), fr_, sr), ('model L', (230, 120, 0), fm, sml + gdb),
              ('model R', (160, 0, 160), fm, smr + gdb)], [('L', (0, 0, 200), hl), ('R', (0, 150, 0), hr)], a.plot,
             'Template %d Hz %s through the mix stage (boost %d, att 0x%02X, Stereo Mix %d): capture vs model'
             % (a.tone, 'left-only square' if a.left_only else 'square', boost, a.audvol, a.stereo_mix))
    if a.json:
        json.dump(dict(gain_db=round(gdb, 2), r_over_l=dict(capture=round(rc, 2), model=round(rm, 2)), worst_db=round(worst, 2),
                       harmonics=rows, boost=boost, audvol=a.audvol, stereo_mix=a.stereo_mix), open(a.json, 'w'), indent=1)
    print('vproc_audio: %s' % ('PASS' if ok else 'FAIL'))
    sys.exit(0 if ok else 1)

def cycle_main(a):
    """the audible stretches of an --afilter-cycle capture, each judged on its own"""
    x, fs = read_wav(a.wav)
    left = x[:, 0].astype(float)
    win = int(fs * 0.005)
    nb = len(left) // win
    rms = np.sqrt((left[:nb * win].reshape(nb, win) ** 2).mean(axis=1))
    on = rms > max(30.0, 0.05 * np.percentile(rms, 99))
    runs = []; k = 0
    while k < nb:
        if on[k]:
            j = k
            while j < nb and on[j]: j += 1
            if j - k >= 12: runs.append((k + 2, j - 2))          # >= 60 ms; 10 ms trimmed at each end
            k = j
        else: k += 1
    out = []; ok = True
    for i, (k0, k1) in enumerate(runs):
        seg = left[k0 * win:k1 * win]; seg = seg - seg.mean()
        w = np.hanning(len(seg)); X = np.abs(np.fft.rfft(seg * w)) ** 2; f = np.fft.rfftfreq(len(seg), 1 / fs)
        tot = X[f > 20].sum()
        harm = sum(X[(f >= a.tone * m - 40) & (f <= a.tone * m + 40)].sum() for m in range(1, 200, 2) if a.tone * m < 21000)
        share = harm / tot if tot > 0 else 0.0
        top = f[np.argmax(X * (f > 20))]
        good = bool(share >= 0.9); ok = ok and good
        out.append(dict(start_s=round(k0 * win / fs, 3), ms=round((k1 - k0) * win * 1000 / fs), rms=round(float(np.sqrt((seg ** 2).mean()))),
                        share=round(float(share), 4), top_hz=round(float(top), 1), ok=bool(good)))
        print('stretch %2d at %6.3f s, %4d ms: rms %6.0f, tone-harmonic share %.3f, strongest line %7.1f Hz  %s'
              % (i, k0 * win / fs, (k1 - k0) * win * 1000 / fs, np.sqrt((seg ** 2).mean()), share, top, 'ok' if good else 'NOT THE TONE'))
    if not runs:
        ok = False; print('vproc_audio: no audible stretch found')
    print('vproc_audio: %s  %d stretches, %d not the tone' % ('PASS' if ok else 'FAIL', len(runs), sum(1 for o in out if not o['ok'])))
    if a.json:
        json.dump(dict(stretches=out, ok=ok), open(a.json, 'w'), indent=1)
    return 0 if ok else 1

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=('model', 'compare', 'mix', 'cycle')); ap.add_argument('wav', nargs='?')
    ap.add_argument('--volume', type=lambda v: int(v, 0), default=0); ap.add_argument('--audvol', type=lambda v: int(v, 0), default=0)
    ap.add_argument('--stereo-mix', type=int, default=0); ap.add_argument('--left-only', action='store_true')
    ap.add_argument('--tone', type=int, default=440); ap.add_argument('--afilter')
    ap.add_argument('--root', default=os.environ.get('FILTERS'))   # MiSTer's filter files (sim/run_vproc_gates.sh FILTERS)
    ap.add_argument('--secs', type=float, default=0.6); ap.add_argument('--out')
    ap.add_argument('--ref'); ap.add_argument('--ref-afilter'); ap.add_argument('--plot'); ap.add_argument('--json')
    a = ap.parse_args()
    if a.cmd == 'mix':
        return mix_main(a)
    if a.cmd == 'cycle':
        return cycle_main(a)
    c, what = coeffs_for(a.afilter, a.root)
    print('vproc_audio: %d Hz square, filter %s: rate %d cx %d cx0-2 %d %d %d cy %d %d %d'
          % (a.tone, what, c['rate'], c['cx'], c['cx0'], c['cx1'], c['cx2'], c['cy0'], c['cy1'], c['cy2']))
    cl, y = steps(a.tone, c, a.secs)
    per = int(round(48000 * (11 if a.tone == 440 else 1) / a.tone))       # 1200 samples = 11 periods of 440 Hz
    j0 = int(a.secs * 48000) - 2 * per                                      # the steady state: the last 2 periods
    if a.cmd == 'model':
        write_wav(a.out, outputs(cl, y, 0, 1, int(a.secs * 48000) - 1)); print('wrote', a.out); return
    cap, fs = read_wav(a.wav)
    assert fs == 48000
    L = cap[:, 0]
    same_lr = bool(np.array_equal(cap[:, 0], cap[:, 1])) if cap.shape[1] > 1 else True
    L = L[len(L) // 4:]                                                    # past the start of the recording
    # the capture card's sample clock is not the HDMI stream's (this bench's card: the 440 Hz tone at 440.72 Hz, so
    # 0.16 % slow): measure it on the tone and resample back to the stream's 48 kHz before comparing
    f0 = tone_freq(L.astype(float), a.tone)
    print('vproc_audio: the tone is at %.3f Hz in the capture: the card\'s sample clock is %.0f ppm off the HDMI stream\'s '
          '(it resamples: harmonics are measured as the energy within 40 Hz; the time-domain fit runs over 2 tone periods)'
          % (f0, (f0 / a.tone - 1) * 1e6))
    TW = int(2 * 48000 / a.tone)                                           # 2 tone periods
    def err(seg, ref):
        g = float(seg.astype(float) @ ref.astype(float)) / max(float(ref.astype(float) @ ref.astype(float)), 1e-9)
        return float(((seg - g * ref) ** 2).mean()), g
    best = None
    for shift in range(0, 1547, 11):                                        # one 48 kHz sample = 1546.875 clocks
        st = outputs(cl, y, shift, j0, per)
        sh = align(L, st)
        seg = L[sh:sh + TW]; ref = np.tile(st, 8)[:len(seg)]
        e, g = err(seg, ref)
        if best is None or e < best[0]:
            best = (e, shift, sh, st)
    e, shift, sh, steady = best
    for s2 in range(max(0, shift - 10), shift + 11):                        # refine to one clock
        st = outputs(cl, y, s2, j0, per)
        seg = L[sh:sh + TW]; ref = np.tile(st, 8)[:len(seg)]
        e2, _ = err(seg, ref)
        if e2 < e: e, shift, steady = e2, s2, st
    seg = L[sh:sh + TW]; ref = np.tile(steady, 8)[:len(seg)]
    _, gain = err(seg, ref)
    res = seg - ref
    resg = seg - gain * ref
    snr = 10 * np.log10((gain * gain * (ref.astype(float) ** 2).mean()) / max((resg ** 2).mean(), 1e-9))
    eq = int((res == 0).sum())
    print('vproc_audio: L == R in the capture: %s; time domain (tone shifted %d clocks, aligned at sample %d): gain %.4f '
          '(%.2f dB), residual %.1f dB below the signal; at gain 1: %d of %d samples equal, max |diff| %d'
          % (same_lr, shift, sh, gain, 20 * np.log10(max(gain, 1e-9)), snr, eq, len(seg), int(np.abs(res).max())))
    gdb = 20 * np.log10(max(gain, 1e-9))
    hc, f, sc = harmonics(L[:len(L) // per * per][:48000 * 4], a.tone, f0=f0)
    hm, fm, sm = harmonics(np.tile(steady, 48000 * 4 // per), a.tone)
    worst = 0.0; rows = []
    for (fq, vc), (_, vm) in zip(hc, hm):
        if vm + gdb > -70:
            worst = max(worst, abs(vc - (vm + gdb)))
        rows.append(dict(f=fq, capture=round(float(vc), 2), model=round(float(vm + gdb), 2)))
    print('vproc_audio: odd harmonics above -70 dBFS: capture vs model (at the fitted gain) within %.2f dB' % worst)
    for r in rows[:12]:
        print('   %6d Hz  capture %7.2f dBFS  model %7.2f dBFS' % (r['f'], r['capture'], r['model']))
    ok = worst <= 1.5
    curves = [('capture (%s)' % what, (0, 0, 200), f, sc), ('model (at the fitted gain)', (230, 120, 0), fm, sm + gdb)]
    marks = [('capture', (0, 0, 200), hc)]
    out = dict(filter=what, coeffs=c, gain=round(gain, 5), snr_db=round(float(snr), 2), equal=eq, n=len(seg), harmonics=rows, worst_db=round(worst, 2))
    if a.ref:
        c2, what2 = coeffs_for(a.ref_afilter, a.root)
        cl2, y2 = steps(a.tone, c2, a.secs); st2 = outputs(cl2, y2, 0, j0, per)
        cap2, _ = read_wav(a.ref); L2 = cap2[:, 0][len(cap2) // 4:]
        f02 = tone_freq(L2.astype(float), a.tone)
        h2, f2, s2 = harmonics(L2[:len(L2) // per * per][:48000 * 4], a.tone, f0=f02)
        hm2, _, _ = harmonics(np.tile(st2, 48000 * 4 // per), a.tone)
        print('vproc_audio: the filter on silicon: change per harmonic (%s vs %s), capture vs model' % (what, what2))
        w2 = 0.0; delta = []
        for (fq, vc), (_, vm), (_, rc), (_, rm) in zip(hc, hm, h2, hm2):
            dc_, dm = vc - rc, vm - rm
            if vm + gdb > -70 and rm + gdb > -70: w2 = max(w2, abs(dc_ - dm))
            delta.append(dict(f=fq, capture=round(float(dc_), 2), model=round(float(dm), 2)))
        for r in delta[:12]:
            print('   %6d Hz  %7.2f dB on silicon, %7.2f dB in the model' % (r['f'], r['capture'], r['model']))
        print('vproc_audio: change per harmonic, silicon vs model: within %.2f dB' % w2)
        out['ref'] = dict(filter=what2, delta=delta, worst_db=round(w2, 2))
        curves.insert(1, ('capture (%s)' % what2, (0, 150, 0), f2, s2))
        marks.append(('ref', (0, 150, 0), h2))
        ok = ok and w2 <= 1.0
    if a.plot:
        plot(curves, marks, a.plot, 'Template Audio test %d Hz square through the audio filter: HDMI capture vs model' % a.tone)
    if a.json:
        json.dump(out, open(a.json, 'w'), indent=1)
    print('vproc_audio: %s' % ('PASS' if ok else 'FAIL'))
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    sys.exit(main())
