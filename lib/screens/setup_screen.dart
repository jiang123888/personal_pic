import 'package:flutter/material.dart';

import '../services/vault_service.dart';

/// 首次使用：设置保险箱主密码。
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    if (password.length < 6) {
      setState(() => _error = '密码至少需要 6 位');
      return;
    }
    if (password != _confirm.text) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await VaultService.setPassword(password);
      if (!mounted) return;
      if (ok) {
        widget.onDone();
      } else {
        setState(() => _error = '创建失败，请重试');
      }
    } on VaultException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.shield_outlined,
                  size: 56,
                  color: Color(0xFF5B8CFF),
                ),
                const SizedBox(height: 22),
                Text(
                  '创建隐私保险箱',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '设置一个主密码，用它加密你的照片、音频和视频。\n密码不会上传，也无法找回，请务必记牢。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  enabled: !_busy,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: '主密码',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _confirm,
                  obscureText: _obscure,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    labelText: '确认密码',
                    prefixIcon: const Icon(Icons.check_circle_outline_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 26),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Text('创建保险箱'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
