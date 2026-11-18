// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:jain_client/jain_client.dart';

import 'discovery.dart';

class CustomerHome extends StatefulWidget {
  const CustomerHome({super.key, required this.api});
  final Api api;

  @override
  State<CustomerHome> createState() => _HomeState();
}

class _HomeState extends State<CustomerHome> {
  int tab = 0;
  Api get api => widget.api;
  static const titles = [
    'My profile',
    'Discover',
    'Interests',
    'Notifications',
  ];

  void settings() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => Settings(api: api)),
  );

  @override
  Widget build(BuildContext context) {
    final views = [
      MyProfiles(api: api),
      Discover(api: api),
      Interests(api: api),
      Notifications(api: api),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[tab]),
        actions: [
          IconButton(
            onPressed: settings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Account settings',
          ),
        ],
      ),
      body: views[tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Profile',
          ),
          NavigationDestination(icon: Icon(Icons.search), label: 'Discover'),
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            label: 'Interests',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            label: 'Updates',
          ),
        ],
      ),
    );
  }
}

class MyProfiles extends StatelessWidget {
  const MyProfiles({super.key, required this.api});
  final Api api;

  Future<void> claim(BuildContext context) => runAction(context, () async {
    final id = await prompt(
      context,
      'Claim a profile',
      'Profile ID provided by the administrator',
    );
    if (id == null || !context.mounted) return;
    final challenge = await api.post('/auth/claim-code', {});
    if (!context.mounted) return;
    final code = await enterCode(context, challenge);
    if (code == null) return;
    await api.post('/profiles/claim', {'profileId': id, ...code});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Claim sent for administrator review.')),
      );
    }
  });

  @override
  Widget build(BuildContext context) => RemotePanel(
    load: () => api.get('/profiles'),
    builder: (context, data, refresh) {
      final profiles = items(data).map(Draft.fromJson).toList();
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Jain Matrimonial',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          if (profiles.isEmpty)
            const Text(
              'Create a profile to begin. You can save a draft before submitting it for review.',
            ),
          for (final profile in profiles)
            Card(
              child: ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(
                  profile.data['name']?.toString() ?? 'Unnamed draft',
                ),
                subtitle: Text(
                  profile.record['publishedId'] == null
                      ? 'Awaiting first approval'
                      : 'Approved version available',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => OwnProfile(api: api, id: profile.id),
                    ),
                  );
                  refresh();
                },
              ),
            ),
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('Claim status'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => StatusList(
                  api: api,
                  title: 'Claim status',
                  route: '/claims',
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<bool>(
                      builder: (_) => ProfileEditor(api: api),
                    ),
                  );
                  refresh();
                },
                icon: const Icon(Icons.add),
                label: const Text('Create profile'),
              ),
              OutlinedButton(
                onPressed: () => claim(context),
                child: const Text('Claim a profile'),
              ),
            ],
          ),
        ],
      );
    },
  );
}

