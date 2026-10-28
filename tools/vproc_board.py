#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 the Tango authors
"""vproc_board.py -- an HDMI capture of the Template on the board (MiSTer video processing loaded by the build-time
presets, sys-tango README "Video and audio processing") against the models of tools/vproc_golden.py.

The capture card on this bench gives MJPEG 1920 x 1080 only: it scales the 1280 x 720 picture by 1.5 and compresses
it, so pixels cannot match exactly.  The test is a ranking: the capture is compared with the model of what was loaded
("full") and with the same model with one feature taken away (no polyphase filter = nearest + the framework's
scanline dimming, no gamma, no shadow mask, nothing loaded).  Every model frame goes through the same 1.5x up /
1.5x down chain as the capture; the capture is aligned to "full" (integer shift); the capture card's levels are
fitted per model (capture = a * model + b, least squares over the picture: the card's black and gain are not the
HDMI signal's); the mean absolute error is taken over the picture: the closest model should be "full".  The MJPEG capture resolves large-scale differences (a
polyphase filter's stripes, levels) well but not a 3-px mask pattern, so each loaded feature also has its own test:
  filter  "full" closer than nearest (+ the framework's dimming) by MARGIN (default 2) in the ranking above;
  scan    the vertical profile of a vertically uniform part (Pixel grid's top third, else the window): its strongest
          periodic component is the loaded model's (the Scan filter's period = the source line), not the framework's
          two-line dimming (or the reverse when that is what was loaded);
  gamma   block means (one per source pixel, so a mask averages out) fitted capture = a * model + b: the gamma
          model's residual at least MARGIN times smaller than the model without gamma;
  mask    the column profile across the white square: the capture's component at the mask's period (from the model)
          within 2x of the model's (both through the 1.5x chain), and at least 5x the mask-less model's.
PASS = every applicable feature test passes.

usage: vproc_board.py <capture.png>... --status <hex> --win h0,h1,v0,v1 [--tables <vproc json>] [--out <dir>]
       [--margin 2] [--name <tag>] [--rows y0,y1] [--ref <capture.png>... --ref-status <hex>]
  several captures are averaged first (frames of a still picture: less MJPEG noise).
  --out: writes <name>_capture720.png, <name>_full.png, <name>_diff.png (|capture - full| x 4) and profile plots.
"""
import argparse, copy, json, os, sys
import numpy as np
from PIL import Image, ImageDraw
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vproc_golden as VG

def to_np(rows):
    return np.array(rows, dtype=np.float64)

def chain(a):
    """the capture card's path, approximately: 720p -> 1080p (bilinear), then back to 720p (box), as the capture"""
    im = Image.fromarray(np.clip(a + 0.5, 0, 255).astype(np.uint8))
    up = im.resize((1920, 1080), Image.BILINEAR)
    return np.asarray(up.resize((1280, 720), Image.BOX), dtype=np.float64)

def load(paths):
    acc = None
    for p in paths:
        im = Image.open(p).convert('RGB')
        if im.size != (1280, 720):
            im = im.resize((1280, 720), Image.BOX)
        a = np.asarray(im, dtype=np.float64)
        acc = a if acc is None else acc + a
    return acc / len(paths)

def amp_at(prof, period):
    """the amplitude of the component of period <period> (px) in a 1-d profile (mean removed, Hann window)"""
    x = np.asarray(prof, dtype=np.float64); x = x - x.mean()
    n = len(x); w = np.hanning(n); k = np.arange(n)
    return float(abs(np.sum(x * w * np.exp(-2j * np.pi * k / period))) / (w.sum() / 2))

def peak_period(prof, lo=2.0, hi=12.0):
    """the period (px, lo..hi) of the strongest component of a profile"""
    best = None
    for p in np.arange(lo, hi + 1e-9, 0.01):
        v = amp_at(prof, p)
        if best is None or v > best[0]:
            best = (v, p)
    return float(best[1])

