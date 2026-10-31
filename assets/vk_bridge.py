"""Cave Player <-> VKpyMusic 4.0.2 bridge. No secrets are printed.

This is an optional local helper. It does not bypass DRM or VK access checks.
The user must authenticate interactively in a separate console and must have
rights to download and store any selected recording.
"""
from __future__ import annotations

import argparse
import getpass
import json
import logging
import os
from pathlib import Path
import re
import shutil
import sys
import unicodedata
from urllib.parse import urlsplit

PREFIX = '@cavevk:'
AUDIO_RE = re.compile(r'^(?:audio)?(-?\d+)_(\d+)(?:_[A-Za-z0-9]+)?$')
PLAYLIST_RE = re.compile(r'^(-?\d+)_(\d+)(?:_([A-Za-z0-9]+))?$')


def emit(kind, **values):
    print(PREFIX + json.dumps({'type': kind, **values}, ensure_ascii=False), flush=True)


def normalize(value):
    value = unicodedata.normalize('NFKC', value).casefold()
    return ' '.join(''.join(c if c.isalnum() else ' ' for c in value).split())


def parse_input(text):
    text = text.strip()
    if not text:
        raise ValueError('Укажите «Исполнитель - Название» или ссылку VK.')
    if '://' not in text:
        # Require both fields so the first search result cannot silently be another song.
        parts = re.split(r'\s+[-–—]\s+', text, maxsplit=1)
        if len(parts) != 2 or not all(x.strip() for x in parts):
            raise ValueError('В VK режиме поиск принимает «Исполнитель - Название».')
        return 'search', tuple(x.strip() for x in parts)
    url = urlsplit(text)
    if url.scheme not in ('https', 'http') or url.username or url.password or url.port:
        raise ValueError('Некорректная ссылка VK.')
    host = (url.hostname or '').lower()
    if host not in ('vk.com', 'm.vk.com', 'music.vk.com', 'vk.ru', 'm.vk.ru'):
        raise ValueError('Этот источник принимает только ссылки vk.com / vk.ru.')
    path = url.path.strip('/')
    if (match := re.search(r'(?:^|/)audio(-?\d+_\d+)(?:$|/)', path)):
        return 'audio', [match.group(1)]
    if path.startswith('music/playlist/'):
        value = path.removeprefix('music/playlist/').split('/')[0]
        if (match := PLAYLIST_RE.fullmatch(value)):
            return 'playlist', (int(match.group(1)), int(match.group(2)), match.group(3) or '')
    raise ValueError('Поддерживаются ссылки VK на audio<owner>_<id> и music/playlist/<owner>_<id>[_key].')


def song_matches(song, artist, title):
    """Avoid grabbing unrelated search hits / remixes if exact record absent."""
    return normalize(getattr(song, 'artist', '')) == normalize(artist) and normalize(getattr(song, 'title', '')) == normalize(title)


def safe_filename(name):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '', name)
    name = re.sub(r'\s+', ' ', name).strip(' .')[:140].rstrip(' .')
    return name or 'VK track'


def download_one(service, song, folder, index):
    # VKpyMusic may create ./Music internally, so keep its cwd inside the job folder.
    downloaded = service.save_music(song, overwrite=True)
    if not downloaded:
        raise RuntimeError('VK не предоставил загружаемый аудиофайл.')
    src = Path(downloaded).resolve()
    if not src.is_file() or src.stat().st_size == 0:
        raise RuntimeError('Сохранённый файл отсутствует или пуст.')
    if src.suffix.casefold() != '.mp3':
        raise RuntimeError('VKpyMusic не вернул MP3 файл.')
    name = safe_filename(f'{song.artist} - {song.title}')
    dest = folder / f'{index:03d} - {name}.mp3'
    if src != dest:
        shutil.move(str(src), str(dest))
    return str(dest.resolve())


class _AuthLog(logging.Handler):
    """Collects VKpyMusic log lines to explain a failed login. Never printed."""

    def __init__(self):
        super().__init__()
        self.lines = []

    def emit(self, record):
        self.lines.append(record.getMessage())

    def has(self, text):
        return any(text in line for line in self.lines)


def auth_failure_message(log):
    if log.has('Password bruteforce attempt'):
        return ('VK временно ограничил вход: слишком много попыток. Не повторяйте сразу: '
                'подождите несколько часов или попробуйте из другой сети.')
    if log.has('Login or password is invalid'):
        return 'VK не принял логин или пароль. Проверьте их и повторите.'
    return 'Не удалось войти в VK. Проверьте вывод выше.'


