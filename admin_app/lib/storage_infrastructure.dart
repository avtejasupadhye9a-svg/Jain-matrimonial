import 'dart:async';
import 'dart:convert';
import 'dart:io';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:jain_client/jain_client.dart';

const _root = r'E:\JainMatrimonialAdmin';

class StorageInfrastructure extends StatefulWidget {
  const StorageInfrastructure({super.key, required this.api});
  final Api api;
  @override
  State<StorageInfrastructure> createState() => _InfraState();
}

class _InfraState extends State<StorageInfrastructure> {
  Json cloud = {}, local = {};
  Timer? timer;
  bool busy = false, loading = false;
  String? error, progress;
  String service = 'Unknown', connector = 'Unknown';
  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!busy) refresh();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> readLocal() async {
    if (!Platform.isWindows) return;
    final config = File('$_root\\Config\\storage.json');
    local = await config.exists()
        ? jsonDecode(await config.readAsString()) as Json
        : {};
    final exe = File('$_root\\JainMatrimonialAdmin.exe');
    if (!await exe.exists()) {
      service = 'Installer required';
      return;
    }
    final r = await Process.run(exe.path, ['--status']);
    final parts = r.stdout.toString().trim().split('|');
    if (r.exitCode == 0 && parts.length == 2) {
      service = parts.first;
      connector = parts.last;
    }
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      await readLocal();
      cloud = await widget.api.get('/admin/infrastructure');
      error = null;
    } catch (e) {
      cloud = {};
      error = 'Storage management unavailable. $e';
    } finally {
      loading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> manage(String action, [String? id]) async {
    final r = await Process.run('$_root\\JainMatrimonialAdmin.exe', [
      '--manage',
      action,
      ?id,
    ]);
    if (r.exitCode != 0) {
      throw StateError(
        'Windows did not complete the operation. Check the storage message and log.',
      );
    }
    await readLocal();
  }

  Future<void> control(String action) async {
    await widget.api.post('/admin/infrastructure/control', {
      'action': action,
      'generation': cloud['generation'],
    });
  }

  Future<void> restoreBackup() async {
    final backups = cloud['backups'] as List? ?? [];
    final selected = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Restore a recorded backup'),
        children: [
          for (final b in backups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, b['hash'] as String),
              child: Text(b['createdAt'].toString()),
            ),
        ],
      ),
    );
    if (selected != null) await manage('restore', selected);
  }

  Future<void> verify(String id) async {
    while (mounted) {
      final r = await widget.api.post('/admin/infrastructure/activate', {
        'id': id,
      });
      if (r['complete'] == true) return;
      setState(() => progress = 'Verifying restored files…');
    }
  }

  Future<void> enroll() async {
    await manage('prepare');
    final r = await widget.api.post('/admin/infrastructure/enroll', {
      'commitment': local['commitment'],
      'machine': local['machine'],
    });
    final id = r['id'] as String;
    await manage('redeem', id);
    await verify(id);
  }

  Future<void> run(
    String title,
    Future<void> Function() fn,
    bool confirm,
  ) async {
    if (busy) return;
    if (confirm) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: const Text(
            'This changes storage availability. Permanent files will be retained.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
    }
    setState(() {
      busy = true;
      progress = title;
      error = null;
    });
    String? failure;
    try {
      await fn();
    } catch (e) {
      failure = e.toString();
    }
    await refresh();
    if (mounted) {
      setState(() {
        busy = false;
        progress = null;
        if (failure != null) error = failure;
      });
    }
  }

  String size(dynamic n) =>
      n is num ? '${(n / 1048576).toStringAsFixed(1)} MiB' : 'Unknown';
  @override
  Widget build(BuildContext context) {
    final known = cloud.containsKey('generation'),
        paused = cloud['paused'] == true,
        primary = cloud['origin'];
    final designated = primary != null && primary == local['origin'];
    final installed = Platform.isWindows && service != 'Installer required',
        health = cloud['health'];
    Widget button(
      String title,
      Future<void> Function() fn,
      bool enabled, [
      bool confirm = false,
    ]) => OutlinedButton(
      onPressed: busy || !enabled ? null : () => run(title, fn, confirm),
      child: Text(title),
    );
    final metrics = <String, Object?>{
      'Designated PC': cloud['machine'],
      'Origin UUID': primary,
      'Private Worker route': health != null ? 'Verified' : 'Unverified',
      'Local storage service': service,
      'Local tunnel service': connector,
      'B2 connectivity': cloud['b2Status'],
      'Pending transfers': cloud['pending'],
      'Completed transfers': cloud['completed'],
      'Failed transfers': cloud['failed'],
      'Last synchronization': cloud['lastSync'],
      'Last error': cloud['lastError'],
      'Staged volume': size(cloud['stagedBytes']),
      'Staging budget': size(cloud['budgetBytes']),
      'Permanent files': size(cloud['confirmedBytes']),
      'Free capacity': size(health is Map ? health['freeBytes'] : null),
      'Last local backup': local['lastBackup'],
      'Storage folder': local['location'] ?? r'E:\JainMatrimonialStorage',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage Infrastructure'),
        actions: [
          IconButton(
            onPressed: busy ? null : refresh,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (error != null)
            SelectableText(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (busy) ...[
            const LinearProgressIndicator(),
            Text(progress ?? 'Working…'),
          ],
          for (final m in metrics.entries)
            ListTile(
              dense: true,
              title: Text(m.key),
              subtitle: SelectableText(m.value?.toString() ?? '—'),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              button(
                'Enable Main Storage Server',
                enroll,
                known && installed && (primary == null || paused),
                true,
              ),
              button(
                'Verify enrollment',
                () => verify(local['origin'] as String),
                known && local['origin'] != null && !designated,
              ),
              button(
                'Repair storage service',
                () => manage('repair'),
                installed && local['origin'] != null,
              ),
              button(
                'Restart storage service',
                () => manage('restart'),
                installed && local['origin'] != null,
              ),
              button(
                'Disable main storage',
                () async {
                  await control('revoke');
                  if (designated) await manage('stop');
                },
                known && primary != null,
                true,
              ),
              button(
                'Retry failed transfers',
                () => control('retry'),
                known && (cloud['failed'] as num? ?? 0) > 0,
              ),
              button(
                'View logs',
                () => manage('logs'),
                installed && local['origin'] != null,
              ),
              button(
                'Create backup',
                () => manage('backup'),
                installed && local['origin'] != null,
              ),
              button(
                'Back up to another drive',
                () => manage('external'),
                installed && local['origin'] != null,
              ),
              button(
                'Restore verified backup',
                restoreBackup,
                known &&
                    installed &&
                    cloud['backupHash'] != null &&
                    (paused || primary == null),
                true,
              ),
              button(
                'Configure storage location',
                () => manage('location'),
                known && installed && paused,
                true,
              ),
            ],
          ),
          const Divider(),
          Text(
            'Transfer main storage role',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text(
            'Pause transfers. Back up the current PC and restore the files on the replacement PC. Retire the old tunnel connector before enabling the new PC. Activation verifies every confirmed file.',
          ),
          Wrap(
            spacing: 8,
            children: [
              button(
                'Begin transfer',
                () => control('pause'),
                known && primary != null && !paused,
                true,
              ),
              button(
                'Resume previous origin',
                () async {
                  if (local['machine'] == cloud['machine'] &&
                      local['origin'] != primary &&
                      primary is String) {
                    await manage('rollback', primary);
                  }
                  await control('resume');
                },
                known && paused,
                true,
              ),
              button(
                'Rotate origin credential',
                enroll,
                installed && designated && paused,
                true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
