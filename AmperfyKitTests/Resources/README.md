`flac-variable-bitrate.flac` is a generated, copyright-free 12-second mono FLAC
fixture at 44.1 kHz, 16 bit. It has two silent seconds, tones, and noisy sections
at seconds 3, 4, 8, 9 and 10 so an estimated byte seek is measurably inaccurate.
It contains no music or third-party recording.

Regenerate from the repository root with Python and FFmpeg:

```python
import math, random, struct, subprocess
rng = random.Random(217)
pcm = bytearray()
for i in range(44100 * 12):
    second = i // 44100
    noise = rng.randint(-6000, 6000) if second in [3, 4, 8, 9, 10] else 0
    sample = 0 if second < 2 else int(4000 * math.sin(2 * math.pi * (500 + second * 200) * i / 44100)) + noise
    pcm.extend(struct.pack('<h', sample))
subprocess.run([
    'ffmpeg', '-f', 's16le', '-ar', '44100', '-ac', '1', '-i', 'pipe:0',
    '-c:a', 'flac', '-compression_level', '8', '-map_metadata', '-1', '-y',
    'AmperfyKitTests/Resources/flac-variable-bitrate.flac',
], input=pcm, check=True)
```
