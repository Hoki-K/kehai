import numpy as np, wave, sys
SR = 48000
rng = np.random.default_rng(1)
T = 195
x = np.zeros(int(SR*T))
# background: soft pink-ish noise
w = rng.standard_normal(len(x))
b = np.cumsum(w); b -= np.convolve(b, np.ones(4800)/4800, mode='same')
x += 0.002 * b / (np.std(b)+1e-9) + 0.0015*w

def voice(f0, amp, breath=0.0):
    n = len(f0)
    ph = 2*np.pi*np.cumsum(f0)/SR
    s = np.zeros(n)
    for k in range(1, 16):
        mask = (k*f0 < 9000)
        s += mask * np.sin(k*ph) / k**1.1
    s = s/np.max(np.abs(s)+1e-9)
    s += breath * rng.standard_normal(n)
    return s * amp

def env(n, a=0.015, r=0.03):
    e = np.ones(n); na=int(a*SR); nr=int(r*SR)
    e[:na] = np.linspace(0,1,na); e[-nr:] = np.linspace(1,0,nr); return e

def put(t, sig):
    i = int(t*SR); x[i:i+len(sig)] += sig

def syllable(dur, f_start, f_end, amp, breath=0.03):
    n = int(dur*SR); f0 = np.linspace(f_start, f_end, n) * (1 + 0.01*np.sin(2*np.pi*5*np.arange(n)/SR))
    return voice(f0, amp, breath) * env(n)

# 1) child laughter at 12s: 7 "ha" pulses every ~190ms
t = 12.0
for k in range(7):
    put(t, syllable(0.11, 420-12*k, 380-12*k, 0.25, breath=0.08)); t += 0.19 + rng.uniform(-0.015, 0.015)
# 2) child singing at 45s: 8 notes
notes = [392, 440, 494, 392, 494, 523, 587, 523]
t = 45.0
for f in notes:
    n = int(0.42*SR); vib = 1 + 0.008*np.sin(2*np.pi*5.5*np.arange(n)/SR)
    put(t, voice(f*vib*np.ones(n), 0.15, 0.01) * env(n, 0.03, 0.06)); t += 0.47
# 3) child chatter at 80s: 6s of syllables
def talk(t0, dur, lo, hi, amp):
    t = t0
    while t < t0 + dur:
        d = rng.uniform(0.09, 0.22); f1 = rng.uniform(lo, hi); f2 = f1 * rng.uniform(0.85, 1.12)
        put(t, syllable(d, f1, f2, amp)); t += d + rng.uniform(0.05, 0.2)
talk(80, 6, 260, 380, 0.12)
# 4) adult (low) speech at 115s: should not count as child chatter
talk(115, 6, 105, 150, 0.12)
# 5) shout at 150s
n = int(0.9*SR); put(150, voice(np.linspace(500, 470, n), 0.6, 0.02) * env(n, 0.03, 0.08))
# 6) door slam at 175s
n = int(0.25*SR); put(175, 0.7 * rng.standard_normal(n) * np.exp(-np.arange(n)/(0.04*SR)))
x = np.clip(x, -1, 1)
out = sys.argv[1] if len(sys.argv) > 1 else 'test.wav'
with wave.open(out, 'wb') as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(SR)
    f.writeframes((x*32767).astype('<i2').tobytes())
print('wrote', out, T, 's')
