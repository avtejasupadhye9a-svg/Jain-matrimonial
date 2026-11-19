import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'api.dart';

ThemeData jainTheme() => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff6f2c4b),
    surface: const Color(0xfffff9f5),
  ),
  useMaterial3: true,
  inputDecorationTheme: const InputDecorationTheme(
    border: OutlineInputBorder(),
  ),
);

Future<bool> confirm(
  BuildContext context,
  String title,
  String explanation,
) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(explanation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    ) ??
    false;

Future<String?> prompt(
  BuildContext context,
  String title,
  String field, {
  String initial = '',
}) async {
  var value = initial;
  return showDialog<String>(
    context: context,
    useRootNavigator: false,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: TextFormField(
        initialValue: initial,
        autofocus: true,
        onChanged: (next) => value = next,
        decoration: InputDecoration(labelText: field),
        onFieldSubmitted: (_) => Navigator.pop(dialog, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, value.trim()),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
}

Future<void> runAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
    }
  } catch (error) {
    if (context.mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

Future<Json?> enterCode(BuildContext context, Json response) async {
  final hint = response['localTestCode'];
  final code = await prompt(
    context,
    hint == null ? 'Verify your email' : 'Local test code $hint',
    '6-digit code',
  );
  if (code == null || code.isEmpty) return null;
  return {'challengeId': response['challengeId'], 'code': code};
}

class SignIn extends StatefulWidget {
  const SignIn({super.key, required this.api, required this.role});
  final Api api;
  final String role;

  @override
  State<SignIn> createState() => _SignInState();
}

class _SignInState extends State<SignIn> {
  final email = TextEditingController();
  final form = GlobalKey<FormState>();
  bool busy = false;

  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() => busy = true);
    await runAction(context, () async {
      final response = await widget.api.requestCode(email.text.trim());
      if (!mounted) return;
      final code = await enterCode(context, response);
      if (code != null) {
        await widget.api.signIn(
          code['challengeId'] as String,
          code['code'] as String,
          widget.role,
        );
      }
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  widget.role == 'admin'
                      ? Icons.admin_panel_settings_outlined
                      : Icons.favorite_border,
                  size: 52,
                ),
                const SizedBox(height: 24),
                Text(
                  'Jain Matrimonial',
                  style: Theme.of(context).textTheme.headlineMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.role == 'admin'
                      ? 'Administrator sign-in'
                      : 'Sign in or create your account',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                TextFormField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email address'),
                  validator: (value) => (value ?? '').contains('@')
                      ? null
                      : 'Enter your email address',
                  onFieldSubmitted: (_) => submit(),
                ),
                if (widget.api.localDebug) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    obscureText: true,
                    onChanged: (value) => widget.api.fixtureKey = value,
                    initialValue: widget.api.fixtureKey,
                    decoration: const InputDecoration(
                      labelText: 'Local fixture key (optional)',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(
                    busy ? 'Please wait…' : 'Email a verification code',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Use an email you can access. Codes expire after 10 minutes.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class SessionGate extends StatefulWidget {
  const SessionGate({
    super.key,
    required this.api,
    required this.role,
    required this.home,
  });
  final Api api;
  final String role;
  final Widget Function(BuildContext) home;
  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  late Future<void> loading;
  @override
  void initState() {
    super.initState();
    load();
  }

  void load() {
    loading = widget.api.restore().then((_) async {
      final account = widget.api.account;
      if (account != null && account.role != widget.role)
        await widget.api.clear();
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: loading,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError) {
        return Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => setState(load),
              child: const Text('Retry connection'),
            ),
          ),
        );
      }
      return ListenableBuilder(
        listenable: widget.api,
        builder: (context, _) => widget.api.account == null
            ? SignIn(api: widget.api, role: widget.role)
            : widget.home(context),
      );
    },
  );
}

class RemotePanel extends StatefulWidget {
  const RemotePanel({super.key, required this.load, required this.builder});
  final Future<Json> Function() load;
  final Widget Function(BuildContext, Json, VoidCallback) builder;
  @override
  State<RemotePanel> createState() => _RemotePanelState();
}

class _RemotePanelState extends State<RemotePanel> {
  late Future<Json> data = widget.load();
  void refresh() {
    if (!mounted) return;
    final next = widget.load();
    setState(() {
      data = next;
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: data,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(snapshot.error.toString()),
                OutlinedButton(onPressed: refresh, child: const Text('Retry')),
              ],
            ),
          ),
        );
      }
      return widget.builder(context, snapshot.requireData, refresh);
    },
  );
}

Widget empty(String message) => Center(
  child: Padding(padding: const EdgeInsets.all(24), child: Text(message)),
);
