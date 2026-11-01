// Local, optional Deezer backend. Adapted from the user-supplied standalone module.
// Session credentials are read from tools/deezer_auth.ini, never from source control.
import 'dart:convert';
import 'dart:io';
import 'tools.dart';
import 'winproc.dart';

class DeezerTrack {
  final File file;
  final String artist, title;
  const DeezerTrack(this.file, this.artist, this.title);
}
class DeezerResult {
  final int total, failed;
  final List<DeezerTrack> tracks;
  const DeezerResult(this.total, this.failed, this.tracks);
}
class DeezerMusic {
  static const version = '2.15.0';
  static File python(Tools t) => File('${t.dir.path}/deezer-python/Scripts/python.exe');
  static File config(Tools t) => File('${t.dir.path}/deezer_auth.ini');
  static File bridge(Tools t) => File('${t.dir.path}/deezer_bridge.py');

  static bool accepts(String q) {
    if (q.trim().isEmpty) return false;
    if (!q.contains('://')) {
      final p = q.trim().split(RegExp(r'\s+[-–—]\s+'));
      return p.length == 2 && p.every((x) => x.trim().isNotEmpty);
    }
    final u = Uri.tryParse(q);
    return u != null && (u.scheme == 'https' || u.scheme == 'http') &&
        u.userInfo.isEmpty && !u.hasPort &&
        (u.host == 'deezer.com' || u.host == 'www.deezer.com') &&
        RegExp(r'^/(?:[a-z]{2}(?:-[a-z]{2})?/)?(?:track|album|playlist)/\d+/?$',caseSensitive:false).hasMatch(u.path);
  }

  static Future<void> prepareConfig(Tools t) async {
    await t.dir.create(recursive:true);
    final f = config(t);
    if (await f.exists()) return;
    final env = Platform.environment['CAVE_DEEZER_ARL']?.trim() ?? '';
    final arl = RegExp(r'^[a-fA-F0-9]{64,256}$').hasMatch(env) ? env : 'PASTE_ARL_COOKIE_HERE';
    await f.writeAsString('[deezer]\n'
        '# Локальный файл! Не добавляйте в GitHub или общую библиотеку.\n'
        'arl = $arl\nquality = mp3\n', flush:true);
  }
  static Future<void> prepareBridge(Tools t) async {
    await t.dir.create(recursive:true);
    if (!await bridge(t).exists()) {
      await bridge(t).writeAsString(_script, encoding:utf8, flush:true);
    }
  }
  static Future<int> runProcess(String exe,List<String> args,void Function(String) log) async {
    if (Platform.isWindows) return WinProc.run(exe,args,log);
    final p = await Process.start(exe,args);
    await Future.wait([
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(log),
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(log)]);
    return p.exitCode;
  }
  static Future<void> install(Tools t,void Function(String) log) async {
    if (!Platform.isWindows) throw UnsupportedError('Deezer: автоустановка только Windows.');
    await prepareConfig(t);
    await prepareBridge(t);
    final exe = python(t);
    if (await exe.exists()) {
      final code = await runProcess(exe.path,['-c','import deezer_downloader; from importlib.metadata import version; assert version("deezer-downloader") == "$version"'],(_){});
      if (code == 0) { log('Deezer установлен.'); return; }
    }
    String? found;
    List<String> prefix = [];
    for (final c in <(String,List<String>)>[('py.exe',['-3.13']),('py.exe',['-3']),('python.exe',[])]) {
      try {
        if (await runProcess(c.$1,[...c.$2,'-c','import sys; assert (3,10) <= sys.version_info[:2] < (4,0)'],(_){}) == 0) {
          found = c.$1; prefix = c.$2; break;
        }
      } catch (_) {}
    }
    if (found == null) throw Exception('Не найден Python 3.10+. Установите его и перезапустите плеер.');
    log('Создаю виртуальное окружение Python…');
    if (await runProcess(found,[...prefix,'-m','venv',exe.parent.parent.path],log) != 0 || !await exe.exists()) {
      throw Exception('Не удалось создать Python venv.');
    }
    log('Устанавливаю deezer-downloader $version…');
    if (await runProcess(exe.path,['-m','pip','install','--no-input','--disable-pip-version-check','deezer-downloader==$version'],log) != 0) {
      throw Exception('pip не смог установить deezer-downloader.');
    }
    log('Укажите ARL своей сессии в локальном deezer_auth.ini.');
  }
  static Future<DeezerResult> download(Tools t,String query,Directory output,void Function(String) log) async {
    if (!accepts(query)) throw FormatException('Deezer: укажите «Исполнитель - Название» или ссылку Deezer.');
    if (!await python(t).exists()) throw Exception('Deezer не установлен. Используйте настройки загрузчика.');
    await prepareConfig(t); await prepareBridge(t); await output.create(recursive:true);
    final tracks=<DeezerTrack>[];
    var total=0,failed=0;
    String? error;
    void line(String s) {
      if (!s.startsWith('@cavedeezer:')) return;
      try {
        final e=jsonDecode(s.substring(12));
        if (e is! Map) return;
        switch(e['type']) {
          case 'total': total=(e['count'] as num?)?.toInt()??0;
          case 'failed': failed++; log('Deezer: недоступная запись.');
          case 'error': error='${e['message']}';
          case 'track':
            final f=File('${e['file']??''}').absolute;
            if (!f.path.toLowerCase().startsWith('${output.absolute.path.toLowerCase()}${Platform.pathSeparator}')) return;
            if (!['.mp3','.flac'].any((x)=>f.path.toLowerCase().endsWith(x))) return;
            tracks.add(DeezerTrack(f,'${e['artist']??''}','${e['title']??''}'));
        }
      } catch (_) {}
    }
    final exit=await runProcess(python(t).path,[bridge(t).path,'--config',config(t).path,
      '--output',output.absolute.path,'--input',query],line);
    if (tracks.isEmpty) throw Exception('Deezer: ${error??'нет доступных записей'} (код $exit).');
    return DeezerResult(total>0?total:tracks.length+failed,failed,tracks);
  }

