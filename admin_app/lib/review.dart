// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:jain_client/jain_client.dart';

import 'documents.dart';

const columns = <String, Map<String, String>>{
  'profiles': {
    'name': 'Candidate',
    'id': 'Profile ID',
    'publishedId': 'Published revision',
    'updatedAt': 'Updated',
  },
  'revisions': {
    'name': 'Candidate',
    'profileId': 'Profile ID',
    'createdAt': 'Submitted',
    'status': 'Status',
  },
  'claims': {
    'email': 'Claimant',
    'profileId': 'Profile ID',
    'consentEvidence': 'Consent evidence',
    'createdAt': 'Requested',
  },
  'accounts': {
    'email': 'Account',
    'role': 'Role',
    'status': 'Status',
    'createdAt': 'Created',
  },
  'interests': {
    'sender': 'Sender profile',
    'recipient': 'Recipient profile',
    'status': 'Status',
    'activeConsents': 'Consents',
  },
  'reports': {
    'profileId': 'Profile ID',
    'reason': 'Reason',
    'status': 'Status',
    'createdAt': 'Filed',
  },
  'blocks': {
    'accountId': 'Account',
    'blockedId': 'Blocked account',
    'createdAt': 'Created',
  },
  'privacy-requests': {
    'accountId': 'Account',
    'kind': 'Request',
    'status': 'Status',
    'createdAt': 'Created',
  },
  'notifications': {
    'kind': 'Update',
    'entityId': 'Record',
    'createdAt': 'Received',
    'readAt': 'Read',
  },
  'audit': {
    'action': 'Action',
    'actorId': 'Actor',
    'entityId': 'Record',
    'createdAt': 'Time',
  },
};

class AdminQueue extends StatefulWidget {
  const AdminQueue({super.key, required this.api, required this.queue});
  final Api api;
  final String queue;
  @override
  State<AdminQueue> createState() => _AdminQueueState();
}

class _AdminQueueState extends State<AdminQueue> {
  int offset = 0;
  int refreshCount = 0;
  String query = '';
  String status = '';
  Api get api => widget.api;

  void reload() => setState(() => refreshCount++);

