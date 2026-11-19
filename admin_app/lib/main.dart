// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:jain_client/jain_client.dart';

import 'review.dart';
import 'admin_password.dart';

void main() => runApp(AdminApp(api: Api(persistSession: false)));

class AdminApp extends StatelessWidget {
  const AdminApp({super.key, required this.api});
  final Api api;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Jain Matrimonial',
    theme: jainTheme(),
    home: SessionGate(
      api: api,
      role: 'admin',
      signIn: (_) => AdminLogin(api: api),
      home: (_) => Navigator(
        key: ValueKey(api.account!.id),
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => AdminHome(api: api)),
      ),
    ),
  );
}

const groups = <String, (String, IconData)>{
  'dashboard': ('Dashboard', Icons.space_dashboard_outlined),
  'profiles': ('Profiles', Icons.people_outline),
  'revisions': ('Profile reviews', Icons.fact_check_outlined),
  'claims': ('Claims', Icons.verified_user_outlined),
  'accounts': ('Accounts', Icons.manage_accounts_outlined),
  'interests': ('Interests', Icons.favorite_border),
  'reports': ('Reports', Icons.flag_outlined),
  'blocks': ('Blocks', Icons.block),
  'privacy-requests': ('Privacy requests', Icons.privacy_tip_outlined),
  'notifications': ('Notifications', Icons.notifications_outlined),
  'audit': ('Audit log', Icons.history),
  'readiness': ('Storage and readiness', Icons.storage_outlined),
  'settings': ('Settings', Icons.settings_outlined),
};

class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.api});
  final Api api;
  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  String selected = 'dashboard';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Jain Matrimonial'),
      actions: [
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
          onPressed: () => runAction(context, () async {
            if (await confirm(
              context,
              'Sign out?',
              'Your current administrator session will end.',
            )) {
              await widget.api.logout();
            }
          }),
        ),
        const SizedBox(width: 12),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        return Row(
          children: [
            SizedBox(
              width: wide ? 220 : 65,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                    for (final entry in groups.entries)
                      Tooltip(
                        message: entry.value.$1,
                        child: ListTile(
                          leading: Icon(entry.value.$2),
                          title: wide ? Text(entry.value.$1) : null,
                          selected: selected == entry.key,
                          onTap: () => setState(() => selected = entry.key),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      groups[selected]!.$1,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: switch (selected) {
                        'dashboard' => Dashboard(
                          api: widget.api,
                          choose: (queue) => setState(() => selected = queue),
                        ),
                        'readiness' => Readiness(api: widget.api),
                        'settings' => AdminPasswordSettings(api: widget.api),
                        _ => AdminQueue(
                          key: ValueKey(selected),
                          api: widget.api,
                          queue: selected,
                        ),
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class Dashboard extends StatelessWidget {
  const Dashboard({super.key, required this.api, required this.choose});
  final Api api;
  final ValueChanged<String> choose;
  @override
  Widget build(BuildContext context) => RemotePanel(
    load: () => api.get('/admin/dashboard'),
    builder: (context, data, refresh) => ListView(
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (final metric in {
              'accounts': 'Active customers',
              'revisions': 'Profile reviews',
              'claims': 'Pending claims',
              'interests': 'Interest decisions',
              'reports': 'Open reports',
              'privacyRequests': 'Privacy requests',
            }.entries)
              SizedBox(
                width: 215,
                child: Card(
                  child: ListTile(
                    title: Text(metric.value),
                    subtitle: Text(
                      '${data[metric.key]}',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    onTap: () => choose(
                      metric.key == 'privacyRequests'
                          ? 'privacy-requests'
                          : metric.key,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => choose('settings'),
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Settings'),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh counts'),
          ),
        ),
      ],
    ),
  );
}

class Readiness extends StatelessWidget {
  const Readiness({super.key, required this.api});
  final Api api;
  @override
  Widget build(BuildContext context) => RemotePanel(
    load: () => api.get('/readiness'),
    builder: (context, data, refresh) => ListView(
      children: [
        const ListTile(
          leading: Icon(Icons.cloud_done_outlined),
          title: Text('Worker database checks passed'),
        ),
        ListTile(
          leading: const Icon(Icons.mail_outline),
          title: Text(
            data['emailConfigured'] == true
                ? 'Email credentials configured'
                : 'Email credentials unavailable',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.storage_outlined),
          title: Text(switch (data['uploads']) {
            'online' => 'Permanent storage online',
            'offline' => 'Permanent storage unreachable',
            'unconfigured' => 'Permanent storage connection unconfigured',
            _ => 'File transfer disabled',
          }),
          subtitle: const Text(
            'Transfers require the permanent PC to be online.',
          ),
        ),
        const ListTile(
          leading: Icon(Icons.notifications_off_outlined),
          title: Text('Android push unavailable'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: refresh,
            child: const Text('Refresh'),
          ),
        ),
      ],
    ),
  );
}
