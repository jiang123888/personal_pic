import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/unlock_screen.dart';
import 'services/vault_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PrivateVaultApp());
}

class PrivateVaultApp extends StatelessWidget {
  const PrivateVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF5B8CFF);
    return MaterialApp(
      title: '数据库',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ).copyWith(surface: const Color(0xFF12151B)),
        scaffoldBackgroundColor: const Color(0xFF0D1016),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        snackBarTheme:
            const SnackBarThemeData(behavior: SnackBarBehavior.floating),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF1A1E26),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
      ),
      home: const RootGate(),
    );
  }
}

enum _Stage { loading, setup, unlock, ready }

/// 入口闸门：没有密码就设置，有密码就解锁，解锁后才进主界面。
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  _Stage _stage = _Stage.loading;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final hasPassword = await VaultService.hasPassword();
      if (!mounted) return;
      setState(() => _stage = hasPassword ? _Stage.unlock : _Stage.setup);
    } catch (_) {
      if (!mounted) return;
      setState(() => _stage = _Stage.setup);
    }
  }

  void _onUnlocked() {
    if (mounted) setState(() => _stage = _Stage.ready);
  }

  Future<void> _lock() async {
    await VaultService.lock();
    if (!mounted) return;
    setState(() => _stage = _Stage.unlock);
  }

  @override
  Widget build(BuildContext context) {
    return switch (_stage) {
      _Stage.loading => const _SplashScreen(),
      _Stage.setup => SetupScreen(onDone: _onUnlocked),
      _Stage.unlock => UnlockScreen(onUnlocked: _onUnlocked),
      _Stage.ready => HomeScreen(onLock: _lock),
    };
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_person_rounded, size: 56, color: Color(0xFF5B8CFF)),
            SizedBox(height: 20),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
          ],
        ),
      ),
    );
  }
}
