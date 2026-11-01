package com.jiangty.private_vault

import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/** 容器里保存的原始文件信息，解密时用来还原文件名与类型。 */
data class VaultMeta(
    val name: String,
    val mime: String,
    val size: Long,
    val mtime: Long,
)

/**
 * 保险箱加解密引擎。
 *
 * 密钥只在原生内存中停留，永远不会通过 MethodChannel 传到 Dart 层。
 * 容器格式（小端无关，全部大端）：
 *
 * ```
 * 0   magic  "PVLT"          4
 * 4   version                 1
 * 5   flags                   1
 * 6   reserved                2
 * 8   originalSize            8
 * 16  chunkSize               4
 * 20  nonceBase              12
 * 32  metaNonce              12
 * 44  metaLen                 4
 * 48  metaCipher        metaLen + 16   (AES-GCM，AAD = 前 48 字节)
 * ..  分块密文            每块 chunkSize + 16
 * ```
 *
 * 每个分块的 IV = nonceBase[0..8] + 块序号(4B)；最后一块的序号最高位置 1，
 * 用于识别结尾，防止文件被截断后静默通过。分块 AAD 追加块序号，防止重排。
 */
object VaultCrypto {

    private const val MAGIC = "PVLT"
    private const val VERSION = 1
    private const val HEADER_FIXED = 48
    private const val CHUNK = 64 * 1024
    private const val TAG_BITS = 128
    private const val TAG_LEN = TAG_BITS / 8
    private const val ITERATIONS = 200_000
    private const val KEY_BITS = 256
    private const val CRED_NAME = "vault.cred"
    private const val VERIFIER = "PrivateVault-v1-ok"

    private val random = SecureRandom()

    @Volatile
    private var masterKey: SecretKeySpec? = null

    fun isUnlocked(): Boolean = masterKey != null

    fun lock() {
        masterKey = null
    }

    fun hasPassword(dir: File): Boolean = File(dir, CRED_NAME).isFile

    /** 首次设置密码：生成随机盐，派生密钥，并把验证块写入凭据文件。 */
    fun setPassword(dir: File, password: String): Boolean {
        require(password.length >= 6) { "密码至少需要 6 位" }
        val salt = ByteArray(16).also { random.nextBytes(it) }
        val key = deriveKey(password, salt)
        val nonce = ByteArray(12).also { random.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(TAG_BITS, nonce))
        val sealed = cipher.doFinal(VERIFIER.toByteArray(Charsets.UTF_8))
        File(dir, CRED_NAME).writeBytes(salt + nonce + sealed)
        masterKey = key
        return true
    }

