// One strict URL classifier used by all download modes.
// Catalog links supply metadata; explicitly supported media pages use yt-dlp.
// Never pass arbitrary user-provided HTTP addresses to a generic extractor.
enum MusicSource {
  text,
  spotify,
  deezer,
  appleMusic,
  yandexMusic,
  youtube,
  bandcamp,
  soundcloud,
  audiomack,
  mixcloud,
  internetArchive,
  unsupported,
}

class MusicLink {
  final String input;
  final MusicSource source;
  const MusicLink._(this.input, this.source);

  bool get isLink => source != MusicSource.text;
  bool get isSupported => source != MusicSource.unsupported;
  bool get isCatalog => const {
    MusicSource.spotify, MusicSource.deezer,
    MusicSource.appleMusic, MusicSource.yandexMusic,
  }.contains(source);
  bool get isDirectAudio => const {
    MusicSource.youtube, MusicSource.bandcamp, MusicSource.soundcloud,
    MusicSource.audiomack, MusicSource.mixcloud,
    MusicSource.internetArchive,
  }.contains(source);

  bool get isYouTubePlaylist => source == MusicSource.youtube &&
      (Uri.tryParse(input)?.queryParameters.containsKey('list') ?? false) &&
      (Uri.tryParse(input)?.path.toLowerCase().contains('playlist') ?? false);
  bool get isCollection =>
      isYouTubePlaylist ||
      (source == MusicSource.soundcloud && Uri.tryParse(input)?.pathSegments.contains('sets') == true) ||
      (source == MusicSource.bandcamp && Uri.tryParse(input)?.pathSegments.contains('album') == true);

  static bool _domain(String host, String root) =>
      host == root || host.endsWith('.$root');

  static MusicLink parse(String original) {
    final input = original.trim();
    if (input.isEmpty) return const MusicLink._('', MusicSource.text);
    if (RegExp(r'^spotify:(track|album|playlist):[A-Za-z0-9]+$', caseSensitive: false).hasMatch(input)) {
      return MusicLink._(input, MusicSource.spotify);
    }
    final uri = Uri.tryParse(input);
    if (uri == null) return MusicLink._(input, MusicSource.unsupported);
    if (!uri.hasScheme) return MusicLink._(input, MusicSource.text);
    // Explicitly require an HTTP(S) URL with no userinfo or custom port.
    if (!['http', 'https'].contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasPort) {
      return MusicLink._(input, MusicSource.unsupported);
    }
    final host = uri.host.toLowerCase();
    if (host == 'open.spotify.com') return MusicLink._(input, MusicSource.spotify);
    if (host == 'deezer.com' || host == 'www.deezer.com') {
      return MusicLink._(input, MusicSource.deezer);
    }
    if (host == 'music.apple.com') return MusicLink._(input, MusicSource.appleMusic);
    if (const {'music.yandex.ru', 'music.yandex.com', 'music.yandex.by', 'music.yandex.kz'}.contains(host)) {
      return MusicLink._(input, MusicSource.yandexMusic);
    }
    if (host == 'youtu.be' || _domain(host, 'youtube.com') ||
        host == 'youtube-nocookie.com' || host == 'www.youtube-nocookie.com') {
      return MusicLink._(input, MusicSource.youtube);
    }
    if (_domain(host, 'bandcamp.com') &&
        RegExp(r'^/(track|album)/[^/]+/?$').hasMatch(uri.path)) {
      return MusicLink._(input, MusicSource.bandcamp);
    }
    if (_domain(host, 'soundcloud.com') && uri.pathSegments.any((s) => s.isNotEmpty)) {
      return MusicLink._(input, MusicSource.soundcloud);
    }
    if (_domain(host, 'audiomack.com') && uri.pathSegments.any((s) => s.isNotEmpty)) {
      return MusicLink._(input, MusicSource.audiomack);
    }
    if (_domain(host, 'mixcloud.com') && uri.pathSegments.any((s) => s.isNotEmpty)) {
      return MusicLink._(input, MusicSource.mixcloud);
    }
    if (host == 'archive.org' && uri.pathSegments.contains('details')) {
      return MusicLink._(input, MusicSource.internetArchive);
    }
    return MusicLink._(input, MusicSource.unsupported);
  }
}