  @override
  Widget build(BuildContext context) {
    final queue = widget.queue;
    final spec = columns[queue]!;
    final route = queue == 'notifications' ? '/notifications' : '/admin/$queue';
    return RemotePanel(
      key: ValueKey('$offset:$refreshCount'),
      load: () => api.get(
        api.query(route, {'offset': offset, 'q': query, 'status': status}),
      ),
      builder: (context, data, refresh) {
        final records = items(data);
        final next = data['nextOffset'] as int?;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (queue == 'profiles')
                  FilledButton.icon(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<bool>(
                          builder: (_) => ProfileEditor(api: api, admin: true),
                        ),
                      );
                      reload();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Create unclaimed profile'),
                  ),
                if (['profiles', 'accounts'].contains(queue))
                  OutlinedButton.icon(
                    onPressed: () async {
                      final text = await prompt(
                        context,
                        'Search $queue',
                        'Name, email, or ID',
                        initial: query,
                      );
                      if (text != null && mounted) {
                        setState(() {
                          query = text;
                          offset = 0;
                          refreshCount++;
                        });
                      }
                    },
                    icon: const Icon(Icons.search),
                    label: Text(query.isEmpty ? 'Search' : 'Search for $query'),
                  ),
                if (queue == 'interests')
                  DropdownButton<String>(
                    value: status,
                    onChanged: (next) => setState(() {
                      status = next ?? '';
                      offset = 0;
                      refreshCount++;
                    }),
                    items:
                        {
                              '': 'All statuses',
                              'pending_admin_review': 'Initial review',
                              'pending_contact_authorization':
                                  'Contact authorization',
                              'authorized': 'Authorized',
                              'pending_recipient': 'Recipient decision',
                            }.entries
                            .map(
                              (entry) => DropdownMenuItem(
                                value: entry.key,
                                child: Text(entry.value),
                              ),
                            )
                            .toList(),
                  ),
                OutlinedButton.icon(
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: records.isEmpty
                  ? empty('There are no records to display.')
                  : SingleChildScrollView(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: [
                            const DataColumn(label: Text('Action')),
                            ...spec.values.map(
                              (title) => DataColumn(label: Text(title)),
                            ),
                          ],
                          rows: records
                              .map(
                                (record) => DataRow(
                                  cells: [
                                    DataCell(
                                      TextButton(
                                        onPressed: () => details(
                                          context,
                                          queue,
                                          record,
                                          refresh,
                                        ),
                                        child: const Text('Open'),
                                      ),
                                    ),
                                    ...spec.keys.map(
                                      (key) => DataCell(
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 220,
                                          ),
                                          child: Text(
                                            label(record[key]),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (offset > 0)
                  TextButton(
                    onPressed: () => setState(() => offset -= 20),
                    child: const Text('Previous page'),
                  ),
                if (next != null)
                  TextButton(
                    onPressed: () => setState(() => offset = next),
                    child: const Text('Next page'),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> details(
    BuildContext context,
    String queue,
    Json item,
    VoidCallback refresh,
  ) async {
    if (queue == 'profiles' || queue == 'revisions') {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ProfileReview(
            api: api,
            profileId:
                (queue == 'profiles' ? item['id'] : item['profileId'])
                    as String,
            revisionId: queue == 'revisions' ? item['id'] as String : null,
          ),
        ),
      );
      refresh();
      return;
    }
    final decisionOptions = switch (queue) {
      'claims' => ['approved', 'rejected'],
      'accounts' when item['role'] == 'customer' => [
        item['status'] == 'suspended' ? 'reactivate' : 'suspend',
      ],
      'interests' when item['status'] == 'pending_admin_review' => [
        'admin_approve',
        'admin_reject',
        'cancel',
      ],
      'interests' when item['status'] == 'pending_contact_authorization' => [
        if (item['canAuthorize'] == 1) 'authorize',
        'cancel',
      ],
      'interests'
          when ['pending_recipient', 'authorized'].contains(item['status']) =>
        ['cancel'],
      'reports' ||
      'privacy-requests' when item['status'] == 'open' => ['close'],
      'notifications' when item['readAt'] == null => ['mark_read'],
      _ => <String>[],
    };
    final entityId = item['entityId'] ?? item['id'];
    final showHistory =
        ['accounts', 'reports', 'privacy-requests', 'audit'].contains(queue) &&
        entityId is String &&
        RegExp(r'^[0-9a-f-]{36}$').hasMatch(entityId);
    final history = showHistory ? api.get('/admin/moderation/$entityId') : null;
    final decision = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (dialog) => AlertDialog(
        title: Text(label(queue)),
        content: SizedBox(
          width: 570,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in item.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SelectableText(
                      '${entry.key} · ${entry.value ?? '—'}',
                    ),
                  ),
                if (queue == 'interests' &&
                    item['status'] == 'pending_contact_authorization' &&
                    item['canAuthorize'] != 1)
                  const Text(
                    'Authorization requires current consent from both parties and two eligible profiles.',
                  ),
                if (history != null)
                  FutureBuilder<Json>(
                    future: history,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Text(
                          'Moderation history unavailable: ${snapshot.error}',
                        );
                      }
                      if (!snapshot.hasData) {
                        return const LinearProgressIndicator();
                      }
                      final actions = items(snapshot.requireData);
                      if (actions.isEmpty) return const SizedBox.shrink();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(),
                          const Text('Moderation history'),
                          for (final action in actions)
                            SelectableText(
                              '${label(action['kind'])} · ${action['reason']} · ${action['createdAt']}',
                            ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Close'),
          ),
          if (item['profileId'] is String)
            TextButton(
              onPressed: () => Navigator.pop(dialog, 'open_profile'),
              child: const Text('Review profile'),
            ),
          for (final option in decisionOptions)
            FilledButton(
              onPressed: () => Navigator.pop(dialog, option),
              child: Text(label(option)),
            ),
        ],
      ),
    );
    if (decision == null || !context.mounted) return;
    if (decision == 'open_profile') {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              ProfileReview(api: api, profileId: item['profileId'] as String),
        ),
      );
      refresh();
      return;
    }
    await runAction(context, () async {
      final id = item['id'];
      if (decision == 'mark_read') {
        await api.post('/notifications/$id/read', {});
      } else {
        final reason = await prompt(
          context,
          'Confirm ${label(decision)}',
          'Reason',
        );
        if (reason == null || reason.isEmpty) return;
        switch (queue) {
          case 'claims':
            await api.post('/admin/claims/$id/decision', {
              'decision': decision,
              'reason': reason,
            });
          case 'accounts':
            await api.put('/admin/accounts/$id/suspension', {
              'suspended': decision == 'suspend',
              'reason': reason,
            });
          case 'interests':
            await api.post('/admin/interests/$id/decision', {
              'action': decision,
              'reason': reason,
              'version': item['version'],
            });
          case 'reports':
          case 'privacy-requests':
            await api.post('/admin/$queue/$id/close', {'reason': reason});
        }
      }
      refresh();
    });
  }
}

class ProfileReview extends StatelessWidget {
  const ProfileReview({
    super.key,
    required this.api,
    required this.profileId,
    this.revisionId,
  });
  final Api api;
  final String profileId;
  final String? revisionId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Profile review')),
    body: RemotePanel(
      load: () => api.get('/profiles/$profileId'),
      builder: (context, data, refresh) {
        final history = (data['history'] as List).map(asJson).toList();
        final baseline = data['publication'] == null
            ? null
            : asJson(data['publication']);
        final pending = history
            .where(
              (row) => revisionId == null
                  ? row['status'] == 'pending_review'
                  : row['id'] == revisionId,
            )
            .firstOrNull;
        final original = baseline == null
            ? <String, dynamic>{}
            : asJson(baseline['data']);
        final next = pending == null
            ? asJson(data['data'])
            : asJson(pending['data']);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              next['name']?.toString() ?? 'Unnamed draft',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            SelectableText('Profile ID $profileId'),
            if (data['claimEmail'] != null)
              SelectableText('Claim email · ${data['claimEmail']}'),
            if (data['consentEvidence'] != null)
              SelectableText('Candidate consent · ${data['consentEvidence']}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ProfileDocuments(api: api, profileId: profileId),
                    ),
                  ),
                  icon: const Icon(Icons.attachment),
                  label: const Text('Private documents'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<bool>(
                        builder: (_) => ProfileEditor(
                          api: api,
                          draft: Draft.fromJson(data),
                          admin: true,
                        ),
                      ),
                    );
                    refresh();
                  },
                  child: const Text('Edit draft'),
                ),
                OutlinedButton(
                  onPressed: () => runAction(context, () async {
                    final suspended = data['suspended'] != 1;
                    final reason = await prompt(
                      context,
                      suspended ? 'Confirm suspension' : 'Confirm reactivation',
                      'Reason',
                    );
                    if (reason == null || reason.isEmpty) return;
                    await api.put('/admin/profiles/$profileId/suspension', {
                      'suspended': suspended,
                      'reason': reason,
                    });
                    refresh();
                  }),
                  child: Text(
                    data['suspended'] == 1 ? 'Reactivate' : 'Suspend',
                  ),
                ),
                if (pending?['status'] == 'pending_review')
                  for (final decision in [
                    'approved',
                    'rejected',
                    'changes_requested',
                  ])
                    FilledButton(
                      onPressed: () => runAction(context, () async {
                        final reason = await prompt(
                          context,
                          'Confirm ${label(decision)}',
                          'Review reason',
                        );
                        if (reason == null || reason.isEmpty) return;
                        await api.post(
                          '/admin/revisions/${pending!['id']}/decision',
                          {'decision': decision, 'reason': reason},
                        );
                        refresh();
                      }),
                      child: Text(switch (decision) {
                        'approved' => 'Approve',
                        'rejected' => 'Reject',
                        _ => 'Request corrections',
                      }),
                    ),
              ],
            ),
            const SizedBox(height: 14),
            for (final field in [
              ...basics,
              ...community,
              ...professional,
              ...family,
              ...preferenceFields.map(
                (field) => (
                  key: 'preferences.${field.key}',
                  label: 'Preference · ${field.label}',
                ),
              ),
            ])
              if (_value(original, field.key) != null ||
                  _value(next, field.key) != null)
                _difference(
                  context,
                  field.label,
                  _value(original, field.key),
                  _value(next, field.key),
                  pending != null,
                ),
            const Divider(),
            Text(
              'Revision history',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final row in history)
              ListTile(
                title: Text(label(row['status'])),
                subtitle: Text(
                  [
                    row['createdAt'],
                    row['reviewer'],
                    row['reason'],
                  ].whereType<String>().join(' · '),
                ),
              ),
          ],
        );
      },
    ),
  );

  Object? _value(Json row, String key) => key.startsWith('preferences.')
      ? (row['preferences'] is Map
            ? asJson(row['preferences'])[key.substring(12)]
            : null)
      : row[key];

  Widget _difference(
    BuildContext context,
    String field,
    Object? before,
    Object? after,
    bool pending,
  ) {
    final changed = before.toString() != after.toString();
    String show(Object? value) => value == null
        ? '—'
        : value is List
        ? value.join(', ')
        : label(value);
    return Card(
      color: changed ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(field)),
            Expanded(child: SelectableText('Approved · ${show(before)}')),
            Expanded(
              child: SelectableText(
                '${pending ? 'Submitted' : 'Draft'} · ${show(after)}',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
