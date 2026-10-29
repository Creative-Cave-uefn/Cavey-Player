import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final app = await AppServices.create();
  runApp(CavePlayerApp(app: app));
}