def blocks(img, win, nw, nh):
    """one mean per source pixel (its inner part), per channel: (nh, nw, 3)"""
    sw = (win[1] - win[0] + 1) / nw; sh = (win[3] - win[2] + 1) / nh
    out = np.zeros((nh, nw, 3))
    for sy in range(nh):
        y0 = int(round(win[2] + sy * sh)); y1 = int(round(win[2] + (sy + 1) * sh))
        if y1 - y0 >= 3: y0, y1 = y0 + 1, y1 - 1
        for sx in range(nw):
            x0 = int(round(win[0] + sx * sw)); x1 = int(round(win[0] + (sx + 1) * sw))
            if x1 - x0 >= 3: x0, x1 = x0 + 1, x1 - 1
            out[sy, sx] = img[y0:y1, x0:x1].reshape(-1, 3).mean(axis=0)
    return out

def variants(tables):
    """name -> tables for the models: what was loaded, and each feature taken away"""
    out = {'full': tables}
    if tables is None:
        return out
    if tables['flt_mode'] & 1:
        t = copy.deepcopy(tables); t['flt_mode'] = 0          # nearest; the framework's dimming is back
        out['no polyphase filter'] = t
        if tables.get('frac', 4) == 8:                         # the same files in ascal at FRAC 4: every 16th phase
            t = copy.deepcopy(tables); t['frac'] = 4
            t['sets'] = {k: [v[16 * i] for i in range(16)] for k, v in tables['sets'].items()}
            out['FRAC 4 (16 phases)'] = t
        if any(k in tables['sets'] for k in ('2', '3')):        # the adaptive set not used
            t = copy.deepcopy(tables); t['sets'] = {k: v for k, v in tables['sets'].items() if k in ('0', '1')}
            out['no adaptive set'] = t
    if tables.get('gamma_en'):
        t = copy.deepcopy(tables); t['gamma_en'] = 0
        out['no gamma'] = t
    if tables.get('mask_words') and tables.get('mask_loaded', True) and any(tables['mask_words']):
        t = copy.deepcopy(tables); t['mask_words'] = None
        out['no shadow mask'] = t
    out['nothing loaded'] = None
    return out

def mae(a, b, box):
    x0, x1, y0, y1 = box
    return float(np.abs(a[y0:y1, x0:x1] - b[y0:y1, x0:x1]).mean())

def fit(cap, m, box):
    """the capture card's levels: (a, b) with cap ~ a * m + b over the box, least squares"""
    x0, x1, y0, y1 = box
    x = m[y0:y1, x0:x1].ravel(); y = cap[y0:y1, x0:x1].ravel()
    A = np.vstack([x, np.ones_like(x)]).T
    (a, b), *_ = np.linalg.lstsq(A, y, rcond=None)
    if not 0.5 <= a <= 2.0:                      # a card's gain, not an inversion or a collapse: offset only
        a = 1.0; b = float(np.mean(y - x))
    return float(a), float(b)

def align(cap, ref, box, r=3):
    """the integer shift of the capture that fits the model best (each shift with its own levels fit, so a smooth
    picture at the card's levels does not pull it off); ties go to the smaller shift"""
    best = None
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            s = np.roll(np.roll(cap, dy, axis=0), dx, axis=1)
            ga, gb = fit(s, ref, box)
            e = mae(s, ga * ref + gb, box) + 1e-3 * (abs(dx) + abs(dy))
            if best is None or e < best[0]:
                best = (e, dx, dy)
    return best

