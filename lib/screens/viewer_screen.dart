import 'dart:io';

import 'package:flutter/material.dart';

import '../services/vault_service.dart';

/// 应用内预览：先把文件解密到私有缓存，再显示；退出时删除缓存。
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.entry});

  final VaultEntry entry;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  String? _path;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final path = await VaultService.preview(widget.entry.uri);
      if (!mounted) return;
      setState(() => _path = path);
    } on VaultException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _cleanup() async {
    final path = _path;
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {
      // 缓存文件可能已被其它流程清理，忽略。
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildContent(theme)),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
            color: Colors.black,
            child: Text(
              '${entry.mime} · ${_formatBytes(entry.size)}',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    if (_path == null) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (!widget.entry.isImage) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '该格式暂不支持应用内播放。\n可以先「还原为原文件」，再用系统播放器打开。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, height: 1.6),
          ),
        ),
      );
    }
    return InteractiveViewer(
      maxScale: 5,
      child: Center(
        child: Image.file(
          File(_path!),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const Center(
            child: Text('图片解码失败', style: TextStyle(color: Colors.white70)),
          ),
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var size = bytes / 1024;
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unit]}';
}