def interactive_auth(config, client_name='kate'):
    from vkpymusic import TokenReceiver
    from vkpymusic.client import KateMobileClient, VkMobileClient
    client = {'kate': KateMobileClient, 'vk': VkMobileClient}[client_name]
    print('Cave Player: вход в VK Музыку через VKpyMusic. Пароль не сохраняется.', flush=True)
    print('Авторизация может потребовать SMS, приложение 2FA или капчу.', flush=True)
    login = input('Телефон или логин VK: ').strip()
    password = getpass.getpass('Пароль VK (ввод скрыт): ')
    if not login or not password:
        raise ValueError('Логин и пароль не могут быть пустыми.')
    receiver = TokenReceiver(login, password, client=client)
    del password
    auth_log = _AuthLog()
    receiver._logger.addHandler(auth_log)
    if not receiver.auth():
        raise RuntimeError(auth_failure_message(auth_log))
    # VKpyMusic stores token and user agent in a local INI file.
    receiver.save_to_config(str(config))
    if not config.is_file():
        raise RuntimeError('VKpyMusic не сохранил настройки авторизации.')
    try:
        os.chmod(config, 0o600)
    except OSError:
        pass
    print('Авторизация успешна. Теперь выберите «VK Музыка» в Cave Player.', flush=True)


def download(config, folder, raw):
    from vkpymusic import Service
    if not config.is_file():
        raise RuntimeError('Сначала нажмите «Войти в VK» в настройках загрузчика.')
    service = Service.parse_config(str(config))
    if service is None:
        raise RuntimeError('Авторизация VK отсутствует или истекла. Войдите ещё раз.')
    mode, value = parse_input(raw)
    songs = []
    if mode == 'search':
        artist, title = value
        songs = [s for s in service.search_songs_by_text(f'{artist} {title}', 20) if song_matches(s, artist, title)][:1]
        if not songs:
            raise RuntimeError('Точное совпадение артиста и названия в VK не найдено.')
    elif mode == 'audio':
        songs = service.get_songs_by_id(value)
    elif mode == 'playlist':
        owner, playlist, access_key = value
        # Bounded pagination; no loop if VK unexpectedly repeats a page.
        seen = set()
        for offset in range(0, 500, 100):
            page = service.get_songs_by_playlist_id(owner, playlist, access_key, 100, offset)
            fresh = [s for s in page if (str(s.owner_id), str(s.track_id)) not in seen]
            if not fresh:
                break
            songs.extend(fresh)
            seen.update((str(s.owner_id), str(s.track_id)) for s in fresh)
            if len(page) < 100:
                break
    if not songs:
        raise RuntimeError('В VK нет доступных аудиозаписей по этому запросу.')
    emit('total', count=len(songs))
    failed = 0
    for index, song in enumerate(songs, 1):
        label = f'{song.artist} - {song.title}'
        try:
            output = download_one(service, song, folder, index)
            emit('track', file=output, artist=str(song.artist), title=str(song.title), duration=int(song.duration or 0))
        except Exception:
            failed += 1
            emit('failed', title=label, message='Трек недоступен для сохранения или произошла ошибка VKpyMusic.')
    emit('complete', failed=failed)
    if failed == len(songs):
        raise RuntimeError('Ни один трек VK не был сохранён.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=('auth', 'download'))
    parser.add_argument('--config', required=True)
    parser.add_argument('--output')
    parser.add_argument('--input')
    parser.add_argument('--client', choices=('kate', 'vk'), default='kate')
    a = parser.parse_args()
    config = Path(a.config).resolve()
    if a.mode == 'auth':
        config.parent.mkdir(parents=True, exist_ok=True)
        interactive_auth(config, a.client)
        return
    if not a.output or not a.input:
        raise ValueError('Не задан запрос или каталог назначения.')
    folder = Path(a.output).resolve()
    folder.mkdir(parents=True, exist_ok=True)
    os.chdir(folder)
    download(config, folder, a.input)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Avoid leaking token, password or authenticated audio URLs in logs.
        message = str(exc) if isinstance(exc, (ValueError, RuntimeError)) else 'Ошибка VKpyMusic или сетевого соединения.'
        emit('error', message=message)
        sys.exit(1)
