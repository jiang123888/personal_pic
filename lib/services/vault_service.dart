import 'package:flutter/services.dart';

/// 保险箱里的一条记录：只包含元数据，正文按需解密。
class VaultEntry {
  const VaultEntry({
    required this.uri,
    required this.name,
    required this.mime,
    required this.size,
    required this.modified,
  });

  final String uri;
  final String name;
  final String mime;
  final int size;
  final int modified;

  factory VaultEntry.fromMap(Map<Object?, Object?> map) {
    return VaultEntry(
      uri: map['uri'] as String? ?? '',
      name: map['name'] as String? ?? '未知文件',
      mime: map['mime'] as String? ?? '',
      size: (map['size'] as num?)?.toInt() ?? 0,
      modified: (map['modified'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');
  bool get isAudio => mime.startsWith('audio/');
}

class VaultException implements Exception {
  const VaultException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 与原生 VaultCrypto / VaultStore 通信的封装。
///
/// 密钥不会经过这里：密码只用于让原生层验证，验证通过后密钥留在原生内存。
class VaultService {
  static const MethodChannel _channel =
      MethodChannel('com.jiangty.private_vault/vault');

  static Future<T> _call<T>(Future<T?> Function() action) async {
    try {
      final value = await action();
      if (value == null && null is! T) {
        throw const VaultException('原生层未返回结果');
      }
      return value as T;
    } on PlatformException catch (e) {
      throw VaultException(e.message ?? '操作失败');
    } on MissingPluginException {
      throw const VaultException('原生模块未加载，请重新安装应用');
    }
  }

  static Future<bool> hasPassword() =>
      _call<bool>(() => _channel.invokeMethod<bool>('hasPassword'));

  static Future<bool> setPassword(String password) => _call<bool>(
        () => _channel.invokeMethod<bool>('setPassword', {'password': password}),
      );

  static Future<bool> unlock(String password) => _call<bool>(
        () => _channel.invokeMethod<bool>('unlock', {'password': password}),
      );

  static Future<bool> changePassword(String oldPassword, String newPassword) =>
      _call<bool>(
        () => _channel.invokeMethod<bool>('changePassword', {
          'oldPassword': oldPassword,
          'newPassword': newPassword,
        }),
      );

  static Future<void> lock() async {
    await _channel.invokeMethod<bool>('lock');
  }

  static Future<String?> getFolder() =>
      _call<String?>(() => _channel.invokeMethod<String>('getFolder'));

  static Future<String?> pickFolder() =>
      _call<String?>(() => _channel.invokeMethod<String>('pickFolder'));

  static Future<List<String>> pickFiles() async {
    final list = await _call<List<Object?>?>(
      () => _channel.invokeMethod<List<Object?>>('pickFiles'),
    );
    return list?.cast<String>() ?? const <String>[];
  }

  static Future<List<VaultEntry>> scan(String treeUri) async {
    final list = await _call<List<Object?>?>(
      () => _channel.invokeMethod<List<Object?>>('scan', {'tree': treeUri}),
    );
    if (list == null) return const <VaultEntry>[];
    return list
        .whereType<Map<Object?, Object?>>()
        .map(VaultEntry.fromMap)
        .toList(growable: false);
  }

  static Future<Map<String, Object?>> importFiles(
    String treeUri,
    List<String> uris, {
    bool deleteOriginals = true,
  }) async {
    final result = await _call<Map<Object?, Object?>?>(
      () => _channel.invokeMethod<Map<Object?, Object?>>('import', {
        'tree': treeUri,
        'uris': uris,
        'deleteOriginals': deleteOriginals,
      }),
    );
    return result?.map((key, value) => MapEntry('$key', value)) ??
        const <String, Object?>{};
  }

  static Future<Map<String, Object?>> decrypt(String treeUri, String uri) async {
    final result = await _call<Map<Object?, Object?>?>(
      () => _channel.invokeMethod<Map<Object?, Object?>>(
        'decrypt',
        {'tree': treeUri, 'uri': uri},
      ),
    );
    return result?.map((key, value) => MapEntry('$key', value)) ??
        const <String, Object?>{};
  }

  /// 解密到应用私有缓存，返回本地路径，用于应用内预览。
  static Future<String> preview(String uri) =>
      _call<String>(() => _channel.invokeMethod<String>('preview', {'uri': uri}));

  static Future<bool> delete(String uri) => _call<bool>(
        () => _channel.invokeMethod<bool>('delete', {'uri': uri}),
      );
}
