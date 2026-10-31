// Bandcamp: only explicitly selected, playable track/album pages.
// yt-dlp supports Bandcamp track and album extractors. This is a recording of
// available audio streams, NOT a purchase or a lossless original download.
import 'dart:convert';

import 'tools.dart';

class BandcampInfo {
  final String title;
  final int? count;
  const BandcampInfo(this.title, this.count);
}

class Bandcamp {
  static Uri? supportedUri(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty || uri.hasPort || uri.host.isEmpty) return null;
    final host = uri.host.toLowerCase();
    if (host != 'bandcamp.com' && !host.endsWith('.bandcamp.com')) return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || !['track', 'album'].contains(segments[0])) return null;
    // Skip homepages, radio, user profile and search URLs.
    return uri;
  }

  static bool accepts(String input) => supportedUri(input) != null;
  static bool isAlbum(String input) => supportedUri(input)?.pathSegments.first == 'album';

  /// Only used if the site does not supply album/title metadata in the track.
  static String slug(String input) => Uri.tryParse(input)?.pathSegments.last ?? 'Bandcamp';

  /// Probe album size so partial uploads are correctly reported as partial failures.
  /// Probing can fail (site update, throttling); in that case downloads still run.
  static Future<BandcampInfo?> inspect(Tools tools, String input) async {
    if (!accepts(input) || !isAlbum(input)) return null;
    try {
      final output = await Tools.run(tools.ytdlp.path, [
        ...tools.jsArgs, '--flat-playlist', '--dump-single-json', '--no-warnings', input,
      ]);
      final raw = output.firstWhere((line) => line.startsWith('{'), orElse: () => '');
      if (raw.isEmpty) return null;
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final entries = data['entries'];
      return BandcampInfo('${data['title'] ?? slug(input)}', entries is List ? entries.length : null);
    } catch (_) {
      return null;
    }
  }

  /// Used to ignore dangerous unrelated links even when manually pasted.
  static bool youtubeUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.userInfo.isNotEmpty || uri.hasPort) return false;
    final host = uri.host.toLowerCase();
    return host == 'youtu.be' || host == 'youtube.com' || host.endsWith('.youtube.com');
  }
}
