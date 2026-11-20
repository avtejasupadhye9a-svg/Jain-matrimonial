// ignore_for_file: deprecated_member_use
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:jain_client/jain_client.dart';

const _maxBytes = 8 * 1024 * 1024;
const _mime = {
  'pdf': 'application/pdf',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
};

String _id() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class ProfileDocuments extends StatefulWidget {
  const ProfileDocuments({
    super.key,
    required this.api,
    required this.profileId,
  });
  final Api api;
  final String profileId;

  @override
  State<ProfileDocuments> createState() => _ProfileDocumentsState();
}

class _ProfileDocumentsState extends State<ProfileDocuments> {
  int offset = 0;
  bool busy = false;
  ({String id, Uint8List bytes, String mime, String checksum})? pending;

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await runAction(context, action);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> upload(VoidCallback refresh, {Json? existing}) async {
    if (pending == null) {
      final selected = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Identity documents',
            extensions: ['pdf', 'jpg', 'jpeg', 'png'],
          ),
        ],
      );
      if (selected == null || !mounted) return;
      final mime = _mime[selected.name.split('.').last.toLowerCase()];
      if (mime == null) {
        throw const ApiError(0, 'Choose a PDF, JPEG, or PNG.', {});
      }
      final handle = await File(selected.path).open();
      final Uint8List bytes;
      try {
        bytes = await handle.read(_maxBytes + 1);
      } finally {
        await handle.close();
      }
      if (bytes.isEmpty || bytes.length > _maxBytes) {
        throw const ApiError(0, 'Choose a file between 1 byte and 8 MiB.', {});
      }
      if (!mounted) return;
      final checksum = sha256.convert(bytes).toString();
      if (existing != null &&
          (existing['mime'] != mime || existing['sha256'] != checksum)) {
        throw const ApiError(
          0,
          'Choose the original file to retry this upload.',
          {},
        );
      }
      pending = (
        id: existing?['id'] as String? ?? _id(),
        bytes: bytes,
        mime: mime,
        checksum: checksum,
      );
    }
    final file = pending!;
    try {
      await widget.api.uploadDocument(
        widget.api.query('/admin/documents/${file.id}', {
          'profileId': widget.profileId,
        }),
        file.bytes,
        file.mime,
        file.checksum,
      );
      pending = null;
      if (mounted) setState(() => offset = 0);
    } on ApiError catch (error) {
      if (error.status >= 400 && error.status < 500 && error.status != 429) {
        pending = null;
      }
      rethrow;
    } finally {
      if (mounted) refresh();
    }
  }

  Future<void> download(Json row) async {
    final extension = switch (row['mime']) {
      'application/pdf' => 'pdf',
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      _ => 'bin',
    };
    final id = row['id'];
    final location = await getSaveLocation(
      suggestedName: 'identity-$id.$extension',
    );
    if (location == null || !mounted) return;
    final data = await widget.api.downloadDocument('/admin/documents/$id');
    if (sha256.convert(data).toString() != row['sha256']) {
      throw const ApiError(0, 'The document failed its integrity check.', {});
    }
    if (!mounted) return;
    try {
      final destination = await File(location.path).create(exclusive: true);
      await destination.writeAsBytes(data, flush: true);
    } on FileSystemException {
      throw const ApiError(
        0,
        'Could not save the document. Choose a new writable filename.',
        {},
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Document saved.')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Private documents')),
    body: RemotePanel(
      key: ValueKey(offset),
      load: () => widget.api.get(
        widget.api.query('/admin/profiles/${widget.profileId}/documents', {
          'offset': offset,
        }),
      ),
      builder: (context, data, refresh) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Identity documents · administrator access'),
          const Text(
            'Downloads are available after permanent storage confirms the file.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : () => perform(() => upload(refresh)),
                icon: const Icon(Icons.upload_file),
                label: Text(
                  pending == null ? 'Upload document' : 'Retry upload',
                ),
              ),
              if (pending != null)
                TextButton(
                  onPressed: busy ? null : () => setState(() => pending = null),
                  child: const Text('Discard retry'),
                ),
              TextButton(
                onPressed: busy ? null : refresh,
                child: const Text('Refresh'),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (items(data).isEmpty)
            const ListTile(title: Text('No documents recorded')),
          for (final row in items(data))
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: SelectableText(row['id'].toString()),
              subtitle: Text(
                '${row['mime']} · ${label(row['state'])} · ${row['createdAt']}',
              ),
              trailing: row['state'] == 'confirmed'
                  ? TextButton(
                      onPressed: busy
                          ? null
                          : () => perform(() => download(row)),
                      child: const Text('Save document'),
                    )
                  : ['failed', 'copying'].contains(row['state'])
                  ? TextButton(
                      onPressed: busy || pending != null
                          ? null
                          : () => perform(() => upload(refresh, existing: row)),
                      child: const Text('Retry with original file'),
                    )
                  : null,
            ),
          Row(
            children: [
              if (offset > 0)
                TextButton(
                  onPressed: busy ? null : () => setState(() => offset -= 20),
                  child: const Text('Previous'),
                ),
              if (data['nextOffset'] is int)
                TextButton(
                  onPressed: busy
                      ? null
                      : () =>
                            setState(() => offset = data['nextOffset'] as int),
                  child: const Text('Next'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
