"""Local-only Subsonic fixture for the simulator login/sync/home smoke test."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs
import io
import wave
import json
import struct
import zlib


def rectangular_cover(second=False):
    width, height = (320, 480) if second else (480, 320)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            border = x < 12 or y < 12 or x >= width - 12 or y >= height - 12
            pixels.extend((255, 240, 210) if border else
                          (40 + x * 100 // width, 55 + y * 80 // height, 180) if not second else
                          (30 + x * 50 // width, 90 + y * 100 // height, 135))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(bytes(pixels))) + chunk(b'IEND', b''))


COVERS = [rectangular_cover(), rectangular_cover(True)]

def silent_audio(seconds):
    audio_buffer = io.BytesIO()
    with wave.open(audio_buffer, 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(b'\0\0' * 16000 * seconds)
    return audio_buffer.getvalue()


AUDIO = silent_audio(180)
SCROBBLE_AUDIO = silent_audio(8)
LYRICS = '<lyricsList><structuredLyrics lang="zh" synced="true">' + ''.join(
    f'<line start="{i * 10000}">{text}</line>' for i, text in enumerate([
        '晚风轻轻经过', '带着远方的颜色', '沿着街灯往前走', '把今天写成一首歌',
        '让音乐陪着我', '慢慢走过每个街口', '天边的云还没散', '故事也还没有说完',
        '此刻不用着急', '听见生活的回音',
    ])) + '</structuredLyrics></lyricsList>'

ARTIST = '<artist id="artist-1" name="测试歌手" albumCount="1" coverArt="ar-1"/>'
ALBUM = '<album id="album-1" name="测试专辑" artist="测试歌手" artistId="artist-1" songCount="1" duration="180" coverArt="al-1" created="2026-01-01T00:00:00"/>'
SONG = '<song id="song-1" title="测试歌曲" album="测试专辑" albumId="album-1" artist="测试歌手" artistId="artist-1" duration="180" size="1000000" suffix="mp3" contentType="audio/mpeg" isDir="false" coverArt="al-1"/>'
SONG = SONG.replace('suffix="mp3"', 'suffix="wav"').replace('audio/mpeg', 'audio/wav')
SECOND_SONG = SONG.replace('song-1', 'song-2').replace('测试歌曲', '下一首歌曲').replace('al-1', 'al-2')
SCROBBLE_SONG = SONG.replace('song-1', 'song-scrobble').replace('测试歌曲', 'Scrobble probe').replace('duration="180"', 'duration="8"')
PLAYLIST = '<playlist id="playlist-1" name="测试歌单" songCount="1" duration="180" coverArt="pl-1_hash" owner="smoke" public="false"/>'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        action = url.path.rsplit('/', 1)[-1].removesuffix('.view')
        query = parse_qs(url.query)
        if '/apis/mlj_1/' in url.path:
            endpoint = url.path.split('/apis/mlj_1/', 1)[1]
            status, response = maloja_response(endpoint, query)
            body = json.dumps(response, ensure_ascii=False).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if action in ('stream', 'download'):
            if action == 'stream' and (query.get('format') != ['raw'] or 'maxBitRate' in query):
                self.send_error(400, 'Expected original audio without transcoding')
                return
            audio = SCROBBLE_AUDIO if query.get('id') == ['song-scrobble'] else AUDIO
            start, end = 0, len(audio) - 1
            partial = self.headers.get('Range', '').startswith('bytes=')
            if partial:
                first, last = self.headers['Range'][6:].split('-', 1)
                start = int(first or '0')
                end = min(int(last) if last else end, end)
            self.send_response(206 if partial else 200)
            self.send_header('Content-Type', 'audio/wav')
            self.send_header('Accept-Ranges', 'bytes')
            if partial:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(audio)}')
            self.send_header('Content-Length', str(end - start + 1))
            self.end_headers()
            try:
                self.wfile.write(audio[start:end+1])
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if action == 'scrobble':
            # Only fixture identifiers and protocol fields; never authentication data.
            print('SCROBBLE ' + json.dumps({key: query.get(key, []) for key in ('id', 'submission', 'time')}), flush=True)
        if action in ('getCoverArt', 'image'):
            body = COVERS[1 if query.get('id') == ['al-2'] else 0]
            mime = 'image/png'
        else:
            album_list = ALBUM if query.get('offset', ['0'])[0] == '0' else ''
            responses = {
                'ping': '',
                'getOpenSubsonicExtensions': '<openSubsonicExtensions name="songLyrics"><versions>1</versions></openSubsonicExtensions>',
                'getSong': SCROBBLE_SONG if query.get('id') == ['song-scrobble'] else SECOND_SONG if query.get('id') == ['song-2'] else SONG,
                'search3': '<searchResult3>' + (SCROBBLE_SONG if query.get('query') == ['scrobble-probe'] else '') + '</searchResult3>',
                'getLyricsBySongId': LYRICS,
                'getGenres': '<genres><genre songCount="1" albumCount="1">Pop</genre></genres>',
                'getArtists': f'<artists><index name="T">{ARTIST}</index></artists>',
                'getArtist': f'<artist id="artist-1" name="测试歌手" albumCount="1">{ALBUM}</artist>',
                'getAlbumList2': f'<albumList2>{album_list}</albumList2>',
                'getAlbumList': f'<albumList>{album_list}</albumList>',
                'getAlbum': f'<album id="album-1" name="测试专辑" artist="测试歌手" artistId="artist-1" songCount="2" coverArt="al-1">{SONG}{SECOND_SONG}</album>',
                'getPlaylists': f'<playlists>{PLAYLIST}</playlists>',
                'getPlaylist': PLAYLIST.replace('/>', '>') + SONG.replace('<song ', '<entry ') + '</playlist>',
                'getPodcasts': '<podcasts/>',
                'getStarred2': '<starred2/>',
                'getStarred': '<starred/>',
                'getRandomSongs': f'<randomSongs>{SONG}</randomSongs>',
                'getInternetRadioStations': '<internetRadioStations/>',
                'getMusicFolders': '<musicFolders><musicFolder id="1" name="Music"/></musicFolders>',
            }
            inner = responses.get(action, '')
            body = ('<?xml version="1.0" encoding="UTF-8"?>'
                    '<subsonic-response xmlns="http://subsonic.org/restapi" status="ok" '
                    'version="1.16.1" type="navidrome" serverVersion="0.60.0" openSubsonic="true">'
                    + inner + '</subsonic-response>').encode('utf-8')
            mime = 'text/xml; charset=utf-8'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Never log auth query parameters, even for the fixed fixture account.
        print(urlparse(self.path).path, flush=True)


def maloja_response(endpoint, query):
    """Deterministic Maloja contract, including paging and error/empty states."""
    if query.get('in') == ['invalid']:
        return 200, {'status': 'error', 'amount': 99, 'list': []}
    if query.get('in') == ['unauthorized']:
        return 401, {'error': 'Unauthorized'}
    if query.get('in') == ['empty']:
        return 200, {'status': 'ok', 'amount': 0, 'list': []}
    page = int(query.get('page', ['0'])[0])
    album = {'albumtitle': '测试专辑', 'artists': ['测试歌手']}
    track = {'title': '测试歌曲', 'artists': ['测试歌手'], 'album': album}
    def entry(kind, i=0):
        common = {'scrobbles': 120 - i, 'rank': i + 1}
        if kind == 'artists':
            return {**common, 'artist': '测试歌手' if i == 0 else f'歌手 {i + 1}', 'artist_id': i + 1}
        if kind == 'albums':
            return {**common, 'album': {**album, 'albumtitle': '测试专辑' if i == 0 else f'专辑 {i + 1}'}, 'album_id': str(i + 1)}
        return {**common, 'track': track if i == 0 else {**track, 'title': f'歌曲 {i + 1}'}, 'track_id': i + 1}
    def period(i):
        return {'description': f'2026/09/{i + 1:02}', 'fromstamp': 1788220800 + i * 86400,
                'tostamp': 1788307199 + i * 86400, 'fromstring': f'2026/09/{i + 1:02}', 'tostr': f'2026/09/{i + 1:02}'}
    if endpoint == 'numscrobbles':
        return 200, {'status': 'ok', 'amount': 328}
    if endpoint.startswith('charts/'):
        return 200, {'status': 'ok', 'list': [entry(endpoint.split('/')[1], i) for i in range(55 if endpoint.endswith('tracks') else 4)]}
    if endpoint in ('pulse', 'performance'):
        key = 'scrobbles' if endpoint == 'pulse' else 'rank'
        return 200, {'status': 'ok', 'list': [{ 'range': period(i), key: (i * 7 + 13) % 48 } for i in reversed(range(12))] if page == 0 else []}
    if endpoint.startswith('top/'):
        return 200, {'status': 'ok', 'list': [{'range': period(i), 'top': [entry(endpoint.split('/')[1])]} for i in range(4)]}
    if endpoint.endswith('info'):
        return 200, {'status': 'ok', 'scrobbles': 512, 'position': 2, 'topweeks': 3,
                     'certification': 'gold', 'medals': {'gold': ['2026/09'], 'silver': [], 'bronze': []},
                     'associated': ['合作歌手'] if endpoint == 'artistinfo' else [], 'id': 1}
    if endpoint == 'scrobbles':
        return 200, {'status': 'ok', 'list': [{'time': 1790614800 - (i + page * 50) * 3600,
                      'duration': 180, 'origin': 'qMusic', 'track': {**track, 'album': album if i % 2 == 0 else '测试专辑'},
                      'track_id': '1' if i % 2 == 0 else 1} for i in range(50 if page == 0 else 1)]}
    return 404, {'status': 'error'}


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
