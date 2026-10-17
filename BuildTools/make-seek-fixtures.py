"""Generate original, time-marked audio with deliberately nonuniform FLAC bitrate."""
from pathlib import Path
import argparse
import array
import shutil
import subprocess
import sys
import wave


def generate(destination):
    destination.mkdir(parents=True, exist_ok=True)
    pcm = array.array('h')
    random = 17
    for sample in range(96 * 44100):
        second = sample // 44100
        random = (1664525 * random + 1013904223) & 0xFFFFFFFF
        # Every second has its own DC marker; high/low entropy regions force VBR.
        noise = ((random >> 16) % 12001 - 6000) if second % 16 < 5 else 0
        value = 1000 + second * 150 + noise
        pcm.extend((value, value))
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(destination / 'markers.wav'), 'wb') as audio:
        audio.setnchannels(2)
        audio.setsampwidth(2)
        audio.setframerate(44100)
        audio.writeframes(pcm.tobytes())
    if shutil.which('ffmpeg'):
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(destination / 'markers.wav'),
                        '-c:a', 'flac', str(destination / 'markers.flac')], check=True)
    else:
        subprocess.run(['afconvert', '-f', 'flac', '-d', 'flac', str(destination / 'markers.wav'),
                        str(destination / 'markers.flac')], check=True)
    original = bytearray((destination / 'markers.flac').read_bytes())
    assert original[:4] == b'fLaC' and original[4] & 0x7F == 0
    end = 8 + int.from_bytes(original[5:8], 'big')
    last = original[4] & 0x80
    original[4] &= 0x7F
    padding = bytes([last | 1]) + (200000).to_bytes(3, 'big') + bytes(200000)
    (destination / 'markers-metadata.flac').write_bytes(original[:end] + padding + original[end:])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('destination', type=Path)
    generate(parser.parse_args().destination)
