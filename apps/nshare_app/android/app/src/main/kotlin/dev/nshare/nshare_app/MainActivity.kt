package dev.nshare.nshare_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var exportSource: String? = null
    private val cancelled = AtomicBoolean(false)
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.nshare/files").setMethodCallHandler { call, reply ->
            when (call.method) {
                "importFolder", "exportFolder" -> {
                    if (pending != null) { reply.error("busy", "A folder operation is active", null) }
                    else {
                        pending = reply
                        exportSource = if (call.method == "exportFolder") call.argument<String>("path") else null
                        cancelled.set(false)
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                        startActivityForResult(intent, 7401)
                    }
                }
                "cancelFolderOperation" -> { cancelled.set(true); reply.success(null) }
                else -> reply.notImplemented()
            }
        }
    }
    @Deprecated("Android activity result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7401) return
        val reply = pending ?: return
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            pending = null; reply.success(null); return
        }
        try { contentResolver.takePersistableUriPermission(tree,
            (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) }
        catch (_: Exception) { /* Permission remains valid for this import/export. */ }
        val source = exportSource
        Thread {
            var staged: File? = null
            try {
                val document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                if (source == null) {
                    val container = File(filesDir, "nshare-imports/${UUID.randomUUID()}")
                    staged = container; container.mkdirs()
                    val root = File(container, displayName(document))
                    var count = 0
                    fun copy(uri: Uri, destination: File, depth: Int, ancestors: Set<String>) {
                        check(!cancelled.get()) { "Folder import cancelled" }
                        check(depth <= 128 && ++count <= 1_000_000) { "Folder limit exceeded" }
                        check(!ancestors.contains(uri.toString())) { "Cyclic document tree" }
                        if (mime(uri) == DocumentsContract.Document.MIME_TYPE_DIR) {
                            check(destination.mkdir()) { "Cannot create staging directory or duplicate folder name" }
                            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(uri))
                            contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { cursor ->
                                while (cursor.moveToNext()) {
                                    val child = DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
                                    copy(child, File(destination, displayName(child)), depth + 1, ancestors + uri.toString())
                                }
                            } ?: error("Cannot enumerate selected folder")
                        } else {
                            check(destination.createNewFile()) { "Duplicate document name" }
                            contentResolver.openInputStream(uri)?.use { input ->
                                destination.outputStream().use { output ->
                                    val buffer = ByteArray(65536)
                                    while (true) {
                                        check(!cancelled.get()) { "Folder import cancelled" }
                                        check(container.usableSpace > 1024 * 1024) { "Insufficient staging space" }
                                        val length = input.read(buffer); if (length < 0) break
                                        output.write(buffer, 0, length)
                                    }
                                }
                            } ?: error("Cannot read document")
                        }
                    }
                    copy(document, root, 0, emptySet())
                    runOnUiThread { pending = null; reply.success(root.absolutePath) }
                } else {
                    val root = File(source).canonicalFile
                    check(root.isDirectory) { "Receive folder does not exist" }
                    val exported = DocumentsContract.createDocument(contentResolver, document,
                        DocumentsContract.Document.MIME_TYPE_DIR, "nshare-${System.currentTimeMillis()}") ?: error("Cannot create export folder")
                    fun export(file: File, parent: Uri) {
                        check(!cancelled.get()) { "Export cancelled" }
                        check(file.canonicalPath == file.absolutePath) { "Links cannot be exported" }
                        if (file.name == ".nshare-state" && file.parentFile?.canonicalFile == root) return
                        val uri = DocumentsContract.createDocument(contentResolver, parent,
                            if (file.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream", file.name)
                            ?: error("Cannot create export document")
                        if (file.isDirectory) {
                            val children = file.listFiles() ?: error("Cannot read export directory")
                            children.forEach { export(it, uri) }
                        } else contentResolver.openOutputStream(uri)?.use { output -> file.inputStream().use { it.copyTo(output, 65536) } }
                            ?: error("Cannot write export document")
                    }
                    val entries = root.listFiles() ?: error("Cannot read received folder")
                    entries.forEach { export(it, exported) }
                    runOnUiThread { pending = null; reply.success(exported.toString()) }
                }
            } catch (error: Exception) {
                staged?.deleteRecursively()
                runOnUiThread { pending = null; reply.error("folder", error.message, null) }
            }
        }.start()
    }
    private fun displayName(uri: Uri): String {
        val value = column(uri, DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        require(value.isNotEmpty() && value != "." && value != ".." && !value.contains('/') && !value.contains('\\')) { "Unsafe document name" }
        return value
    }
    private fun mime(uri: Uri) = column(uri, DocumentsContract.Document.COLUMN_MIME_TYPE)
    private fun column(uri: Uri, name: String): String = contentResolver.query(uri, arrayOf(name), null, null, null)?.use {
        check(it.moveToFirst()) { "Document is unavailable" }; it.getString(0)
    } ?: error("Cannot read document metadata")
}
