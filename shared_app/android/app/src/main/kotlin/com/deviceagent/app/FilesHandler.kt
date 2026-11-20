package com.deviceagent.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Native side of `ChannelNames.files` (Section 3.4).
 *
 * Stage 5 / item 67 fixes:
 *  - `content://` URIs ab **picked tree ke andar** hi allowed hain
 *    (pehle koi bhi content:// URI chal jati thi — `pickedTreeUri`
 *    store hota tha par check nahi hota tha).
 *  - Picked tree restart ke baad bhi yaad rehta hai (SharedPreferences +
 *    persisted URI permission re-verify).
 *  - Read size cap (10 MiB) — poori badi file memory mein nahi.
 *  - Saara file IO background thread par; result main thread par.
 *  - Item 74: pehli pending pick request overwrite hokar latakti nahi.
 */
class FilesHandler(private val activity: HandlerHost) {

    private companion object {
        const val MAX_READ_BYTES = 10 * 1024 * 1024 // server ki upload limit ke barabar
        const val PREFS = "uda_files"
        const val KEY_TREE = "picked_tree_uri"
    }

    private class FileOpException(val code: String, message: String) : Exception(message)

    private val executor = Executors.newSingleThreadExecutor()
    private var pendingPickResult: MethodChannel.Result? = null
    private var pickedTreeUri: Uri? = loadPickedTree()

    private val sandboxRoot: File
        get() = activity.getExternalFilesDir(null) ?: activity.filesDir

