package com.jiangty.private_vault

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.IOException

/**
 * 基于 SAF（Storage Access Framework）的存储层。
 *
 * 用户授权一个目录树后，本应用可以递归扫描、创建、读取、删除其中的文件，
 * 不需要「所有文件访问」这类敏感权限，也能在 Android 10+ 上正常工作。
 */
object VaultStore {

    const val SUFFIX = ".pvl"
    private const val MAX_DEPTH = 12

    /** 递归扫描目录树，返回所有保险箱文件（只解密元数据，不碰正文）。 */
    fun scan(context: Context, treeUri: Uri): List<Map<String, Any>> {
        val root = DocumentFile.fromTreeUri(context, treeUri) ?: return emptyList()
        val result = ArrayList<Map<String, Any>>()
        walk(context, root, result, 0)
        result.sortWith(compareByDescending { it["modified"] as Long })
        return result
    }

    private fun walk(
        context: Context,
        dir: DocumentFile,
        out: MutableList<Map<String, Any>>,
        depth: Int,
    ) {
        if (depth > MAX_DEPTH) return
        val children = try {
            dir.listFiles()
        } catch (_: Exception) {
            return
        }
        for (child in children) {
            if (child.isDirectory) {
                walk(context, child, out, depth + 1)
                continue
            }
            if (!child.isFile) continue
            val name = child.name ?: continue
            if (!name.endsWith(SUFFIX, ignoreCase = true)) continue
            try {
                val meta = readMeta(context, child.uri) ?: continue
                out.add(
                    mapOf(
                        "uri" to child.uri.toString(),
                        "name" to meta.name,
                        "mime" to meta.mime,
                        "size" to meta.size,
                        "modified" to meta.mtime,
                    ),
                )
            } catch (_: Exception) {
                // 损坏或其它应用的文件：跳过，不影响整体扫描。
            }
        }
    }

    /** 把源文件加密进目录树，文件名保留原名并追加 .pvl 后缀。 */
    fun importFiles(
        context: Context,
        treeUri: Uri,
        sources: List<Uri>,
        deleteOriginals: Boolean,
    ): Map<String, Any> {
        val dir = DocumentFile.fromTreeUri(context, treeUri) ?: throw IOException("无法打开目标目录")
        var ok = 0
        var failed = 0
        val errors = ArrayList<String>()

        for (source in sources) {
            try {
                importOne(context, dir, source)
                ok++
                if (deleteOriginals) {
                    // 只有持有该文件的写权限时才能删；失败就保留原文件。
                    runCatching { DocumentFile.fromSingleUri(context, source)?.delete() }
                }
            } catch (e: Exception) {
                failed++
                if (errors.size < 3) errors.add(e.message ?: e.toString())
            }
        }
        runCatching { ensureNoMedia(context, dir) }
        return mapOf("ok" to ok, "failed" to failed, "errors" to errors)
    }

    private fun importOne(context: Context, dir: DocumentFile, source: Uri) {
        val doc = DocumentFile.fromSingleUri(context, source)
            ?: throw IOException("无法读取源文件")
        val name = doc.name ?: "file_${System.currentTimeMillis()}"
        val mime = doc.type ?: "application/octet-stream"
        val declared = doc.length()
        // 部分 SAF 提供方拿不到文件大小时返回 0/-1，此时先数一遍字节，
        // 保证容器头里的原始长度准确（解密时会按它校验）。
        val size = if (declared > 0) declared else countBytes(context, source)

        val target = dir.createFile("application/octet-stream", "$name$SUFFIX")
            ?: throw IOException("无法在目标目录创建文件")

        try {
            val input = context.contentResolver.openInputStream(source)
                ?: throw IOException("无法打开源文件: $name")
            input.buffered().use { ins ->
                val output = context.contentResolver.openOutputStream(target.uri, "wt")
                    ?: throw IOException("无法写入目标文件: $name")
                output.buffered().use { outs ->
                    VaultCrypto.encrypt(
                        ins,
                        outs,
                        VaultMeta(name, mime, size, System.currentTimeMillis()),
                    )
                }
            }
        } catch (e: Exception) {
            // 加密失败时删掉半成品，避免留下损坏的 .pvl。
            runCatching { target.delete() }
            throw e
        }
    }

