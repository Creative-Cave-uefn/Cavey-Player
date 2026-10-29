import 'package:flutter/material.dart';

import '../app.dart';
import 'theme.dart';
import 'widgets.dart';

class _Frame extends StatelessWidget {
  final List<Widget> children;
  final double width;
  const _Frame({required this.children, this.width = 460});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  final String? error;
  const _ErrorText(this.error);
  @override
  Widget build(BuildContext context) => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(error!, style: const TextStyle(color: C.danger, height: 1.4)),
        );
}

/// Ключи Google не вшиты в сборку — просим ввести вручную
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _id = TextEditingController();
  final _secret = TextEditingController();
  String? _error;

  Future<void> _save() async {
    final app = Services.of(context);
    final id = _id.text.trim(), secret = _secret.text.trim();
    if (!id.endsWith('.apps.googleusercontent.com')) {
      setState(() => _error = 'Client ID заканчивается на .apps.googleusercontent.com — проверьте, что скопировали его целиком.');
      return;
    }
    if (secret.isEmpty) {
      setState(() => _error = 'Вставьте Client secret из того же экрана Google Cloud.');
      return;
    }
    app.settings
      ..clientId = id
      ..clientSecret = secret;
    await app.lib.saveSettings();
    app.accounts.configChanged();
  }

  @override
  Widget build(BuildContext context) {
    return _Frame(children: [
      const Wordmark(size: 30),
      const SizedBox(height: 32),
      Text('Ключ для входа через Google', style: display(20)),
      const SizedBox(height: 10),
      const Text(
        'Полка входит в Google от имени вашего приложения в Google Cloud. '
        'Создайте его по инструкции из README (раздел «Ключи Google») и вставьте сюда оба значения. '
        'Это нужно сделать один раз.',
        style: TextStyle(color: C.muted, height: 1.5),
      ),
      const SizedBox(height: 24),
      TextField(controller: _id, decoration: const InputDecoration(hintText: 'Client ID')),
      const SizedBox(height: 12),
      TextField(
        controller: _secret,
        obscureText: true,
        decoration: const InputDecoration(hintText: 'Client secret'),
        onSubmitted: (_) => _save(),
      ),
      _ErrorText(_error),
      const SizedBox(height: 24),
      FilledButton(onPressed: _save, child: const Text('Сохранить')),
    ]);
  }
}

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  String? _error;

  Future<void> _signIn() async {
    final app = Services.of(context);
    setState(() => _error = null);
    try {
      await app.accounts.signIn();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.accounts,
      builder: (context, _) => _Frame(width: 520, children: [
        const Wordmark(size: 44),
        const SizedBox(height: 36),
        Text('Общая музыка для своих', style: display(26)),
        const SizedBox(height: 14),
        const Text(
          'Музыка лежит в ваших папках на Google Диске. Полка собирает её в одну библиотеку '
          'с общими плейлистами и лайками и играет прямо с Диска, ничего не скачивая.',
          style: TextStyle(color: C.muted, fontSize: 16, height: 1.55),
        ),
        const SizedBox(height: 32),
        if (!app.accounts.signingIn)
          FilledButton.icon(
            onPressed: _signIn,
            icon: const Icon(Icons.login_rounded, size: 18),
            label: const Text('Войти через Google'),
          )
        else
          Row(children: [
            const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 14),
            const Expanded(child: Text('Продолжите вход в открывшемся браузере', style: TextStyle(color: C.muted))),
            TextButton(onPressed: app.accounts.cancelSignIn, child: const Text('Отменить')),
          ]),
        const SizedBox(height: 14),
        const Text(
          'Google спросит разрешения. Обязательно отметьте доступ к Google Диску, иначе Полка не увидит музыку.',
          style: TextStyle(color: C.faint, fontSize: 13, height: 1.45),
        ),
        _ErrorText(_error),
      ]),
    );
  }
}

/// Создать свою «Полку» или подключиться к полке друга
class HubScreen extends StatefulWidget {
  const HubScreen({super.key});
  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> {
  final _link = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() fn) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final me = app.accounts.primary!;
    return _Frame(width: 560, children: [
      const Wordmark(size: 30),
      const SizedBox(height: 32),
      Text('Где будет ваша полка?', style: display(24)),
      const SizedBox(height: 10),
      Text(
        'Полка — это папка на Google Диске, где хранятся общие плейлисты и лайки. '
        'Её создаёт кто-то один, остальные подключаются по ссылке. Вы вошли как ${me.email}.',
        style: const TextStyle(color: C.muted, height: 1.5),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: _busy || app.accounts.signingIn
              ? null
              : () => _run(() async {
                    final acc = await app.accounts.signIn(loginHint: me.email);
                    await app.accounts.setPrimary(acc.email);
                  }),
          child: const Text('Войти заново или другим аккаунтом'),
        ),
      ),
      const SizedBox(height: 16),
      _Option(
        title: 'Подключиться к полке друга',
        text: 'Попросите ссылку на папку «Полка». Друг должен поделиться ею с вашей почтой с правами редактора.',
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _link,
              enabled: !_busy,
              decoration: const InputDecoration(hintText: 'Ссылка на папку'),
              onSubmitted: (_) => _run(() => app.lib.joinHub(_link.text)),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _busy ? null : () => _run(() => app.lib.joinHub(_link.text)),
            child: const Text('Подключиться'),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      _Option(
        title: 'Создать новую полку',
        text: 'На вашем Диске появится папка «Полка». Потом поделитесь ею с друзьями.',
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _busy ? null : () => _run(() => app.lib.createHub(me.email)),
            child: const Text('Создать полку'),
          ),
        ),
      ),
      if (_busy) const Padding(padding: EdgeInsets.only(top: 20), child: LinearProgressIndicator()),
      _ErrorText(_error),
    ]);
  }
}

class _Option extends StatelessWidget {
  final String title;
  final String text;
  final Widget child;
  const _Option({required this.title, required this.text, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(text, style: const TextStyle(color: C.muted, height: 1.45)),
        const SizedBox(height: 16),
        child,
      ]),
    );
  }
}
