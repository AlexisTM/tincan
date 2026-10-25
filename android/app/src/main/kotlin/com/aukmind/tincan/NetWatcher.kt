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
    // Its own thread, so a network change never waits behind a file copy on io.
    private val netIo: ExecutorService = Executors.newSingleThreadExecutor()
    // Main thread only.
    private var channel: MethodChannel? = null
    private var lastInterfaces: List<Map<String, Any>>? = null
    private var lastNetwork: Network? = null
    private var lastAddrs: List<String>? = null
    private var defaultNetwork: Network? = null
    private var defaultAddrs: List<String>? = null
    private var watching = false

    fun attach(context: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "tincan/netifs")
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> netIo.execute {
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
        val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java)
        // The network we start on is the baseline, not a change.
        lastNetwork = cm.activeNetwork
        lastAddrs = lastNetwork?.let { cm.getLinkProperties(it) }?.let(::addrsOf)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (network != defaultNetwork) defaultAddrs = cm.getLinkProperties(network)?.let(::addrsOf)
                defaultNetwork = network
                push()
            }
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) {
                if (network == defaultNetwork) defaultAddrs = addrsOf(lp)
                push()
            }
            override fun onLost(network: Network) {
                if (defaultNetwork == network) {
                    defaultNetwork = null
                    defaultAddrs = null
                }
                push()
            }
        }
        cm.registerDefaultNetworkCallback(cb, main)
    }

    private fun addrsOf(lp: LinkProperties) = lp.linkAddresses.map { it.toString() }.sorted()

    private val send = Runnable {
        netIo.execute {
            val list = listInterfaces()
            main.post {
                val ch = channel ?: return@post
                // Wi-Fi to cellular can keep both interfaces up, so the
                // list alone misses it; other interface churn is noise.
                val networkChanged = defaultNetwork != lastNetwork || defaultAddrs != lastAddrs
                lastNetwork = defaultNetwork
                lastAddrs = defaultAddrs
                val redial = networkChanged && defaultNetwork != null
                if (list == lastInterfaces) {
                    if (redial) ch.invokeMethod("onNetworkChanged", null)
                    return@post
                }
                lastInterfaces = list
                if (!redial) {
                    ch.invokeMethod("changed", list)
                    return@post
                }
                // Redial only once Go has the new interfaces.
                ch.invokeMethod("changed", list, object : MethodChannel.Result {
                    override fun success(result: Any?) = ch.invokeMethod("onNetworkChanged", null)
                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                        ch.invokeMethod("onNetworkChanged", null)
                    override fun notImplemented() = ch.invokeMethod("onNetworkChanged", null)
                })
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
