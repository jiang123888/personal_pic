import 'package:flutter_test/flutter_test.dart';

import 'package:private_vault/services/vault_service.dart';

void main() {
  test('VaultEntry 能从原生返回的 Map 正确构建', () {
    final entry = VaultEntry.fromMap(<Object?, Object?>{
      'uri': 'content://demo/1',
      'name': 'IMG_0001.jpg',
      'mime': 'image/jpeg',
      'size': 1024,
      'modified': 1700000000000,
    });

    expect(entry.uri, 'content://demo/1');
    expect(entry.name, 'IMG_0001.jpg');
    expect(entry.size, 1024);
    expect(entry.isImage, isTrue);
    expect(entry.isVideo, isFalse);
  });

  test('缺少字段时使用安全默认值', () {
    final entry = VaultEntry.fromMap(<Object?, Object?>{'uri': 'content://x'});

    expect(entry.name, '未知文件');
    expect(entry.size, 0);
    expect(entry.isImage, isFalse);
  });
}