    /** 把 .pvl 还原成原始文件（同目录树根下），成功后删除保险箱文件。 */
    fun decryptFile(context: Context, treeUri: Uri, uri: Uri): Map<String, Any> {
        val dir = DocumentFile.fromTreeUri(context, treeUri) ?: throw IOException("无法打开目标目录")
        val meta = readMeta(context, uri) ?: throw IOException("不是有效的保险箱文件")

        val name = uniqueName(dir, meta.name)
        val mime = meta.mime.ifBlank { "application/octet-stream" }
        val target = dir.createFile(mime, name) ?: throw IOException("无法创建还原文件")

        try {
            val input = context.contentResolver.openInputStream(uri)
                ?: throw IOException("无法打开保险箱文件")
            input.buffered().use { ins ->
                val output = context.contentResolver.openOutputStream(target.uri, "wt")
                    ?: throw IOException("无法写入还原文件")
                output.buffered().use { outs -> VaultCrypto.decrypt(ins, outs) }
            }
        } catch (e: Exception) {
            runCatching { target.delete() }
            throw e
        }

        runCatching { DocumentFile.fromSingleUri(context, uri)?.delete() }
        return mapOf("name" to name, "mime" to mime, "size" to meta.size)
    }

    /** 解密到应用私有缓存，供应用内预览播放；退出/锁定时统一清理。 */
    fun preview(context: Context, uri: Uri): String {
        val meta = readMeta(context, uri) ?: throw IOException("不是有效的保险箱文件")
        val dir = File(context.cacheDir, "preview").apply { mkdirs() }
        val file = File(dir, sanitize(meta.name))
        val input = context.contentResolver.openInputStream(uri)
            ?: throw IOException("无法打开保险箱文件")
        input.buffered().use { ins ->
            file.outputStream().buffered().use { outs -> VaultCrypto.decrypt(ins, outs) }
        }
        return file.absolutePath
    }

    fun deleteFile(context: Context, uri: Uri): Boolean =
        runCatching { DocumentFile.fromSingleUri(context, uri)?.delete() == true }.getOrDefault(false)

    /** 清空预览缓存。锁定或退出时调用，避免明文残留。 */
    fun clearPreviewCache(context: Context) {
        runCatching { File(context.cacheDir, "preview").deleteRecursively() }
    }

    private fun readMeta(context: Context, uri: Uri): VaultMeta? =
        context.contentResolver.openInputStream(uri)?.use { raw ->
            raw.buffered().use { input -> VaultCrypto.readMeta(input) }
        }

    private fun uniqueName(dir: DocumentFile, name: String): String {
        var candidate = name
        var index = 1
        while (dir.findFile(candidate) != null && index < 1000) {
            val dot = name.lastIndexOf('.')
            candidate = if (dot > 0) {
                "${name.substring(0, dot)} ($index)${name.substring(dot)}"
            } else {
                "$name ($index)"
            }
            index++
        }
        return candidate
    }

    private fun sanitize(name: String): String =
        name.replace(Regex("[\\\\/:*?\"<>|]"), "_").ifBlank { "preview" }

    private fun countBytes(context: Context, uri: Uri): Long {
        val input = context.contentResolver.openInputStream(uri)
            ?: throw IOException("无法读取源文件")
        input.buffered().use { ins ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val n = ins.read(buffer)
                if (n < 0) break
                total += n
            }
            return total
        }
    }

    /** 目录里放一个 .nomedia，让媒体扫描器整目录跳过，进一步避免相册收录。 */
    private fun ensureNoMedia(context: Context, dir: DocumentFile) {
        if (dir.findFile(".nomedia") != null) return
        dir.createFile("application/octet-stream", ".nomedia")
    }
}
