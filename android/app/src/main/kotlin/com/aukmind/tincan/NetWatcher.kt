package com.aukmind.tincan

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

// Process-wide, like the cached engine: the activity can die while the
// service keeps the transport up.
internal val io: ExecutorService = Executors.newSingleThreadExecutor()

/**
 * Go can't enumerate interfaces here (netlink is SELinux-blocked for
 * apps), so this does it and Dart passes them down. Watches the default
 * network for the life of the process, not of the activity.
 */
object NetWatcher {
    private val main = Handler(Looper.getMainLooper())
    // Main thread only.
    private var channel: MethodChannel? = null
    private var lastInterfaces: List<Map<String, Any>>? = null
    private var lastNetwork: Network? = null
    private var defaultNetwork: Network? = null
    private var watching = false
    private var primed = false

    fun attach(context: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "tincan/netifs")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> io.execute {
                    val list = listInterfaces()
                    main.post {
                        lastInterfaces = list
                        result.success(list)
                    }
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        if (watching) return
        watching = true
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { main.post { defaultNetwork = network; push() } }
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) { main.post { push() } }
            override fun onLost(network: Network) {
                main.post {
                    if (defaultNetwork == network) defaultNetwork = null
                    push()
                }
            }
        }
        context.applicationContext.getSystemService(ConnectivityManager::class.java)
            .registerDefaultNetworkCallback(cb)
    }

    private val send = Runnable {
        io.execute {
            val list = listInterfaces()
            main.post {
                val ch = channel ?: return@post
                val listChanged = list != lastInterfaces
                if (listChanged) {
                    lastInterfaces = list
                    ch.invokeMethod("changed", list)
                }
                // Wi-Fi to cellular can keep both interfaces up, so the
                // list alone misses it.
                if (listChanged || defaultNetwork != lastNetwork) {
                    lastNetwork = defaultNetwork
                    // The first callback is just the network we started on.
                    if (primed) ch.invokeMethod("onNetworkChanged", null)
                }
                primed = true
            }
        }
    }

    // One change fires a burst of callbacks, so wait for it to settle.
    private fun push() {
        main.removeCallbacks(send)
        main.postDelayed(send, 300)
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
