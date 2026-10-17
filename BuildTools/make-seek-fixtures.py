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
        subprocess.run(['afconvert', '-f', 'flac', '-d', 'LEI16', str(destination / 'markers.wav'),
                        str(destination / 'markers.flac')], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('destination', type=Path)
    generate(parser.parse_args().destination)
