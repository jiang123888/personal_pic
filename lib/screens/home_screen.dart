import 'package:flutter/material.dart';

import '../services/vault_service.dart';
import 'viewer_screen.dart';

/// 主界面：列出保险箱里的文件，负责导入、还原、删除。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onLock});

  final Future<void> Function() onLock;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _tree;
  List<VaultEntry> _entries = const <VaultEntry>[];
  bool _loading = true;
  bool _busy = false;
  String _busyLabel = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final tree = await VaultService.getFolder();
      if (!mounted) return;
      setState(() => _tree = tree);
      if (tree != null) {
        await _scan(showSpinner: true);
      } else {
        setState(() => _loading = false);
      }
    } on VaultException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(e.message);
    }
  }

  Future<void> _scan({bool showSpinner = false}) async {
    final tree = _tree;
    if (tree == null) return;
    if (showSpinner && mounted) setState(() => _loading = true);
    try {
      final list = await VaultService.scan(tree);
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } on VaultException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(e.message);
    }
  }

  Future<void> _chooseFolder() async {
    try {
      final uri = await VaultService.pickFolder();
      if (uri == null || !mounted) return;
      setState(() {
        _tree = uri;
        _entries = const <VaultEntry>[];
        _loading = true;
      });
      await _scan();
      if (mounted && _entries.isEmpty) {
        _toast('已授权文件夹，点击右下角开始加密文件');
      }
    } on VaultException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _import() async {
    if (_tree == null) {
      await _chooseFolder();
      if (_tree == null || !mounted) return;
    }
    final tree = _tree!;
    final uris = await VaultService.pickFiles();
    if (uris.isEmpty || !mounted) return;

    final deleteOriginals = await _askDeleteOriginals(uris.length);
    if (deleteOriginals == null || !mounted) return;

    await _runBusy('正在加密 ${uris.length} 个文件…', () async {
      final result = await VaultService.importFiles(
        tree,
        uris,
        deleteOriginals: deleteOriginals,
      );
      final ok = (result['ok'] as num?)?.toInt() ?? 0;
      final failed = (result['failed'] as num?)?.toInt() ?? 0;
      await _scan();
      if (!mounted) return;
      _toast(
        failed == 0
            ? '已加密 $ok 个文件'
            : '成功 $ok 个，失败 $failed 个（文件可能被占用或权限不足）',
      );
    });
  }

  Future<void> _restore(VaultEntry entry) async {
    final confirmed = await _confirm(
      title: '还原文件',
      message: '将「${entry.name}」解密回原始位置，并删除保险箱中的副本。',
      confirmText: '还原',
    );
    if (confirmed != true || !mounted) return;

    final tree = _tree;
    if (tree == null) return;
    await _runBusy('正在还原…', () async {
      final result = await VaultService.decrypt(tree, entry.uri);
      final name = result['name'] as String? ?? entry.name;
      await _scan();
      if (!mounted) return;
      _toast('已还原：$name');
    });
  }

  Future<void> _delete(VaultEntry entry) async {
    final confirmed = await _confirm(
      title: '删除文件',
      message: '「${entry.name}」将被永久删除，无法恢复。',
      confirmText: '删除',
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    await _runBusy('正在删除…', () async {
      final ok = await VaultService.delete(entry.uri);
      await _scan();
      if (!mounted) return;
      _toast(ok ? '已删除' : '删除失败');
    });
  }

  Future<void> _preview(VaultEntry entry) async {
    if (!entry.isImage) {
      await _showActions(entry);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ViewerScreen(entry: entry)),
    );
    if (mounted) await _scan();
  }

  Future<void> _showActions(VaultEntry entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A1E26),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.restore_rounded),
                title: const Text('还原为原文件'),
                onTap: () => Navigator.pop(context, 'restore'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('从保险箱删除'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (action == 'restore') {
      await _restore(entry);
    } else if (action == 'delete') {
      await _delete(entry);
    }
  }

  Future<void> _runBusy(
    String label,
    Future<void> Function() action,
  ) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
    });
    try {
      await action();
    } on VaultException catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) _toast('操作失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = '';
        });
      }
    }
  }

  Future<bool?> _askDeleteOriginals(int count) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('加密 $count 个文件'),
        content: const Text(
          '加密完成后，原文件要怎么处理？\n\n'
          '· 删除原文件：更彻底，相册里不会留下副本\n'
          '· 保留原文件：仅在无法删除时才建议，原文件仍可见',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留原文件'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除原文件'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmText,
    bool danger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('隐私保险箱'),
            if (_entries.isNotEmpty)
              Text(
                '${_entries.length} 个加密文件',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '选择文件夹',
            onPressed: _busy ? null : _chooseFolder,
            icon: const Icon(Icons.folder_open_rounded),
          ),
          IconButton(
            tooltip: '重新扫描',
            onPressed: _busy ? null : () => _scan(showSpinner: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '锁定',
            onPressed: _busy ? null : () => widget.onLock(),
            icon: const Icon(Icons.lock_rounded),
          ),
        ],
      ),
      floatingActionButton: _tree == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.add_rounded),
              label: const Text('加密导入'),
            ),
      body: Stack(
        children: [
          _buildBody(),
          if (_busy)
            Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(
                  color: const Color(0xCC0D1016),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(strokeWidth: 2.5),
                        const SizedBox(height: 18),
                        Text(
                          _busyLabel,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (_tree == null) {
      return _Hint(
        icon: Icons.folder_special_outlined,
        title: '还没有选择保险箱目录',
        message: '选择一个文件夹，应用会把加密文件存放在这里。\n'
            '该目录之外的文件不会被修改。',
        actionLabel: '选择文件夹',
        onAction: _chooseFolder,
      );
    }
    if (_entries.isEmpty) {
      return _Hint(
        icon: Icons.lock_open_rounded,
        title: '保险箱还是空的',
        message: '点击右下角「加密导入」，选择照片、音频或视频。\n'
            '加密后它们会变成 .pvl 文件，相册扫描不到。',
        actionLabel: '重新扫描',
        onAction: () => _scan(showSpinner: true),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 96),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.92,
      ),
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return _EntryCard(
          entry: entry,
          onTap: () => _preview(entry),
          onMore: () => _showActions(entry),
        );
      },
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.onTap,
    required this.onMore,
  });

  final VaultEntry entry;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: const Color(0xFF161A22),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        onLongPress: onMore,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  iconSize: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                  onPressed: onMore,
                  icon: const Icon(Icons.more_vert_rounded),
                ),
              ),
              const Spacer(),
              Center(
                child: Icon(
                  _iconFor(entry),
                  size: 42,
                  color: const Color(0xFF5B8CFF),
                ),
              ),
              const Spacer(),
              Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _formatBytes(entry.size),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(VaultEntry entry) {
    if (entry.isImage) return Icons.image_rounded;
    if (entry.isVideo) return Icons.movie_rounded;
    if (entry.isAudio) return Icons.audiotrack_rounded;
    return Icons.insert_drive_file_rounded;
  }
}

class _Hint extends StatelessWidget {
  const _Hint({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 54, color: const Color(0xFF5B8CFF)),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: onAction,
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(actionLabel),
            ),
          ],
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
