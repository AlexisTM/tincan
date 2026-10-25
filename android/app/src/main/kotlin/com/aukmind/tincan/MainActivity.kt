package com.aukmind.tincan

import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

// local_auth needs a FragmentActivity; on a plain FlutterActivity every
// biometric prompt fails before it is shown.
class MainActivity : FlutterFragmentActivity() {
    private var pendingPick: MethodChannel.Result? = null
    private var pendingCreate: MethodChannel.Result? = null
    private val openDocument = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val result = pendingPick ?: return@registerForActivityResult
        pendingPick = null
        if (uri == null) result.success(null) else offMain(result) { copyToCache(uri) }
    }
    private val createDocument =
        registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
            pendingCreate?.success(uri?.toString())
            pendingCreate = null
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Picked copies a killed process never released; once per process,
        // since a reopened activity may find one still being sent.
        if (!pickedSwept) {
            pickedSwept = true
            io.execute { File(cacheDir, "picked").deleteRecursively() }
        }
    }

    // One engine for the process: Back destroys the activity, but the app
    // must keep handling messages and notifying while the service runs.
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        return cache.get(ENGINE_ID)
            ?: FlutterEngine(context.applicationContext).also { cache.put(ENGINE_ID, it) }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NetWatcher.attach(this, flutterEngine)

        // The app decides the policy; this only starts and stops the
        // service that keeps the process alive.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tincan/service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val minutes = call.argument<Int>("stopAfterMinutes") ?: 0
                        TincanService.start(this, minutes)
                        result.success(true)
                    }
                    "stop" -> {
                        TincanService.stop(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // Streams documents in and out, where file_selector would load
        // a whole video into memory and can't save at all.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tincan/files")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> {
                        if (pendingPick != null) return@setMethodCallHandler result.error("busy", "a picker is already open", null)
                        pendingPick = result
                        openDocument.launch(call.argument<List<String>>("mimeTypes")?.toTypedArray() ?: arrayOf("*/*"))
                    }
                    "create" -> {
                        if (pendingCreate != null) return@setMethodCallHandler result.error("busy", "a picker is already open", null)
                        pendingCreate = result
                        createDocument.launch(call.argument<String>("name") ?: "tincan")
                    }
                    "write" -> {
                        val uri = Uri.parse(call.argument<String>("uri"))
                        val src = File(call.argument<String>("path")!!)
                        offMain(result) {
                            contentResolver.openOutputStream(uri, "wt")!!.use { out ->
                                src.inputStream().use { it.copyTo(out) }
                            }
                            null
                        }
                    }
                    "discard" -> {
                        val uri = Uri.parse(call.argument<String>("uri"))
                        offMain(result) { DocumentsContract.deleteDocument(contentResolver, uri); null }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun offMain(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            val out = runCatching(work)
            runOnUiThread {
                out.fold({ result.success(it) }, { result.error("io", it.message, null) })
            }
        }
    }

    // A private copy under its own name: the transport sends a file
    // under its base name.
    private fun copyToCache(uri: Uri): String {
        val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }?.replace('/', '_')?.takeIf { it.isNotBlank() } ?: "file"
        val dir = File(cacheDir, "picked/${System.nanoTime()}").apply { mkdirs() }
        val dst = File(dir, name)
        contentResolver.openInputStream(uri)!!.use { input ->
            dst.outputStream().use { input.copyTo(it) }
        }
        return dst.path
    }

    companion object {
        private const val ENGINE_ID = "main"
        private var pickedSwept = false
    }
}
