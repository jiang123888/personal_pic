# personal_pic

个人图片仓库。

**桌面显示名：数据库**

## 用途

存放个人性质的照片、视频、音频与其他任意素材的强大服务软件

## 备注

- 极轻量，快速响应
- 与本地相片系统分隔，避免穿透
- 保证绝对的隐私和安全

## 技术概览

- 平台：Android 8.0+（minSdk 26）
- 技术：Flutter 界面 + Kotlin 原生加密引擎
- 依赖：仅 `androidx.documentfile`，无其它第三方包
- 布局：仓库根目录即 Flutter 工程根目录

## 功能

| 功能 | 说明 |
|---|---|
| 加密导入 | 选中文件后原地加密，可选择删除原文件 |
| 自动发现 | 递归扫描授权目录，识别所有被加密的文件并列出 |
| 应用内查看 | 图片可直接预览；音频/视频可先还原再用系统播放器打开 |
| 还原 | 解密回原始文件名与格式，删除保险箱副本 |
| 删除 | 直接从保险箱移除 |
| 密码门禁 | 每次启动都要输入主密码 |

## 加密设计

- **KDF**：PBKDF2-HMAC-SHA256，200,000 次迭代，16 字节随机盐 → 256 位主密钥。
- **加密**：AES-256-GCM，按 64 KiB 分块流式处理，大视频不会占满内存。
- **防篡改**：每块 AAD 绑定块序号，IV 含序号且末块置标志位，可检测重排与截断；解密后还会校验总长度。
- **密钥位置**：口令校验与密钥派生都在 Kotlin 层完成，密钥只存在原生内存，不经过 Dart。

### 容器格式

```
0   "PVLT"              4   魔数
4   version             1   格式版本
5   flags               1
6   reserved            2
8   originalSize        8   原始字节数
16  chunkSize           4
20  nonceBase          12
32  metaNonce          12
44  metaLen             4
48  metaCipher  metaLen+16  加密的 JSON 元数据（原始文件名/MIME/大小/时间）
..  分块密文             每块 chunkSize+16
```

```bash
python tool/generate_icon.py
```

## 构建

在仓库根目录执行：

```bash
flutter pub get
flutter run                              # 连真机调试
flutter build apk --release --split-per-abi
```

产物在 `build/app/outputs/flutter-apk/`。

> 目前 release 用的是 debug 签名，正式发布前请在 `android/app/build.gradle.kts` 里换成自己的 keystore。

## 代码结构

```
lib/
  main.dart                     入口、主题、密码闸门
  services/vault_service.dart   MethodChannel 封装与数据模型
  screens/
    setup_screen.dart           设置主密码
    unlock_screen.dart          解锁
    home_screen.dart            文件网格、导入/还原/删除
    viewer_screen.dart          应用内图片预览
android/app/src/main/kotlin/com/jiangty/private_vault/
  VaultCrypto.kt                PBKDF2 / AES-GCM / 容器格式
  VaultStore.kt                 SAF 扫描、加密、还原、预览缓存
  MainActivity.kt               MethodChannel 与系统选择器
tool/generate_icon.py           生成应用图标
```

## 已知限制

- 音频/视频暂不支持应用内直接播放，需还原后用系统播放器打开。
- 还原的文件统一放在授权目录的根目录（不会还原到加密前的子目录）。
- 忘记密码无法找回：密钥完全由密码派生，没有后门。
- 全盘自动扫描需要"所有文件访问"权限，本版本改用 SAF 目录授权，符合上架要求；如需要全盘扫描可后续加开关。