  static const _script=r'''from __future__ import annotations
import argparse, configparser, json, re, sys, unicodedata
from pathlib import Path
from urllib.parse import urlsplit
def event(kind, **fields):
    print('@cavedeezer:'+json.dumps(dict(type=kind,**fields),ensure_ascii=True),flush=True)
def norm(s):
    return ' '.join(re.findall(r'[^\W_]+',unicodedata.normalize('NFKC',str(s)).casefold()))
def parse(q):
    if '://' not in q:
        m=re.fullmatch(r'(.+?)\s+[-–—]\s+(.+)',q.strip())
        if not m: raise ValueError('bad search')
        return ('search',m.groups())
    u=urlsplit(q)
    if u.scheme not in ('http','https') or u.hostname not in ('deezer.com','www.deezer.com') or u.username or u.port:
        raise ValueError('bad url')
    m=re.fullmatch(r'(?:(?:[a-z]{2}(?:-[a-z]{2})?)/)?(track|album|playlist)/(\d+)',u.path.strip('/'),re.I)
    if not m: raise ValueError('bad path')
    return (m.group(1).lower(),m.group(2))
def run(args):
    kind,key=parse(args.input)
    c=configparser.ConfigParser(interpolation=None)
    if not c.read(args.config,encoding='utf-8'): raise ValueError('no config')
    arl=c.get('deezer','arl',fallback='').strip()
    quality=c.get('deezer','quality',fallback='mp3').strip().lower()
    if len(arl)<20 or arl=='PASTE_ARL_COOKIE_HERE' or any(x.isspace() for x in arl) or quality not in ('mp3','flac'):
        raise ValueError('no valid auth')
    from deezer_downloader import configuration
    settings=configparser.ConfigParser(interpolation=None)
    settings['deezer']={'cookie_arl':arl,'quality':quality}
    settings['proxy']={'server':''}
    configuration.config=settings
    from deezer_downloader import deezer as dz
    dz.init_deezer_session('',quality)
    if kind=='search':
        artist,title=key
        found=next((s for s in dz.deezer_search(f'{artist} {title}',dz.TYPE_TRACK)
                    if norm(s.get('artist',''))==norm(artist) and norm(s.get('title',''))==norm(title)),None)
        if found is None: raise RuntimeError('no exact match')
        songs=[dz.get_song_infos_from_deezer_website(dz.TYPE_TRACK,found['id'])]
    elif kind=='track': songs=[dz.get_song_infos_from_deezer_website(dz.TYPE_TRACK,key)]
    elif kind=='album': songs=list(dz.get_song_infos_from_deezer_website(dz.TYPE_ALBUM,key))[:500]
    else: songs=list(dz.parse_deezer_playlist(str(key))[1])[:500]
    out=Path(args.output).resolve()
    out.mkdir(parents=True,exist_ok=True)
    event('total',count=len(songs))
    done=0
    for i,s in enumerate(songs):
        artist=str(s.get('ART_NAME') or '')
        title=str(s.get('SNG_TITLE') or '')
        sid=str(s.get('SNG_ID') or '')
        ext=dz.get_file_extension()
        if not sid.isdecimal() or ext not in ('mp3','flac'):
            event('failed')
            continue
        clean=lambda t: re.sub(r'[<>:"/\\|?*\x00-\x1f]','',t).strip(' .')[:120]
        path=out/f'{i+1:03d} - {clean(artist)} - {clean(title)} - {sid}.{ext}'
        try:
            dz.download_song(s,str(path))
            if not path.is_file() or path.stat().st_size<1024: raise RuntimeError('empty')
            event('track',file=str(path),artist=artist,title=title)
            done+=1
        except Exception:
            path.unlink(missing_ok=True)
            event('failed')
    if not done: raise RuntimeError('no audio')
if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('--config',required=True)
    ap.add_argument('--output',required=True)
    ap.add_argument('--input',required=True)
    a=ap.parse_args()
    try: run(a)
    except Exception:
        event('error',message='Проверьте локальный ARL, доступ Deezer и название трека.')
        sys.exit(1)
''';
}