class OwnProfile extends StatelessWidget {
  const OwnProfile({super.key, required this.api, required this.id});
  final Api api;
  final String id;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('My profile')),
    body: RemotePanel(
      load: () => api.get('/profiles/$id'),
      builder: (context, json, refresh) {
        final profile = Draft.fromJson(json);
        final history = (json['history'] as List).map(asJson).toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              profile.data['name']?.toString() ?? 'Unnamed draft',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            SelectableText('Profile ID $id'),
            if (profile.record['suspended'] == 1)
              const Text('This profile is suspended.'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute<bool>(
                    builder: (_) => ProfileEditor(api: api, draft: profile),
                  ),
                );
                refresh();
              },
              child: const Text('Edit draft and partner preferences'),
            ),
            SwitchListTile(
              title: const Text('Show approved profile in discovery'),
              value: json['visible'] == 1,
              onChanged: (value) => runAction(context, () async {
                if (!await confirm(
                  context,
                  'Change visibility?',
                  'This also controls eligibility for contact sharing.',
                )) {
                  return;
                }
                await api.put('/profiles/$id/visibility', {'visible': value});
                refresh();
              }),
            ),
            const ListTile(
              leading: Icon(Icons.photo_outlined),
              title: Text('Photo uploads are unavailable.'),
            ),
            const Divider(),
            Text(
              'Review history',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (history.isEmpty)
              const ListTile(title: Text('No submissions yet.')),
            for (final entry in history)
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(label(entry['status'])),
                subtitle: Text(
                  [
                    entry['createdAt'],
                    entry['reason'],
                  ].whereType<String>().join('\n'),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class Interests extends StatefulWidget {
  const Interests({super.key, required this.api});
  final Api api;
  @override
  State<Interests> createState() => _InterestsState();
}

class _InterestsState extends State<Interests> {
  int offset = 0;
  @override
  Widget build(BuildContext context) => RemotePanel(
    key: ValueKey(offset),
    load: () => widget.api.get('/interests?offset=$offset'),
    builder: (context, data, refresh) {
      final records = items(data);
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (records.isEmpty)
            const ListTile(title: Text('No interests to show.')),
          for (final item in records) _interest(context, item, refresh),
          PageButtons(
            offset: offset,
            next: data['nextOffset'] as int?,
            onPage: (value) => setState(() => offset = value),
          ),
        ],
      );
    },
  );

  Widget _interest(BuildContext context, Json item, VoidCallback refresh) {
    final id = item['id'];
    final status = item['status'];
    final direction = item['direction'];
    final sent = direction == 'sent';
    final api = widget.api;
    Future<void> action(String code) => runAction(context, () async {
      if (!await confirm(
        context,
        'Confirm ${label(code)}?',
        'This updates the interest for the parties involved.',
      )) {
        return;
      }
      await api.post('/interests/$id/decision', {
        'action': code,
        'version': item['version'],
      });
      refresh();
    });
    Future<void> setConsent(bool granted) => runAction(context, () async {
      if (!await confirm(
        context,
        granted ? 'Share your verified email?' : 'Withdraw contact consent?',
        granted
            ? 'Both participants must agree and an administrator must authorize release.'
            : 'This prevents future access to your email through this interest.',
      )) {
        return;
      }
      await api.put('/interests/$id/consent', {'granted': granted});
      refresh();
    });
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${label(direction)} · ${label(status)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SelectableText('Profile ${item[sent ? 'recipient' : 'sender']}'),
            Wrap(
              spacing: 8,
              children: [
                if (!sent && status == 'pending_recipient') ...[
                  FilledButton(
                    onPressed: () => action('accept'),
                    child: const Text('Accept'),
                  ),
                  OutlinedButton(
                    onPressed: () => action('decline'),
                    child: const Text('Decline'),
                  ),
                ],
                if (sent &&
                    [
                      'pending_admin_review',
                      'pending_recipient',
                      'pending_contact_authorization',
                      'authorized',
                    ].contains(status))
                  OutlinedButton(
                    onPressed: () => action('withdraw'),
                    child: const Text('Withdraw'),
                  ),
                if (status == 'pending_contact_authorization' &&
                    item['activeConsents'] == 0)
                  FilledButton(
                    onPressed: () => setConsent(true),
                    child: const Text('Grant email consent'),
                  ),
                if (item['activeConsents'] == 1)
                  OutlinedButton(
                    onPressed: () => setConsent(false),
                    child: const Text('Revoke consent'),
                  ),
                if (status == 'authorized')
                  FilledButton(
                    onPressed: () => runAction(context, () async {
                      final contact = await api.get('/interests/$id/contact');
                      if (!context.mounted) return;
                      await showDialog<void>(
                        context: context,
                        builder: (dialog) => AlertDialog(
                          title: const Text('Approved contact email'),
                          content: SelectableText(contact['email'] as String),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialog),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    }),
                    child: const Text('View email'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class Notifications extends StatefulWidget {
  const Notifications({super.key, required this.api});
  final Api api;
  @override
  State<Notifications> createState() => _NotificationsState();
}

class _NotificationsState extends State<Notifications> {
  int offset = 0;
  @override
  Widget build(BuildContext context) => RemotePanel(
    key: ValueKey(offset),
    load: () => widget.api.get('/notifications?offset=$offset'),
    builder: (context, data, refresh) => ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ListTile(title: Text('${data['unread']} unread')),
        for (final record in items(data))
          ListTile(
            leading: Icon(
              record['readAt'] == null
                  ? Icons.circle_notifications
                  : Icons.notifications_none,
            ),
            title: Text(label(record['kind']).replaceAll('.', ' · ')),
            subtitle: Text(
              DateTime.tryParse(
                    record['createdAt'].toString(),
                  )?.toLocal().toString() ??
                  '',
            ),
            onTap: () => runAction(context, () async {
              await widget.api.post('/notifications/${record['id']}/read', {});
              if (!context.mounted) return;
              final entity = record['entityId'];
              if (record['kind'].toString().startsWith('profile.')) {
                await Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        OwnProfile(api: widget.api, id: entity as String),
                  ),
                );
              } else if (record['kind'].toString().startsWith('interest.')) {
                await Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Interests')),
                      body: Interests(api: widget.api),
                    ),
                  ),
                );
              }
              refresh();
            }),
          ),
        PageButtons(
          offset: offset,
          next: data['nextOffset'] as int?,
          onPage: (value) => setState(() => offset = value),
        ),
      ],
    ),
  );
}

class Settings extends StatelessWidget {
  const Settings({super.key, required this.api});
  final Api api;

  Future<Json?> securityCode(BuildContext context) async {
    final response = await api.post('/auth/security-code', {});
    return context.mounted ? enterCode(context, response) : null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account and privacy')),
    body: ListView(
      children: [
        ListTile(
          title: const Text('Verified email'),
          subtitle: Text(api.account?.email ?? ''),
        ),
        ListTile(
          title: const Text('Change email'),
          onTap: () => runAction(context, () async {
            final email = await prompt(
              context,
              'Change email',
              'New email address',
            );
            if (email == null || !context.mounted) return;
            final current = await securityCode(context);
            if (current == null || !context.mounted) return;
            final response = await api.post('/auth/new-email-code', {
              'email': email,
            });
            if (!context.mounted) return;
            final next = await enterCode(context, response);
            if (next == null) return;
            await api.post('/auth/change-email', {
              'email': email,
              'current': current,
              'next': next,
            });
            await api.clear();
            if (context.mounted) Navigator.pop(context);
          }),
        ),
        ListTile(
          title: const Text('Unblock a profile'),
          onTap: () => runAction(context, () async {
            final id = await prompt(context, 'Unblock a profile', 'Profile ID');
            if (id != null && id.isNotEmpty) await api.delete('/blocks/$id');
          }),
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('View privacy requests'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => StatusList(
                api: api,
                title: 'Privacy requests',
                route: '/privacy-requests',
              ),
            ),
          ),
        ),
        for (final kind in ['export', 'deletion'])
          ListTile(
            title: Text('Request data $kind'),
            onTap: () => runAction(context, () async {
              if (!await confirm(
                context,
                'Request data $kind?',
                'The service team will review this privacy request.',
              )) {
                return;
              }
              if (!context.mounted) return;
              final code = await securityCode(context);
              if (code == null) return;
              await api.post('/privacy-requests', {'kind': kind, ...code});
            }, success: 'Privacy request submitted'),
          ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          onTap: () => runAction(context, () async {
            try {
              await api.logout();
            } finally {
              if (context.mounted) Navigator.pop(context);
            }
          }),
        ),
      ],
    ),
  );
}

class StatusList extends StatelessWidget {
  const StatusList({
    super.key,
    required this.api,
    required this.title,
    required this.route,
  });
  final Api api;
  final String title;
  final String route;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: RemotePanel(
      load: () => api.get(route),
      builder: (context, data, refresh) {
        final records = items(data);
        if (records.isEmpty) return empty('There are no requests to display.');
        return ListView(
          children: [
            for (final record in records)
              ListTile(
                title: Text(label(record['kind'] ?? record['profileId'])),
                subtitle: Text(label(record['status'])),
              ),
          ],
        );
      },
    ),
  );
}
