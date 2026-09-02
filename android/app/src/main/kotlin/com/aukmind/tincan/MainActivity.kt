package com.aukmind.tincan

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.NetworkInterface
import java.util.concurrent.Executors

// local_auth needs a FragmentActivity; on a plain FlutterActivity every
// biometric prompt fails before it is shown.
class MainActivity : FlutterFragmentActivity() {
    private var netCallback: ConnectivityManager.NetworkCallback? = null
    private val main = Handler(Looper.getMainLooper())
    private var pushInterfaces: Runnable? = null
    private var lastInterfaces: List<Map<String, Any>>? = null // main thread only

    private val io = Executors.newSingleThreadExecutor()
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
        // Picked copies a killed process never released.
        if (savedInstanceState == null) io.execute { File(cacheDir, "picked").deleteRecursively() }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Go can't enumerate interfaces here (netlink is SELinux-blocked
        // for apps), so Java does it and Dart passes them down.
        val netifs = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tincan/netifs")
        netifs.setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> io.execute {
                    val list = listInterfaces()
                    runOnUiThread {
                        lastInterfaces = list
                        result.success(list)
                    }
                }
                else -> result.notImplemented()
            }
        }
        watchNetworks(netifs)

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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        netCallback?.let { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        netCallback = null
        pushInterfaces?.let { main.removeCallbacks(it) }
        super.cleanUpFlutterEngine(flutterEngine)
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

    // Pushes the interface list when the default network changes. One
    // change fires a burst of callbacks, so wait for it to settle.
    private fun watchNetworks(channel: MethodChannel) {
        val send = Runnable {
            io.execute {
                val list = listInterfaces()
                runOnUiThread {
                    if (list != lastInterfaces) {
                        lastInterfaces = list
                        channel.invokeMethod("changed", list)
                    }
                }
            }
        }
        pushInterfaces = send
        val push = {
            main.removeCallbacks(send)
            main.postDelayed(send, 300)
        }
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { push() }
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) { push() }
            override fun onLost(network: Network) { push() }
        }
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(cb)
        netCallback = cb
    }

    private fun listInterfaces(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        try {
            for (ni in NetworkInterface.getNetworkInterfaces()) {
                val addrs = mutableListOf<String>()
                try {
                    for (ia in ni.interfaceAddresses) {
                        val ip = ia.address.hostAddress ?: continue
                        addrs.add("${ip.substringBefore('%')}/${ia.networkPrefixLength}")
                    }
                } catch (_: Exception) {}
                out.add(
                    mapOf(
                        "name" to ni.name,
                        "index" to ni.index,
                        "mtu" to (runCatching { ni.mtu }.getOrDefault(1500)),
                        "up" to (runCatching { ni.isUp }.getOrDefault(false)),
                        "loopback" to (runCatching { ni.isLoopback }.getOrDefault(false)),
                        "pointToPoint" to (runCatching { ni.isPointToPoint }.getOrDefault(false)),
                        "multicast" to (runCatching { ni.supportsMulticast() }.getOrDefault(false)),
                        "addrs" to addrs,
                    )
                )
            }
        } catch (_: Exception) {}
        return out
    }
}