    fun register(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ChannelNames.files
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAllowedRoot" -> result.success(pickedTreeUri?.toString() ?: sandboxRoot.absolutePath)
                "listDirectory" -> listDirectory(call.argument("path") ?: "", result)
                "readFile" -> readFile(call.argument("path") ?: "", result)
                "writeFile" -> writeFile(
                    call.argument("path") ?: "",
                    call.argument("data") ?: "",
                    result
                )
                "deleteFile" -> deleteFile(call.argument("path") ?: "", result)
                "pickDirectory" -> pickDirectory(result)
                else -> result.notImplemented()
            }
        }
    }

    // ---- picked tree persistence ------------------------------------------

    private fun loadPickedTree(): Uri? {
        val raw = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_TREE, null) ?: return null
        val uri = Uri.parse(raw)
        // Permission abhi bhi valid hai? (user ne Settings se revoke kiya ho sakta hai)
        val stillGranted = activity.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        return if (stillGranted) uri else null
    }

    private fun savePickedTree(uri: Uri?) {
        activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().apply {
            if (uri == null) remove(KEY_TREE) else putString(KEY_TREE, uri.toString())
        }.apply()
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        pendingPickResult?.success(null) // purani pending request ko complete karo
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        activity.startActivityForResult(intent, MainActivity.REQUEST_CODE_PICK_DIRECTORY)
    }

    fun onDirectoryPicked(resultCode: Int, data: Intent?) {
        val pending = pendingPickResult
        pendingPickResult = null
        if (resultCode == Activity.RESULT_OK && data?.data != null) {
            val uri = data.data!!
            activity.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            pickedTreeUri = uri
            savePickedTree(uri)
            pending?.success(uri.toString())
        } else {
            pending?.success(null)
        }
    }

    // ---- path safety -------------------------------------------------------

    private fun resolveSandboxFile(relativePath: String): File? {
        val target = File(sandboxRoot, relativePath).canonicalFile
        val rootCanonical = sandboxRoot.canonicalFile
        val isWithinRoot = target == rootCanonical ||
            target.path.startsWith(rootCanonical.path + File.separator)
        return if (isWithinRoot) target else null
    }

    /** Item 67: content:// URI sirf picked tree ke andar valid hai. */
    private fun requireWithinPickedTree(path: String): Uri {
        val tree = pickedTreeUri
            ?: throw FileOpException("FORBIDDEN", "Koi folder pick nahi kiya gaya — pehle Permission Center se folder chunein")
        val uri = Uri.parse(path)
        val t = tree.toString()
        val u = uri.toString()
        val within = u == t || u.startsWith("$t/") || u.startsWith("$t%2F")
        if (!within) {
            throw FileOpException("FORBIDDEN", "Yeh path picked folder ke bahar hai")
        }
        return uri
    }

    // ---- IO helpers --------------------------------------------------------

    private fun runIo(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                activity.runOnUiThread { result.success(value) }
            } catch (e: FileOpException) {
                activity.runOnUiThread { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("IO_FAILED", e.message, null) }
            }
        }
    }

    // ---- operations --------------------------------------------------------

    private fun listDirectory(path: String, result: MethodChannel.Result) = runIo(result) {
        if (path.startsWith("content://")) {
            val uri = requireWithinPickedTree(path)
            val dir = DocumentFile.fromTreeUri(activity, uri)
            if (dir == null || !dir.isDirectory) throw FileOpException("NOT_FOUND", "Directory nahi mili")
            dir.listFiles().map {
                mapOf(
                    "name" to (it.name ?: ""),
                    "isDirectory" to it.isDirectory,
                    "size" to it.length(),
                    "modifiedAt" to it.lastModified(),
                    "path" to it.uri.toString()
                )
            }
        } else {
            val dir = resolveSandboxFile(path)
            if (dir == null || !dir.isDirectory) {
                throw FileOpException("NOT_FOUND", "Directory nahi mili ya sandbox se bahar hai")
            }
            (dir.listFiles() ?: emptyArray()).map {
                mapOf(
                    "name" to it.name,
                    "isDirectory" to it.isDirectory,
                    "size" to it.length(),
                    "modifiedAt" to it.lastModified(),
                    "path" to it.relativeTo(sandboxRoot).path
                )
            }
        }
    }

    private fun readFile(path: String, result: MethodChannel.Result) = runIo(result) {
        val bytes: ByteArray = if (path.startsWith("content://")) {
            val uri = requireWithinPickedTree(path)
            activity.contentResolver.openInputStream(uri)?.use { input ->
                // Cap+1 bytes tak padho; zyada mila to reject.
                val buf = input.readNBytesCompat(MAX_READ_BYTES + 1)
                if (buf.size > MAX_READ_BYTES) throw FileOpException("TOO_LARGE", "File 10 MiB se badi hai")
                buf
            } ?: throw FileOpException("NOT_FOUND", "File nahi mili")
        } else {
            val file = resolveSandboxFile(path)
            if (file == null || !file.isFile) throw FileOpException("NOT_FOUND", "File nahi mili")
            if (file.length() > MAX_READ_BYTES) throw FileOpException("TOO_LARGE", "File 10 MiB se badi hai")
            file.readBytes()
        }
        Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    /**
     * Item 14 (native layer): server + Dart dispatcher ke baad teesri line
     * of defence. List `data_channel_security.dart` / `device_policy.dart`
     * se sync rakhni hai.
     */
    private fun isDangerousFileName(rawPath: String): Boolean {
        val dangerous = listOf(".exe", ".msi", ".msix", ".appx", ".bat", ".cmd", ".com", ".scr", ".pif", ".ps1", ".psm1", ".vbs", ".vbe", ".wsf", ".wsh", ".hta", ".js", ".jse", ".lnk", ".reg", ".cpl", ".msc", ".gadget", ".inf", ".sh", ".bash", ".zsh", ".run", ".bin", ".py", ".pl", ".rb", ".desktop", ".appimage", ".deb", ".rpm", ".apk", ".aab", ".dex", ".dll", ".so", ".dylib", ".sys", ".jar")
        val decoded = try { Uri.decode(rawPath) } catch (_: Exception) { rawPath }
        val name = decoded.substringAfterLast('/').substringAfterLast('\\').lowercase()
        return name.split(':').any { raw ->
            val part = raw.trimEnd('.', ' ')
            dangerous.any { part.endsWith(it) }
        }
    }

    private fun writeFile(path: String, base64Data: String, result: MethodChannel.Result) = runIo(result) {
        if (isDangerousFileName(path)) {
            throw FileOpException("FORBIDDEN_TYPE", "Is file type ko likhna security policy se blocked hai")
        }
        val bytes = Base64.decode(base64Data, Base64.NO_WRAP)
        if (bytes.size > MAX_READ_BYTES) throw FileOpException("TOO_LARGE", "Data 10 MiB se bada hai")
        if (path.startsWith("content://")) {
            val uri = requireWithinPickedTree(path)
            val out = activity.contentResolver.openOutputStream(uri, "wt")
                ?: throw FileOpException("WRITE_FAILED", "File open nahi hui")
            out.use { it.write(bytes) }
        } else {
            val file = resolveSandboxFile(path)
                ?: throw FileOpException("FORBIDDEN", "Sandbox se bahar likhna mana hai")
            file.parentFile?.mkdirs()
            file.writeBytes(bytes)
        }
        true
    }

    private fun deleteFile(path: String, result: MethodChannel.Result) = runIo(result) {
        if (path.startsWith("content://")) {
            val uri = requireWithinPickedTree(path)
            DocumentsContract.deleteDocument(activity.contentResolver, uri)
        } else {
            resolveSandboxFile(path)?.delete() ?: false
        }
    }

    /** `InputStream.readNBytes` API 33+ hai; yeh purane API par bhi chalta hai. */
    private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(8192)
        var total = 0
        while (total < limit) {
            val n = read(buf, 0, minOf(buf.size, limit - total))
            if (n < 0) break
            out.write(buf, 0, n)
            total += n
        }
        return out.toByteArray()
    }
}