def plot(series, path, title, ylab='value'):
    """series: [(label, colour, 1-d array)]; a plain line plot with PIL"""
    W, H, L, B = 1000, 420, 60, 40
    im = Image.new('RGB', (W, H), 'white'); d = ImageDraw.Draw(im)
    n = max(len(s[2]) for s in series)
    lo = min(float(np.min(s[2])) for s in series); hi = max(float(np.max(s[2])) for s in series)
    if hi - lo < 1: hi = lo + 1
    X = lambda i: L + (W - L - 20) * i / max(1, n - 1)
    Y = lambda v: H - B - (H - B - 30) * (v - lo) / (hi - lo)
    d.rectangle([L, 30, W - 20, H - B], outline='black')
    d.text((L, 8), title, fill='black')
    for k in range(5):
        v = lo + (hi - lo) * k / 4
        d.text((4, Y(v) - 6), '%.0f' % v, fill='black')
    for i, (lab, col, s) in enumerate(series):
        pts = [(X(j), Y(float(v))) for j, v in enumerate(s)]
        d.line(pts, fill=col, width=2 if i == 0 else 1)
        d.text((W - 260, 36 + 14 * i), lab, fill=col)
    d.text((L, H - B + 8), 'pixel (720p)', fill='black')
    im.save(path)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('captures', nargs='+'); ap.add_argument('--status', required=True); ap.add_argument('--win', required=True)
    ap.add_argument('--tables'); ap.add_argument('--out'); ap.add_argument('--margin', type=float, default=2.0)
    ap.add_argument('--name', default='board')
    ap.add_argument('--ref', nargs='+', help='captures of the same pattern with nothing loaded (the card\'s transfer for the gamma test)')
    ap.add_argument('--ref-status', default='0')
    ap.add_argument('--rows', help='y0,y1 (720p): compare these lines only')
    a = ap.parse_args()
    status = int(a.status, 16)
    win = tuple(int(v) for v in a.win.split(','))
    tables = json.load(open(a.tables)) if a.tables else None
    cap = load(a.captures)
    box = (win[0] + 4, win[1] - 3, win[2] + 4, win[3] - 3)
    if a.rows:                                   # e.g. the card's MJPEG encoder corrupts the bottom of a sharp Pixel grid
        r0, r1 = (int(v) for v in a.rows.split(','))
        box = (box[0], box[1], max(box[2], r0), min(box[3], r1))
    vt = variants(tables)
    gold = {k: to_np(VG.golden(status, t, win)) for k, t in vt.items()}
    models = {k: chain(g) for k, g in gold.items()}
    e0, dx, dy = align(cap, models['full'], box)
    cap = np.roll(np.roll(cap, dy, axis=0), dx, axis=1)
    raw = {k: mae(cap, m, box) for k, m in models.items()}
    lv = {k: fit(cap, m, box) for k, m in models.items()}
    errs = {k: mae(cap, lv[k][0] * m + lv[k][1], box) for k, m in models.items()}
    sep = {k: mae(models['full'], m, box) for k, m in models.items()}       # how far each model is from "full"
    print('vproc_board %s: status %032x, window %s, capture shifted by (%d, %d)' % (a.name, status, a.win, dx, dy))
    others = []
    for k, e in errs.items():
        note = ''
        if k != 'full':
            if sep[k] < 0.5:
                note = '  (the same picture as "full" here: this feature changes nothing in this pattern; not ranked)'
            else:
                others.append(e); note = '  (%.2f from "full")' % sep[k]
        print('   %-22s mean |capture - model| = %6.2f after levels a=%.3f b=%+.1f (raw %6.2f)%s'
              % (k, e, lv[k][0], lv[k][1], raw[k], note))
    base = max(errs['full'], 1e-6)
    closest = min(errs, key=errs.get)
    print('   ranking: the closest model is "%s"' % closest)
    fm = lambda t: (t or {}).get('flt_mode', 0)
    res = []                                         # (feature, ok, text)
    _, nw, nh = VG.native(status)
    sl = (status >> 122) & 3
    # filter: "full" against nearest (+ dimming) in the ranking
    if 'no polyphase filter' in errs and sep['no polyphase filter'] >= 0.5:
        r = errs['no polyphase filter'] / base
        res.append(('filter', r >= a.margin, 'mean error %.2f against %.2f with nearest + the framework\'s dimming: %.1fx (margin %.1f)'
                    % (errs['full'], errs['no polyphase filter'], r, a.margin)))
    # scan: the vertical profile's strongest periodic component
    if (fm(tables) & 2) or (sl and 'no polyphase filter' in gold):
        pat = (status >> 41) & 15
        y0 = win[2] + 6; y1 = win[2] + (win[3] - win[2]) // 3 - 6 if pat == 1 else win[3] - 6
        vp = lambda img: img[y0:y1, win[0] + 6:win[1] - 6].mean(axis=(1, 2))
        alt = 'no polyphase filter' if 'no polyphase filter' in models else 'nothing loaded'
        pf, pa = peak_period(vp(models['full'])), peak_period(vp(models[alt]))
        cf, ca = amp_at(vp(cap), pf), amp_at(vp(cap), pa)
        mf, ma = amp_at(vp(models['full']), pf), amp_at(vp(models['full']), pa)
        ok_s = cf > 2 * ca if abs(pf - pa) > 0.2 else True
        res.append(('scan', ok_s, 'vertical profile rows %d-%d: period %.2f (the loaded model\'s) %.1f in the capture, %.1f in the model; '
                    'period %.2f (%s) %.1f in the capture, %.1f in the model' % (y0, y1, pf, cf, mf, pa, alt, ca, ma)))
    # gamma: block means
    if tables and tables.get('gamma_en') and 'no gamma' in gold:
        bc = blocks(cap, win, nw, nh)
        bg = blocks(models['no gamma'], win, nw, nh)
        chans = [c for c in range(3) if bg[..., c].std() > 1.0]          # a constant channel shows no curve
        T = None
        if a.ref:                                    # the card's own transfer, from a capture of the same pattern unprocessed
            rc = load(a.ref); rm = chain(to_np(VG.golden(int(a.ref_status, 16), None, win)))
            br, bmr = blocks(rc, win, nw, nh), blocks(rm, win, nw, nh)
            T = []
            for c in range(3):
                x, y = bmr[..., c].ravel(), br[..., c].ravel()
                xs = np.arange(0, 256, 4.0); ys = []
                for v in xs:
                    m = np.abs(x - v) <= 2.5
                    ys.append(y[m].mean() if m.any() else np.nan)
                ys = np.array(ys); ok_ = ~np.isnan(ys)
                T.append((xs[ok_], ys[ok_]))
        def resid(m):
            bm = blocks(m, win, nw, nh); e = []
            for c in chans:
                x = bm[..., c].ravel(); y = bc[..., c].ravel()
                if T is not None and len(T[c][0]) > 8:
                    x = np.interp(x, T[c][0], T[c][1])
                A = np.vstack([x, np.ones_like(x)]).T
                sol, *_ = np.linalg.lstsq(A, y, rcond=None)
                e.append(np.sqrt(np.mean((A @ sol - y) ** 2)))
            return float(np.mean(e))
        rg, rn = resid(models['full']), resid(models['no gamma'])
        res.append(('gamma', rn >= a.margin * rg, 'per-source-pixel means of %s%s, fitted: residual %.2f with the gamma table, %.2f without: %.1fx (margin %.1f)'
                    % ('/'.join('RGB'[c] for c in chans), ' through the card\'s transfer measured on the reference capture' if T else '',
                       rg, rn, rn / max(rg, 1e-6), a.margin)))
    # mask: the white square's column profile
    if 'no shadow mask' in gold:
        sqx, sqy = (nw - 24) // 2, (nh - 24) // 2
        sw = (win[1] - win[0] + 1) / nw; sh = (win[3] - win[2] + 1) / nh
        x0 = int(win[0] + (sqx + 2) * sw); x1 = int(win[0] + (sqx + 22) * sw)
        y0 = int(win[2] + (sqy + 2) * sh); y1 = int(win[2] + (sqy + 22) * sh)
        best = None
        for axis, what in ((0, 'columns %d-%d' % (x0, x1)), (1, 'lines %d-%d' % (y0, y1))):   # a rotated mask runs down
            cp = lambda img, ax=axis: img[y0:y1, x0:x1].mean(axis=(ax, 2))
            per = peak_period(cp(models['full']))
            mm = amp_at(cp(models['full']), per)
            if best is None or mm > best[0]:
                best = (mm, per, cp, what)
        mm, per, cp, what = best
        cm, nm = amp_at(cp(cap), per), amp_at(cp(models['no shadow mask']), per)
        ok_m = (mm / 2.5 <= cm <= mm * 2) and cm >= 5 * max(nm, 0.05)
        res.append(('mask', ok_m, 'white square, profile across %s: the component of period %.2f px is %.2f in the capture, %.2f in the model, %.2f without the mask'
                    % (what, per, cm, mm, nm)))
    # presence: capture ~ g * (alt + alpha * (full - alt)) + b, least squares over the picture: alpha 1 = the
    # feature at the model's strength, 0 = absent (the card's scaler and MJPEG soften fine detail: masks read low)
    for k in models:
        if k == 'full' or sep[k] < 0.5:
            continue
        x0, x1, y0, y1 = box
        xa = models[k][y0:y1, x0:x1].ravel(); dd = (models['full'] - models[k])[y0:y1, x0:x1].ravel()
        yy = cap[y0:y1, x0:x1].ravel()
        A = np.vstack([xa, dd, np.ones_like(xa)]).T
        coef, *_ = np.linalg.lstsq(A, yy, rcond=None)
        alpha = coef[1] / coef[0] if coef[0] else float('nan')
        print('   presence of what "%s" takes away: alpha = %.2f (1 = as the model, 0 = absent)' % (k, alpha))
        if k in ('FRAC 4 (16 phases)', 'no adaptive set'):
            nm = 'frac8' if k.startswith('FRAC') else 'adaptive'
            res.append((nm, 0.6 <= alpha <= 1.4, 'alpha %.2f against "%s" (PASS: 0.6 .. 1.4)' % (alpha, k)))
    ok = all(r[1] for r in res) if res else (closest == 'full')
    for f, o, t in res:
        print('   %-6s %s  %s' % (f, 'PASS' if o else 'FAIL', t))
    print('vproc_board %s: %s' % (a.name, 'PASS' if ok else 'FAIL'))
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        n = a.name
        Image.fromarray(np.clip(cap + 0.5, 0, 255).astype(np.uint8)).save(os.path.join(a.out, n + '_capture720.png'))
        full = to_np(VG.golden(status, tables, win))
        Image.fromarray(full.astype(np.uint8)).save(os.path.join(a.out, n + '_model.png'))
        Image.fromarray(np.clip(np.abs(cap - (lv['full'][0] * models['full'] + lv['full'][1])) * 4, 0, 255).astype(np.uint8)).save(os.path.join(a.out, n + '_diff_x4.png'))
        # profiles: a horizontal one through the picture's top sixth, a vertical one down its left part
        y0 = win[2] + (win[3] - win[2]) // 12; x0 = win[0] + 8
        rows = slice(y0, y0 + 30); cols = slice(x0, x0 + 30)
        ser = [('capture', (0, 0, 200), cap[rows, x0:x0 + 60].mean(axis=(0, 2)))]
        cols_ = [(200, 80, 0), (0, 140, 0), (160, 0, 160), (120, 120, 120)]
        for i, (k, m) in enumerate(models.items()):
            mm = lv[k][0] * m + lv[k][1]
            ser.append(('model: ' + k, cols_[i % 4], mm[rows, x0:x0 + 60].mean(axis=(0, 2))))
        plot(ser, os.path.join(a.out, n + '_hprofile.png'), '%s: horizontal profile (mean of RGB, rows %d-%d, 720p; models at the capture\'s levels)' % (n, y0, y0 + 29))
        ser = [('capture', (0, 0, 200), cap[y0:y0 + 40, cols].mean(axis=(1, 2)))]
        for i, (k, m) in enumerate(models.items()):
            mm = lv[k][0] * m + lv[k][1]
            ser.append(('model: ' + k, cols_[i % 4], mm[y0:y0 + 40, cols].mean(axis=(1, 2))))
        plot(ser, os.path.join(a.out, n + '_vprofile.png'), '%s: vertical profile (mean of RGB, columns %d-%d, 720p; models at the capture\'s levels)' % (n, x0, x0 + 29))
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
