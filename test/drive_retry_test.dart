import 'package:cave_player/core/auth.dart';
import 'package:cave_player/core/drive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Accounts implements AccountManager {
  @override
  Future<String> token(String email, {bool force = false}) async => 'test-token';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('Drive GET retries connection closed before response headers', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      if (attempts == 1) {
        throw http.ClientException(
            'Connection closed before full header was received', request.url);
      }
      return http.Response('{"files":[]}', 200);
    });
    final api = DriveApi(_Accounts(), client: client);
    final response = await api.send('test@example.com', 'GET', DriveApi.api('files'));
    expect(response.statusCode, 200);
    expect(attempts, 2);
    client.close();
  });

  test('Drive upload requests never replay after ambiguous disconnect', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      throw http.ClientException('Connection closed before headers', request.url);
    });
    final api = DriveApi(_Accounts(), client: client);
    await expectLater(
      api.send('test@example.com', 'POST', DriveApi.api('files'),
          body: <int>[1, 2, 3]),
      throwsA(isA<DriveException>().having((e) => e.status, 'status', 503)),
    );
    expect(attempts, 1);
    client.close();
  });

  test('Drive GET does not retry permission failures', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      return http.Response('{"error":{"message":"Forbidden"}}', 403);
    });
    final api = DriveApi(_Accounts(), client: client);
    await expectLater(api.send('test@example.com', 'GET', DriveApi.api('files')),
        throwsA(isA<DriveException>().having((e) => e.status, 'status', 403)));
    expect(attempts, 1);
    client.close();
  });
}