    /** 解锁：用输入的密码派生密钥，解验证块。成功才把密钥留在内存。 */
    fun unlock(dir: File, password: String): Boolean {
        val file = File(dir, CRED_NAME)
        if (!file.isFile) return false
        val bytes = file.readBytes()
        if (bytes.size < 16 + 12 + TAG_LEN) return false
        val salt = bytes.copyOfRange(0, 16)
        val nonce = bytes.copyOfRange(16, 28)
        val sealed = bytes.copyOfRange(28, bytes.size)
        return try {
            val key = deriveKey(password, salt)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, nonce))
            val plain = cipher.doFinal(sealed)
            val ok = String(plain, Charsets.UTF_8) == VERIFIER
            if (ok) masterKey = key
            ok
        } catch (_: Exception) {
            false
        }
    }

    fun changePassword(dir: File, oldPassword: String, newPassword: String): Boolean {
        if (!hasPassword(dir)) return false
        if (!unlock(dir, oldPassword)) return false
        // 旧凭据文件先备份，写新凭据失败时回滚。
        val cred = File(dir, CRED_NAME)
        val backup = cred.readBytes()
        return try {
            setPassword(dir, newPassword)
            true
        } catch (e: Exception) {
            cred.writeBytes(backup)
            unlock(dir, oldPassword)
            throw e
        }
    }

    // ---------------------------------------------------------------- 加密

    fun encrypt(input: InputStream, output: OutputStream, meta: VaultMeta) {
        val key = requireKey()

        val nonceBase = ByteArray(12).also { random.nextBytes(it) }
        val metaNonce = ByteArray(12).also { random.nextBytes(it) }

        val metaJson = JSONObject()
            .put("n", meta.name)
            .put("m", meta.mime)
            .put("s", meta.size)
            .put("t", meta.mtime)
            .toString()
            .toByteArray(Charsets.UTF_8)

        val header = buildHeader(meta.size, CHUNK, nonceBase, metaNonce, metaJson.size)
        val metaCipher = gcm(Cipher.ENCRYPT_MODE, key, metaNonce, header).doFinal(metaJson)

        output.write(header)
        output.write(metaCipher)

        val buffer = ByteArray(CHUNK)
        var index = 0
        while (true) {
            val read = readUpTo(input, buffer)
            val last = read < CHUNK
            val iv = buildIv(nonceBase, index, last)
            val sealed = gcm(Cipher.ENCRYPT_MODE, key, iv, chunkAad(header, index))
                .doFinal(buffer, 0, read)
            output.write(sealed)
            index++
            if (last) break
        }
        output.flush()
    }

    // ---------------------------------------------------------------- 解密

    fun decrypt(input: InputStream, output: OutputStream): VaultMeta {
        val key = requireKey()
        val header = readExactly(input, HEADER_FIXED) ?: throw IOException("文件头不完整")
        val meta = readMetaFromHeader(key, header, input)

        val origSize = ByteBuffer.wrap(header, 8, 8).order(ByteOrder.BIG_ENDIAN).long
        val chunk = ByteBuffer.wrap(header, 16, 4).order(ByteOrder.BIG_ENDIAN).int
        if (origSize < 0) throw IOException("原始长度字段异常")
        if (chunk < 1024 || chunk > 1024 * 1024) throw IOException("分块大小字段异常")
        val nonceBase = header.copyOfRange(20, 32)
        val totalChunks = if (origSize == 0L) 1 else ((origSize + chunk - 1) / chunk).toInt()

        var written = 0L
        for (i in 0 until totalChunks) {
            val last = i == totalChunks - 1
            val plainLen = if (last) (origSize - written).toInt() else chunk
            val sealed = readExactly(input, plainLen + TAG_LEN) ?: throw IOException("文件被截断或损坏")
            val iv = buildIv(nonceBase, i, last)
            val plain = gcm(Cipher.DECRYPT_MODE, key, iv, chunkAad(header, i)).doFinal(sealed)
            output.write(plain)
            written += plain.size
        }
        if (written != origSize) throw IOException("文件长度校验失败")
        output.flush()
        return meta
    }

    /** 只读元数据，用于扫描列表，不解密正文。 */
    fun readMeta(input: InputStream): VaultMeta? {
        val key = requireKey()
        val header = readExactly(input, HEADER_FIXED) ?: return null
        return readMetaFromHeader(key, header, input)
    }

    // ---------------------------------------------------------------- 内部

    private fun readMetaFromHeader(key: SecretKeySpec, header: ByteArray, input: InputStream): VaultMeta {
        if (header.size < HEADER_FIXED) throw IOException("文件头不完整")
        val magic = String(header, 0, 4, Charsets.US_ASCII)
        if (magic != MAGIC) throw IOException("不是保险箱文件")
        val version = header[4].toInt()
        if (version != VERSION) throw IOException("不支持的格式版本: $version")

        val metaNonce = header.copyOfRange(32, 44)
        val metaLen = ByteBuffer.wrap(header, 44, 4).order(ByteOrder.BIG_ENDIAN).int
        if (metaLen <= 0 || metaLen > 64 * 1024) throw IOException("元数据长度异常")
        val sealed = readExactly(input, metaLen + TAG_LEN) ?: throw IOException("元数据不完整")
        val plain = gcm(Cipher.DECRYPT_MODE, key, metaNonce, header).doFinal(sealed)
        val json = JSONObject(String(plain, Charsets.UTF_8))
        return VaultMeta(
            name = json.optString("n", "unknown"),
            mime = json.optString("m", "application/octet-stream"),
            size = json.optLong("s", 0L),
            mtime = json.optLong("t", 0L),
        )
    }

    private fun requireKey(): SecretKeySpec =
        masterKey ?: throw IllegalStateException("保险箱未解锁")

    private fun deriveKey(password: String, salt: ByteArray): SecretKeySpec {
        val spec = PBEKeySpec(password.toCharArray(), salt, ITERATIONS, KEY_BITS)
        val raw = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(spec)
            .encoded
        spec.clearPassword()
        return SecretKeySpec(raw, "AES")
    }

    private fun gcm(mode: Int, key: SecretKeySpec, nonce: ByteArray, aad: ByteArray): Cipher {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(mode, key, GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return cipher
    }

    private fun buildHeader(
        origSize: Long,
        chunk: Int,
        nonceBase: ByteArray,
        metaNonce: ByteArray,
        metaLen: Int,
    ): ByteArray = ByteBuffer.allocate(HEADER_FIXED).order(ByteOrder.BIG_ENDIAN).apply {
        put(MAGIC.toByteArray(Charsets.US_ASCII))
        put(VERSION.toByte())
        put(0.toByte())
        putShort(0)
        putLong(origSize)
        putInt(chunk)
        put(nonceBase)
        put(metaNonce)
        putInt(metaLen)
    }.array()

    private fun buildIv(nonceBase: ByteArray, index: Int, last: Boolean): ByteArray =
        ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN).apply {
            put(nonceBase.copyOfRange(0, 8))
            val counter = if (last) index or Int.MIN_VALUE else index
            putInt(counter)
        }.array()

    private fun chunkAad(header: ByteArray, index: Int): ByteArray =
        ByteBuffer.allocate(header.size + 4).order(ByteOrder.BIG_ENDIAN).apply {
            put(header)
            putInt(index)
        }.array()

    /** 尽量读满 buffer，返回实际读取字节数（末块可能不足 CHUNK）。 */
    private fun readUpTo(input: InputStream, buffer: ByteArray): Int {
        var offset = 0
        while (offset < buffer.size) {
            val n = input.read(buffer, offset, buffer.size - offset)
            if (n < 0) break
            offset += n
        }
        return offset
    }

    /** 精确读取 length 字节：流已结束时返回 null，读到一半断掉则抛异常。 */
    private fun readExactly(input: InputStream, length: Int): ByteArray? {
        val buffer = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val n = input.read(buffer, offset, length - offset)
            if (n < 0) break
            offset += n
        }
        if (offset == 0) return null
        if (offset != length) throw IOException("数据不完整：期望 $length 字节，实际 $offset 字节")
        return buffer
    }
}
