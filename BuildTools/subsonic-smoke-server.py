"""Local-only Subsonic fixture for the simulator login/sync/home smoke test."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

ARTIST = '<artist id="artist-1" name="测试歌手" albumCount="1" coverArt="ar-1"/>'
ALBUM = '<album id="album-1" name="测试专辑" artist="测试歌手" artistId="artist-1" songCount="1" duration="180" coverArt="al-1" created="2026-01-01T00:00:00"/>'
SONG = '<song id="song-1" title="测试歌曲" album="测试专辑" albumId="album-1" artist="测试歌手" artistId="artist-1" duration="180" size="1000000" suffix="mp3" contentType="audio/mpeg" isDir="false" coverArt="al-1"/>'
PLAYLIST = '<playlist id="playlist-1" name="测试歌单" songCount="1" duration="180" coverArt="pl-1_hash" owner="smoke" public="false"/>'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        action = url.path.rsplit('/', 1)[-1].removesuffix('.view')
        query = parse_qs(url.query)
        if action == 'getCoverArt':
            body = Path('AmperfyKit/Assets/Assets.xcassets/Icon-1024.imageset/Icon-1024.png').read_bytes()
            mime = 'image/png'
        else:
            album_list = ALBUM if query.get('offset', ['0'])[0] == '0' else ''
            responses = {
                'ping': '',
                'getOpenSubsonicExtensions': '<openSubsonicExtensions/>',
                'getGenres': '<genres><genre songCount="1" albumCount="1">Pop</genre></genres>',
                'getArtists': f'<artists><index name="T">{ARTIST}</index></artists>',
                'getArtist': f'<artist id="artist-1" name="测试歌手" albumCount="1">{ALBUM}</artist>',
                'getAlbumList2': f'<albumList2>{album_list}</albumList2>',
                'getAlbumList': f'<albumList>{album_list}</albumList>',
                'getAlbum': f'<album id="album-1" name="测试专辑" artist="测试歌手" artistId="artist-1" songCount="1" coverArt="al-1">{SONG}</album>',
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


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 8765), Handler).serve_forever()
