// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:jain_client/jain_client.dart';

class PageButtons extends StatelessWidget {
  const PageButtons({
    super.key,
    required this.offset,
    required this.next,
    required this.onPage,
  });
  final int offset;
  final int? next;
  final ValueChanged<int> onPage;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      if (offset > 0)
        TextButton(
          onPressed: () => onPage(offset >= 20 ? offset - 20 : 0),
          child: const Text('Previous'),
        ),
      if (next != null)
        TextButton(
          onPressed: () => onPage(next!),
          child: const Text('Next page'),
        ),
    ],
  );
}

class Discover extends StatefulWidget {
  const Discover({super.key, required this.api});
  final Api api;
  @override
  State<Discover> createState() => _DiscoverState();
}

class _DiscoverState extends State<Discover> {
  Json filters = {};
  String selected = '/search';
  int offset = 0;
  int revision = 0;
  final List<String?> searchPages = [null];
  Api get api => widget.api;

  Future<Json?> filterDialog(Json current) => showDialog<Json>(
    context: context,
    builder: (dialog) {
      final draft = Map<String, dynamic>.of(current);
      return AlertDialog(
        title: const Text('Discovery filters'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: FieldInputs(
              fields: searchFields,
              values: draft,
              update: (key, value) {
                if (value == null) {
                  draft.remove(key);
                } else {
                  draft[key] = value;
                }
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, <String, dynamic>{}),
            child: const Text('Reset'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, draft),
            child: const Text('Apply'),
          ),
        ],
      );
    },
  );

  void use(Json filters) => setState(() {
    this.filters = filters;
    selected = '/search';
    offset = 0;
    searchPages
      ..clear()
      ..add(null);
    revision++;
  });

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children:
              {
                    '/search': 'Browse',
                    '/recommendations': 'Recommended',
                    '/favorites': 'Favorites',
                    '/saved-searches': 'Saved searches',
                  }.entries
                  .map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(entry.value),
                        selected: selected == entry.key,
                        onSelected: (_) => setState(() {
                          selected = entry.key;
                          offset = 0;
                          searchPages
                            ..clear()
                            ..add(null);
                          revision++;
                        }),
                      ),
                    ),
                  )
                  .toList(),
        ),
      ),
      if (selected == '/search')
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () async {
                final next = await filterDialog(filters);
                if (next != null && mounted) use(next);
              },
              icon: const Icon(Icons.tune),
              label: Text(
                filters.isEmpty ? 'Filters' : 'Filters (${filters.length})',
              ),
            ),
            TextButton(
              onPressed: () => runAction(context, () async {
                final owned = items(await api.get('/profiles'));
                if (owned.isEmpty) {
                  throw const ApiError(
                    400,
                    'Create a profile with partner preferences first.',
                    {},
                  );
                }
                final data = asJson(owned.first['data']);
                if (mounted) {
                  use(
                    data['preferences'] is Map
                        ? asJson(data['preferences'])
                        : {},
                  );
                }
              }),
              child: const Text('Use preferences'),
            ),
            TextButton(
              onPressed: () => runAction(context, () async {
                final name = await prompt(
                  context,
                  'Save search',
                  'Search name',
                );
                if (name != null && name.isNotEmpty) {
                  await api.post('/saved-searches', {
                    'name': name,
                    'filters': filters,
                  });
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Search saved')),
                    );
                  }
                }
              }),
              child: const Text('Save search'),
            ),
          ],
        ),
      Expanded(
        child: RemotePanel(
          key: ValueKey('$selected:$offset:$revision'),
          load: () => api.get(
            api.query(selected, {
              ...(selected == '/search' ? filters : <String, dynamic>{}),
              if (selected == '/search')
                'cursor': searchPages.last
              else
                'offset': offset,
            }),
          ),
          builder: (context, data, refresh) {
            final records = items(data);
            return RefreshIndicator(
              onRefresh: () async => refresh(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  if (records.isEmpty)
                    const ListTile(
                      title: Text('No profiles or searches match this view.'),
                    ),
                  for (final item in records)
                    if (selected == '/saved-searches')
                      _saved(context, item, refresh)
                    else
                      _card(context, Candidate.fromJson(item), refresh),
                  if (selected == '/search')
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (searchPages.length > 1)
                          TextButton(
                            onPressed: () => setState(() {
                              searchPages.removeLast();
                              revision++;
                            }),
                            child: const Text('Previous'),
                          ),
                        if (data['nextCursor'] is String)
                          TextButton(
                            onPressed: () => setState(() {
                              searchPages.add(data['nextCursor'] as String);
                              revision++;
                            }),
                            child: const Text('Next page'),
                          ),
                      ],
                    )
                  else
                    PageButtons(
                      offset: offset,
                      next: data['nextOffset'] as int?,
                      onPage: (value) => setState(() => offset = value),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget _saved(BuildContext context, Json item, VoidCallback refresh) => Card(
    child: ListTile(
      title: Text(item['name'] as String),
      onTap: () => use(asJson(item['filters'])),
      trailing: PopupMenuButton<String>(
        onSelected: (action) => runAction(context, () async {
          final id = item['id'];
          if (action == 'delete') {
            if (!await confirm(
              context,
              'Remove this search?',
              'You can save another search at any time.',
            )) {
              return;
            }
            await api.delete('/saved-searches/$id');
          } else {
            final name = await prompt(
              context,
              'Edit saved search',
              'Search name',
              initial: item['name'] as String,
            );
            if (name == null || !context.mounted) return;
            final revised = await filterDialog(asJson(item['filters']));
            if (revised == null) return;
            await api.put('/saved-searches/$id', {
              'name': name,
              'filters': revised,
            });
          }
          refresh();
        }),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Remove')),
        ],
      ),
    ),
  );

  Widget _card(
    BuildContext context,
    Candidate candidate,
    VoidCallback refresh,
  ) {
    final reasons = candidate.values['reasons'] as List?;
    return Card(
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person_outline)),
        title: Text(candidate.title),
        subtitle: Text(
          [
            candidate.summary,
            if (reasons != null) reasons.join(' · '),
          ].where((value) => value.isNotEmpty).join('\n'),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => Detail(
                api: api,
                id: candidate.id,
                favorite: selected == '/favorites',
              ),
            ),
          );
          refresh();
        },
      ),
    );
  }
}

