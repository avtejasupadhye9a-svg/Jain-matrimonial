// ignore_for_file: deprecated_member_use
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:jain_client/jain_client.dart';

class AdminLogin extends StatefulWidget {
  const AdminLogin({super.key, required this.api});
  final Api api;

  @override
  State<AdminLogin> createState() => _AdminLoginState();
}

class _AdminLoginState extends State<AdminLogin> {
  final password = TextEditingController();
  final form = GlobalKey<FormState>();
  bool busy = false;
  String? error;

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.signInAdmin(password.text);
    } on ApiError catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) {
        password.clear();
        setState(() => busy = false);
      }
    }
  }

  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 390,
          child: Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Jain Matrimonial',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 6),
                const Text('Administrator sign-in'),
                const SizedBox(height: 24),
                _PasswordField(
                  label: 'Password',
                  controller: password,
                  enabled: !busy,
                  validator: _required,
                  autofocus: true,
                  onSubmitted: (_) => submit(),
                ),
                if (error != null) _FormError(error!),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(busy ? 'Signing in…' : 'Login'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class AdminPasswordSettings extends StatefulWidget {
  const AdminPasswordSettings({super.key, required this.api});
  final Api api;

  @override
  State<AdminPasswordSettings> createState() => _AdminPasswordSettingsState();
}

class _AdminPasswordSettingsState extends State<AdminPasswordSettings> {
  final form = GlobalKey<FormState>();
  final current = TextEditingController();
  final next = TextEditingController();
  final confirmation = TextEditingController();
  bool busy = false;
  String? error;

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.changeAdminPassword(
        current.text,
        next.text,
        confirmation.text,
      );
      if (messenger.mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Password changed. Sign in with your new password.'),
          ),
        );
      }
    } on ApiError catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    current.dispose();
    next.dispose();
    confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Form(
            key: form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Change Password',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text('Saving signs you out of all Admin sessions.'),
                const SizedBox(height: 20),
                _PasswordField(
                  label: 'Current password',
                  controller: current,
                  enabled: !busy,
                  validator: _required,
                ),
                const SizedBox(height: 12),
                _PasswordField(
                  label: 'New password',
                  controller: next,
                  enabled: !busy,
                  validator: (value) {
                    if (value == null ||
                        value.trim().isEmpty ||
                        value.runes.length < 20 ||
                        utf8.encode(value).length > 256) {
                      return 'Use at least 20 characters and at most 256 UTF-8 bytes.';
                    }
                    if (value == current.text) {
                      return 'Choose a different password.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                _PasswordField(
                  label: 'Confirm new password',
                  controller: confirmation,
                  enabled: !busy,
                  validator: (value) => value == next.text
                      ? null
                      : 'The new passwords do not match.',
                ),
                if (error != null) _FormError(error!),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : save,
                  child: Text(busy ? 'Saving…' : 'Change Password'),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

String? _required(String? text) =>
    text == null || text.isEmpty ? 'Enter the password.' : null;

class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.label,
    required this.controller,
    required this.enabled,
    required this.validator,
    this.autofocus = false,
    this.onSubmitted,
  });
  final String label;
  final TextEditingController controller;
  final bool enabled;
  final FormFieldValidator<String> validator;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    decoration: InputDecoration(labelText: label),
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    enabled: enabled,
    autofocus: autofocus,
    textInputAction: onSubmitted == null
        ? TextInputAction.next
        : TextInputAction.done,
    onFieldSubmitted: onSubmitted,
    validator: validator,
  );
}

class _FormError extends StatelessWidget {
  const _FormError(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}
