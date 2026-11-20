import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:jain_client/jain_client.dart';

class PrivateUpload extends StatefulWidget {
  const PrivateUpload({super.key, required this.api, required this.profileId});
  final Api api;
  final String profileId;
  @override
  State<PrivateUpload> createState() => _UploadState();
}

class _UploadState extends State<PrivateUpload> {
  bool busy = false;
  String? message;
  ({String id, String kind, String mime, String hash, Uint8List data})? file;
  Future<void> send(String kind) async {
    setState(() => busy = true);
    try {
      if (file == null) {
        final mimes = kind == 'photo'
            ? ['image/jpeg', 'image/png']
            : ['image/jpeg', 'image/png', 'application/pdf'];
        final f = await openFile(
          acceptedTypeGroups: [
            XTypeGroup(
              label: 'Profile file',
              mimeTypes: mimes,
              extensions: kind == 'photo'
                  ? ['jpg', 'jpeg', 'png']
                  : ['jpg', 'jpeg', 'png', 'pdf'],
            ),
          ],
        );
        if (f == null) return;
        final handle = await File(f.path).open();
        late Uint8List data;
        try {
          data = await handle.read(8 * 1024 * 1024 + 1);
        } finally {
          await handle.close();
        }
        if (data.isEmpty || data.length > 8 * 1024 * 1024) {
          throw const FormatException('Choose a file of up to 8 MiB.');
        }
        final ext = f.name.split('.').last.toLowerCase();
        final mime = {
          'jpg': 'image/jpeg',
          'jpeg': 'image/jpeg',
          'png': 'image/png',
          'pdf': 'application/pdf',
        }[ext];
        if (!mimes.contains(mime)) {
          throw const FormatException('Unsupported file type.');
        }
        final random = Random.secure();
        final hex = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final id = [
          hex.substring(0, 8),
          hex.substring(8, 12),
          hex.substring(12, 16),
          hex.substring(16, 20),
          hex.substring(20),
        ].join('-');
        file = (
          id: id,
          kind: kind,
          mime: mime!,
          hash: sha256.convert(data).toString(),
          data: data,
        );
      }
      final f = file!;
      final result = await widget.api.uploadDocument(
        widget.api.query('/customer/files/${f.id}', {
          'profileId': widget.profileId,
          'kind': f.kind,
        }),
        f.data,
        f.mime,
        f.hash,
      );
      message = result['state'] == 'confirmed'
          ? 'Verified in permanent storage.'
          : 'Received for scanning and synchronization.';
      file = null;
    } catch (e) {
      message = e.toString();
      if (e is ApiError &&
          e.status >= 400 &&
          e.status < 500 &&
          e.status != 429) {
        file = null;
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (message != null) Text(message!),
      TextButton(
        onPressed: busy
            ? null
            : () async {
                await runAction(context, () async {
                  final result = await widget.api.get(
                    '/customer/profiles/${widget.profileId}/files',
                  );
                  if (!context.mounted) return;
                  await showDialog<void>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Recent files'),
                      content: SizedBox(
                        width: 420,
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            if (items(result).isEmpty)
                              const Text('No files yet.'),
                            for (final f in items(result))
                              ListTile(
                                title: Text(
                                  f['category'] == 'photo'
                                      ? 'Private photo'
                                      : 'Identity document',
                                ),
                                subtitle: Text(f['state'].toString()),
                                onTap:
                                    f['state'] == 'confirmed' &&
                                        f['category'] == 'photo'
                                    ? () => runAction(c, () async {
                                        final data = await widget.api
                                            .downloadDocument(
                                              '/customer/files/${f['id']}',
                                            );
                                        if (sha256.convert(data).toString() !=
                                            f['sha256']) {
                                          throw const FormatException(
                                            'File integrity check failed.',
                                          );
                                        }
                                        if (c.mounted) {
                                          await showDialog<void>(
                                            context: c,
                                            builder: (_) => Dialog(
                                              child: Image.memory(
                                                data,
                                                fit: BoxFit.contain,
                                              ),
                                            ),
                                          );
                                        }
                                      })
                                    : null,
                              ),
                          ],
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  );
                });
              },
        child: const Text('Recent files'),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final kind in ['photo', 'document'])
            if (file == null || file?.kind == kind)
              OutlinedButton(
                onPressed: busy ? null : () => send(kind),
                child: Text(file != null ? 'Retry upload' : 'Upload $kind'),
              ),
        ],
      ),
    ],
  );
}