class Detail extends StatefulWidget {
  const Detail({
    super.key,
    required this.api,
    required this.id,
    required this.favorite,
  });
  final Api api;
  final String id;
  final bool favorite;
  @override
  State<Detail> createState() => _DetailState();
}

class _DetailState extends State<Detail> {
  late bool favorite = widget.favorite;
  Api get api => widget.api;
  String get id => widget.id;

  Future<void> expressInterest(BuildContext context) =>
      runAction(context, () async {
        final drafts = items(await api.get('/profiles'))
            .where(
              (draft) =>
                  draft['publishedId'] != null &&
                  draft['visible'] == 1 &&
                  draft['suspended'] == 0,
            )
            .toList();
        if (drafts.isEmpty) {
          throw const ApiError(
            409,
            'An approved, visible profile is required.',
            {},
          );
        }
        if (!context.mounted) return;
        final sender = await showDialog<String>(
          context: context,
          builder: (dialog) => SimpleDialog(
            title: const Text('Send interest from'),
            children: drafts
                .map(
                  (draft) => SimpleDialogOption(
                    onPressed: () =>
                        Navigator.pop(dialog, draft['id'] as String),
                    child: Text(
                      asJson(draft['data'])['name']?.toString() ?? 'My profile',
                    ),
                  ),
                )
                .toList(),
          ),
        );
        if (sender == null || !context.mounted) return;
        if (!await confirm(
          context,
          'Send interest?',
          'An administrator will review it before the recipient receives it.',
        )) {
          return;
        }
        await api.post('/interests', {'sender': sender, 'recipient': id});
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Interest submitted for review')),
          );
        }
      });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Profile details')),
    body: RemotePanel(
      load: () => api.get('/discover/$id'),
      builder: (context, data, _) {
        final candidate = Candidate.fromJson(data);
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              candidate.title,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            SelectableText('Profile ID $id'),
            const SizedBox(height: 12),
            for (final field in [
              ...basics,
              ...community,
              ...professional,
              ...family,
            ])
              if (data[field.key] != null)
                ListTile(
                  title: Text(field.label),
                  subtitle: Text(
                    data[field.key] is List
                        ? (data[field.key] as List).join(', ')
                        : label(data[field.key]),
                  ),
                ),
            const ListTile(
              leading: Icon(Icons.photo_outlined),
              title: Text('Photos are unavailable.'),
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () => expressInterest(context),
                  child: const Text('Express interest'),
                ),
                OutlinedButton(
                  onPressed: () => runAction(context, () async {
                    if (favorite) {
                      await api.delete('/favorites/$id');
                    } else {
                      await api.put('/favorites/$id', {});
                    }
                    if (mounted) setState(() => favorite = !favorite);
                  }),
                  child: Text(favorite ? 'Remove favorite' : 'Add favorite'),
                ),
                TextButton(
                  onPressed: () => runAction(context, () async {
                    final reason = await prompt(
                      context,
                      'Report a profile',
                      'Reason',
                    );
                    if (reason == null || reason.isEmpty) return;
                    await api.post('/reports', {
                      'profileId': id,
                      'reason': reason,
                    });
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Report submitted')),
                      );
                    }
                  }),
                  child: const Text('Report'),
                ),
                TextButton(
                  onPressed: () => runAction(context, () async {
                    if (!await confirm(
                      context,
                      'Block this profile?',
                      'Blocking also prevents future contact access through interests.',
                    )) {
                      return;
                    }
                    await api.put('/blocks/$id', {});
                    if (context.mounted) Navigator.pop(context);
                  }),
                  child: const Text('Block'),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}
