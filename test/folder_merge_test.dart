import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/models.dart';

void main() {
  test('folder merging preserves Google file IDs, playlists, likes', () {
    final data = LibraryData();
    for (final name in ['old','new']) {
      data.apply({'op':'addSource','source':{'id':name,'name':name,'by':'me','at':1}});
    }
    data.apply({'op':'upsertTracks','tracks':{
      'drive-track-1':{'s':'old','t':'Test','path':'Album'},
      'drive-track-2':{'s':'new','t':'Other'},
    }});
    data.apply({'op':'createPlaylist','playlist':{
      'id':'playlist','name':'Playlist','by':'me','at':1,'items':['drive-track-1']
    }});
    data.apply({'op':'like','id':'drive-track-1','email':'me','on':true});
    final op = {'op':'relocateSourceTracks','from':'old','to':'new',
      'paths':{'drive-track-1':'Album'}};
    data.apply(op);
    data.apply(op);
    data.apply({'op':'removeSource','id':'old'});
    expect(data.tracks['drive-track-1']?.source, 'new');
    expect(data.tracks['drive-track-1']?.path, 'Album');
    expect(data.tracks['drive-track-2']?.source, 'new');
    expect(data.playlists.single.items, ['drive-track-1']);
    expect(data.likes['drive-track-1'], {'me'});
    expect(data.sources.map((s)=>s.id), ['new']);
  });
}
