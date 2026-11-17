import 'dart:convert';
import 'dart:io';
import '../lib/core/dj_effects.dart';
void main(List<String> args) => File(args.single).writeAsStringSync(jsonEncode({
  for (final effect in DjEffect.values.where((e)=>e!=DjEffect.none))
    effect.name: djEffectGraph(effect,input:'[in]',output:'[out]',start:0,length:4,beat:0.5)
}));
