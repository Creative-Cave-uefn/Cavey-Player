"""Local Deezer adapter for Cave Player, based on deezer-downloader 2.15.0.

This file DOES NOT implement decryption or network authentication: the optional
third-party deezer-downloader package handles those operations. The bridge
accepts a single query, stores music only in the supplied output directory and
writes machine-readable events; credentials must never appear in stdout.
"""
from __future__ import annotations

import argparse
import configparser
import json
import re
import sys
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

PREFIX = '@cavedeezer:'
SUPPORTED_DOMAINS = {'deezer.com', 'www.deezer.com'}
MAX_ITEMS = 500


def emit(event: str, **fields: object) -> None:
    print(PREFIX + json.dumps({'type': event, **fields}, ensure_ascii=True), flush=True)


def normalize(text: str) -> str:
    text = unicodedata.normalize('NFKC', text).casefold()
    return ' '.join(re.findall(r'[^\W_]+', text, flags=re.UNICODE))


def parse_input(value: str) -> tuple[str, object]:
    value = value.strip()
    if not value:
        raise ValueError('Введите «Исполнитель - Название» или ссылку Deezer.')
    if '://' not in value:
        match = re.fullmatch(r'(.+?)\s+[-–—]\s+(.+)', value)
        if not match or not all(normalize(m) for m in match.groups()):
            raise ValueError('Поиск Deezer требует «Исполнитель - Название».')
        return 'search', (match.group(1).strip(), match.group(2).strip())
    try:
        uri = urlsplit(value)
        if uri.scheme not in ('http', 'https') or uri.hostname not in SUPPORTED_DOMAINS or uri.port is not None or uri.username:
            raise ValueError('Допустимы только ссылки deezer.com.')
    except (ValueError, TypeError) as exc:
        raise ValueError('Некорректная ссылка Deezer.') from exc
    path = uri.path.strip('/')
    match = re.fullmatch(r'(?:(?:[a-z]{2}(?:-[a-z]{2})?)/)?(track|album|playlist)/(\d+)', path, re.I)
    if match is None:
        raise ValueError('Поддерживаются ссылки Deezer на /track/, /album/ и /playlist/.')
    return match.group(1).lower(), match.group(2)


def safe_filename(text: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '', str(text)).strip(' .')
    return (cleaned[:125].rstrip(' .') or 'Без названия')


def load_auth(path: str) -> tuple[str, str]:
    p = Path(path)
    if not p.is_file():
        raise ValueError('Настройте cookie ARL в локальном файле deezer_auth.ini.')
    parser = configparser.ConfigParser(interpolation=None)
    parser.read(p, encoding='utf-8')
    if not parser.has_section('deezer'):
        raise ValueError('В конфиге отсутствует раздел [deezer].')
    arl = parser.get('deezer', 'arl', fallback='').strip()
    quality = parser.get('deezer', 'quality', fallback='mp3').strip().lower()
    if not arl or arl == 'PASTE_ARL_COOKIE_HERE' or len(arl) < 20 or any(c.isspace() for c in arl):
        raise ValueError('Укажите действительный cookie ARL аккаунта Deezer.')
    if quality not in ('mp3', 'flac'):
        raise ValueError('Качество должно быть mp3 или flac.')
    return arl, quality


def choose_exact(results: list[dict], artist: str, title: str) -> dict:
    for item in results:
        if normalize(item.get('artist', '')) == normalize(artist) and normalize(item.get('title', '')) == normalize(title):
            return item
    raise RuntimeError('Точное совпадение исполнителя и названия в Deezer не найдено.')


def _load_backend(arl: str, quality: str):
    # Import config BEFORE deezer.py, which holds a module-level reference to it.
    from deezer_downloader import configuration
    cfg = configparser.ConfigParser(interpolation=None)
    cfg['deezer'] = {'cookie_arl': arl, 'quality': quality}
    cfg['proxy'] = {'server': ''}
    configuration.config = cfg
    from deezer_downloader import deezer
    deezer.init_deezer_session('', quality)
    return deezer


def _fetch_tracks(deezer, request: tuple[str, object]) -> list[dict]:
    kind, key = request
    if kind == 'search':
        artist, title = key
        item = choose_exact(deezer.deezer_search(f'{artist} {title}', deezer.TYPE_TRACK), artist, title)
        return [deezer.get_song_infos_from_deezer_website(deezer.TYPE_TRACK, item['id'])]
    if kind == 'track':
        return [deezer.get_song_infos_from_deezer_website(deezer.TYPE_TRACK, key)]
    if kind == 'album':
        return list(deezer.get_song_infos_from_deezer_website(deezer.TYPE_ALBUM, key))[:MAX_ITEMS]
    if kind == 'playlist':
        _, songs = deezer.parse_deezer_playlist(str(key))
        return list(songs)[:MAX_ITEMS]
    raise ValueError('Неподдерживаемый запрос.')


def download(config_path: str, value: str, directory: str) -> int:
    request = parse_input(value)  # validate before loading auth/network
    arl, quality = load_auth(config_path)
    out = Path(directory).resolve()
    out.mkdir(parents=True, exist_ok=True)
    backend = _load_backend(arl, quality)
    songs = _fetch_tracks(backend, request)
    if not songs:
        raise RuntimeError('Deezer не вернул аудиозаписей.')
    emit('total', count=len(songs))
    done = 0
    for i, song in enumerate(songs):
        artist = str(song.get('ART_NAME') or '')
        title = str(song.get('SNG_TITLE') or '')
        track_id = str(song.get('SNG_ID') or '')
        # Stable ID avoids overwriting equal titles from separate releases.
        extension = backend.get_file_extension()
        if extension not in ('mp3', 'flac') or not re.fullmatch(r'\d+', track_id):
            emit('failed', title=title, message='Нет допустимого ID или формата записи.')
            continue
        file = out / f'{i + 1:03d} - {safe_filename(artist)} - {safe_filename(title)} - {track_id}.{extension}'
        try:
            backend.download_song(song, str(file))
            if not file.is_file() or file.stat().st_size < 1024:
                raise RuntimeError('Загрузка вернула пустой аудиофайл.')
            emit('track', file=str(file), artist=artist, title=title)
            done += 1
        except Exception:
            file.unlink(missing_ok=True)
            emit('failed', title=title, message='Недоступен трек или ошибка загрузки.')
    if done == 0:
        raise RuntimeError('Deezer не предоставил ни одного доступного аудиофайла.')
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Cave Player: Deezer downloader bridge')
    parser.add_argument('--config', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--input', required=True)
    args = parser.parse_args(argv)
    try:
        return download(args.config, args.input, args.output)
    except Exception as exc:
        # Never echo library exceptions, which may include cookie/session data.
        if isinstance(exc, (ValueError, RuntimeError)) and str(exc).startswith((
            'Введите', 'Поиск', 'Допустимы', 'Некорректная', 'Поддерживаются', 'Настройте',
            'В конфиге', 'Укажите', 'Качество', 'Точное', 'Deezer не', 'Неподдерживаемый')):
            message = str(exc)
        else:
            message = 'Ошибка Deezer или подключения. Проверьте аккаунт, доступность релиза и журнал.'
        emit('error', message=message)
        return 1


if __name__ == '__main__':
    sys.exit(main())
