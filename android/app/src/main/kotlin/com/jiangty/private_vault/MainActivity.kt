package com.jiangty.private_vault

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.jiangty.private_vault/vault"
        private const val REQ_FOLDER = 1001
        private const val REQ_FILES = 1002
        private const val PREFS = "private_vault_prefs"
        private const val KEY_TREE = "tree_uri"
    }

    private val worker = Executors.newSingleThreadExecutor()

    private var folderResult: MethodChannel.Result? = null
    private var filesResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPassword" -> result.success(VaultCrypto.hasPassword(filesDir))

                "setPassword" -> {
                    val pwd = call.argument<String>("password").orEmpty()
                    onWorker(result) { VaultCrypto.setPassword(filesDir, pwd) }
                }

                "unlock" -> {
                    val pwd = call.argument<String>("password").orEmpty()
                    onWorker(result) { VaultCrypto.unlock(filesDir, pwd) }
                }

                "changePassword" -> {
                    val oldPwd = call.argument<String>("oldPassword").orEmpty()
                    val newPwd = call.argument<String>("newPassword").orEmpty()
                    onWorker(result) { VaultCrypto.changePassword(filesDir, oldPwd, newPwd) }
                }

                "lock" -> {
                    VaultCrypto.lock()
                    VaultStore.clearPreviewCache(this)
                    result.success(true)
                }

                "getFolder" -> result.success(prefs().getString(KEY_TREE, null))

                "pickFolder" -> pickFolder(result)

                "pickFiles" -> pickFiles(result)

                "scan" -> {
                    val tree = Uri.parse(call.argument<String>("tree").orEmpty())
                    onWorker(result) { VaultStore.scan(this, tree) }
                }

                "import" -> {
                    val tree = Uri.parse(call.argument<String>("tree").orEmpty())
                    val uris = call.argument<List<String>>("uris").orEmpty().map { Uri.parse(it) }
                    val deleteOriginals = call.argument<Boolean>("deleteOriginals") ?: true
                    onWorker(result) { VaultStore.importFiles(this, tree, uris, deleteOriginals) }
                }

                "decrypt" -> {
                    val tree = Uri.parse(call.argument<String>("tree").orEmpty())
                    val uri = Uri.parse(call.argument<String>("uri").orEmpty())
                    onWorker(result) { VaultStore.decryptFile(this, tree, uri) }
                }

                "preview" -> {
                    val uri = Uri.parse(call.argument<String>("uri").orEmpty())
                    onWorker(result) { VaultStore.preview(this, uri) }
                }

                "delete" -> {
                    val uri = Uri.parse(call.argument<String>("uri").orEmpty())
                    onWorker(result) { VaultStore.deleteFile(this, uri) }
                }

                else -> result.notImplemented()
            }
        }
    }

    // ------------------------------------------------------------ 线程调度

    /** 把耗时操作（PBKDF2、加解密大文件）放到后台线程，结果回主线程。 */
    private fun onWorker(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error("vault_error", e.message ?: "操作失败", null) }
            }
        }
    }

    // ------------------------------------------------------------ 选择器

    private fun pickFolder(result: MethodChannel.Result) {
        folderResult?.success(null)
        folderResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        startActivityForResult(intent, REQ_FOLDER)
    }

    private fun pickFiles(result: MethodChannel.Result) {
        filesResult?.success(emptyList<String>())
        filesResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, REQ_FILES)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        when (requestCode) {
            REQ_FOLDER -> {
                val result = folderResult ?: return
                folderResult = null
                val intent = data
                val uri = intent?.data
                if (resultCode != Activity.RESULT_OK || intent == null || uri == null) {
                    result.success(null)
                    return
                }
                val flags = intent.flags and (
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                runCatching { contentResolver.takePersistableUriPermission(uri, flags) }
                prefs().edit().putString(KEY_TREE, uri.toString()).apply()
                result.success(uri.toString())
            }

            REQ_FILES -> {
                val result = filesResult ?: return
                filesResult = null
                if (resultCode != Activity.RESULT_OK) {
                    result.success(emptyList<String>())
                    return
                }
                val uris = ArrayList<String>()
                val clip = data?.clipData
                if (clip != null) {
                    for (i in 0 until clip.itemCount) {
                        clip.getItemAt(i)?.uri?.let { uris.add(it.toString()) }
                    }
                } else {
                    data?.data?.let { uris.add(it.toString()) }
                }
                result.success(uris)
            }
        }
    }

    private fun prefs() = getSharedPreferences(PREFS, MODE_PRIVATE)

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }
}
