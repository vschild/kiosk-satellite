package me.jxl.kiosk_satellite.airplay

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.ByteArrayOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import me.jxl.kiosk_satellite.BoundedWorker
import me.jxl.kiosk_satellite.fleet.MdnsPackets
import me.jxl.kiosk_satellite.fleet.MdnsPackets.DnsReader
import me.jxl.kiosk_satellite.fleet.MdnsPackets.lengthPrefixed
import me.jxl.kiosk_satellite.fleet.MdnsPackets.u16
import me.jxl.kiosk_satellite.fleet.MdnsPackets.u32
import me.jxl.kiosk_satellite.fleet.MdnsSocket

/**
 * How iPhones, iPads and Macs find the receiver: an mDNS responder for
 * `<id>@<name>._raop._tcp.local`, the service AirPlay 1 senders browse.
 * Raw packets, the way the fleet announcer works (fleet/FleetDiscovery)
 * and for the same reasons: NsdManager is unreliable on the devices this
 * app runs on. The lessons carried over from there: announce at start and
 * every 30 seconds, answer queries (an iPhone opening its AirPlay menu
 * asks and does not wait for the next announcement), reply unicast to a
 * query that asks for it (Wi-Fi that filters multicast toward phones lets
 * their queries through but not our replies), reply to a legacy query
 * from another port the plain DNS way, join the group on every interface
 * and again as interfaces come and go, check the raw bytes for our labels
 * before parsing anything, and hold a multicast lock.
 *
 * It also finds the sender's remote control ([lookupDacp]): the phone
 * announces `iTunes_Ctrl_<DACP-ID>._dacp._tcp.local`, and its port is
 * where play, pause and skip go. That lookup goes out two ways. A legacy
 * query from a socket of its own is answered straight to that socket: a
 * unicast reply to port 5353 lands on whichever socket Android picks
 * among the several bound there. A plain multicast query is answered to
 * the group, which is the answer that comes back through an mDNS
 * reflector from a phone on another network.
 */
internal class RaopMdns(
    private val context: Context,
    private val deviceId: ByteArray,
    private val openSocket: (Int) -> MulticastSocket = { MdnsSocket(it) },
) {
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var socket: MulticastSocket? = null
    @Volatile private var running = false
    @Volatile private var generation = 0L
    private var multicastLock: WifiManager.MulticastLock? = null
    private val receiver = BoundedWorker("airplay-mdns-rx", capacity = 1)
    private val joined = HashSet<String>()
    @Volatile private var name = ""
    @Volatile private var port = 0
    private var lastAnsweredAt = 0L

    private val idHex = deviceId.joinToString("") { "%02X".format(it) }
    private val host = "ks-${idHex.lowercase()}.local"
    private val serviceNeedle = MdnsPackets.labelNeedle("_raop")
    private val dacpNeedle = MdnsPackets.labelNeedle("_dacp")
    /** Remote control lookups still open: the instance name, and who waits. */
    private val pendingDacp = java.util.concurrent.ConcurrentHashMap<String, (Int) -> Unit>()
    private val hostNeedle = MdnsPackets.labelNeedle(host.substringBefore('.'))

    /** The instance's own label: `<id>@<name>`, cut to one DNS label. */
    private val instanceLabel: String
        get() {
            var label = "$idHex@$name"
            while (label.toByteArray(Charsets.UTF_8).size > 63) label = label.dropLast(1)
            return label
        }
    private val instance get() = "$instanceLabel.$SERVICE"

    private val announcer = object : Runnable {
        override fun run() {
            if (!running) return
            joinGroups()
            send(buildAnswer(TTL, HOST_TTL))
            handler.postDelayed(this, ANNOUNCE_INTERVAL_MS)
        }
    }

    fun start(name: String, port: Int) {
        this.name = name
        this.port = port
        if (running) {
            send(buildAnswer(TTL, HOST_TTL))
            return
        }
        running = true
        runCatching {
            multicastLock = (context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createMulticastLock("ks:airplay-mdns")
                .also { it.setReferenceCounted(false); it.acquire() }
        }
        val run = ++generation
        if (!io.execute {
            var canListen = true
            val s = runCatching { openSocket(MDNS_PORT) }.getOrElse {
                Log.w(TAG, "mDNS port 5353 unavailable, announce only")
                canListen = false
                runCatching { openSocket(0) }.getOrNull()
            }
            if (s != null) {
                runCatching { s.timeToLive = 255 }
                runCatching { (s as? MdnsSocket)?.setUnicastTtl() }
            }
            handler.post {
                if (!running || generation != run) {
                    s?.close()
                    return@post
                }
                if (s == null) {
                    Log.w(TAG, "no multicast socket, AirPlay is not discoverable")
                    return@post
                }
                socket = s
                joinGroups()
                if (canListen) receiver.execute { receiveLoop(s, run) }
                handler.post(announcer)
                for (delay in listOf(1_000L, 3_000L)) {
                    handler.postDelayed({
                        if (running && generation == run) send(buildAnswer(TTL, HOST_TTL))
                    }, delay)
                }
            }
        }) {
            Log.w(TAG, "mDNS worker unavailable")
        }
    }

    fun stop() {
        if (!running) return
        send(buildAnswer(0, 0))
        running = false
        ++generation
        receiver.discardPending()
        handler.removeCallbacks(announcer)
        val old = socket
        socket = null
        synchronized(joined) { joined.clear() }
        if (old != null) {
            val close = Runnable { runCatching { old.close() } }
            handler.postDelayed(close, 300)
        }
        multicastLock?.let { runCatching { if (it.isHeld) it.release() } }
        multicastLock = null
    }

    /** Re-announce, after a network change. */
    fun nudge() {
        if (!running) return
        joinGroups()
        send(buildAnswer(TTL, HOST_TTL))
    }

    /**
     * Finds the port of the sender's remote control for [dacpId], asking
     * a few times over a few seconds. [found] gets it on the main thread.
     */
    fun lookupDacp(dacpId: String, found: (Int) -> Unit) {
        val name = "iTunes_Ctrl_$dacpId.$DACP_SERVICE"
        val key = name.lowercase()
        val done = java.util.concurrent.atomic.AtomicBoolean(false)
        val once: (Int) -> Unit = { port ->
            if (done.compareAndSet(false, true)) {
                pendingDacp.remove(key)
                handler.post { found(port) }
            }
        }
        pendingDacp[key] = once
        handler.postDelayed({ pendingDacp.remove(key) }, 10_000)
        Thread({
            val s = runCatching { DatagramSocket(0) }.getOrNull() ?: return@Thread
            try {
                s.soTimeout = 1000
                val query = ByteArrayOutputStream(96)
                query.u16(0x4b53); query.u16(0); query.u16(1); query.u16(0); query.u16(0); query.u16(0)
                query.names(listOf("iTunes_Ctrl_$dacpId") + DACP_SERVICE.split('.'))
                query.u16(TYPE_SRV); query.u16(1)
                val bytes = query.toByteArray()
                val buf = ByteArray(9000)
                repeat(4) {
                    if (done.get()) return@Thread
                    runCatching { s.send(DatagramPacket(bytes, bytes.size, GROUP, MDNS_PORT)) }
                    // The same question from the group socket, answered to the group.
                    send(bytes.copyOf().also { it[0] = 0; it[1] = 0 })
                    val deadline = System.currentTimeMillis() + 1000L * (it + 1)
                    while (System.currentTimeMillis() < deadline) {
                        val packet = DatagramPacket(buf, buf.size)
                        try {
                            s.receive(packet)
                        } catch (_: java.net.SocketTimeoutException) {
                            break
                        }
                        val p = runCatching { srvPort(packet, name) }.getOrNull()
                        if (p != null && p > 0) {
                            once(p)
                            return@Thread
                        }
                    }
                }
                if (!done.get()) Log.i(TAG, "no remote control found for $dacpId")
            } finally {
                s.close()
            }
        }, "airplay-dacp-lookup").apply { isDaemon = true }.start()
    }

    private fun srvPort(packet: DatagramPacket, name: String): Int? {
        val r = DnsReader(packet.data, packet.offset, packet.length)
        r.u16()
        if (r.u16() and 0x8000 == 0) return null
        val qd = r.u16()
        val count = r.u16() + r.u16() + r.u16()
        repeat(qd) { r.name(); r.u16(); r.u16() }
        repeat(count) {
            val rname = r.name()
            val type = r.u16(); r.u16(); r.u32()
            val size = r.u16()
            val end = r.pos + size
            if (type == TYPE_SRV && rname.equals(name, ignoreCase = true)) {
                r.u16(); r.u16()
                return r.u16()
            }
            r.pos = end
        }
        return null
    }

    private fun receiveLoop(s: MulticastSocket, run: Long) {
        val buf = ByteArray(9000)
        while (running && generation == run) {
            val packet = DatagramPacket(buf, buf.size)
            try {
                s.receive(packet)
            } catch (e: Exception) {
                if (running && generation == run) Log.w(TAG, "receive failed: $e")
                break
            }
            if (!running || generation != run) break
            // A sender's remote control, answered to the group.
            if (pendingDacp.isNotEmpty() && MdnsPackets.mentions(packet, dacpNeedle)) {
                for ((name, waiting) in pendingDacp) {
                    val p = runCatching { srvPort(packet, name) }.getOrNull()
                    if (p != null && p > 0) waiting(p)
                }
            }
            // Nearly every packet on a busy network is about something
            // else. Only one that spells out our labels is parsed.
            if (!MdnsPackets.mentions(packet, serviceNeedle) && !MdnsPackets.mentions(packet, hostNeedle)) continue
            try {
                handle(packet)
            } catch (e: Exception) {
                Log.w(TAG, "bad mDNS packet: $e")
            }
        }
    }

    private fun handle(packet: DatagramPacket) {
        val r = DnsReader(packet.data, packet.offset, packet.length)
        val qid = r.u16()
        val flags = r.u16()
        if (flags and 0x8000 != 0) return
        val qd = r.u16(); r.u16(); r.u16(); r.u16()
        val questionsStart = r.pos
        var asked = false
        var wantsUnicast = false
        val own = instance
        repeat(qd) {
            val qname = r.name()
            val qtype = r.u16()
            val qclass = r.u16()
            val hit = when {
                qname.equals(SERVICE, true) -> qtype == TYPE_PTR || qtype == TYPE_ANY
                qname.equals(SERVICES, true) -> qtype == TYPE_PTR || qtype == TYPE_ANY
                qname.equals(own, true) -> qtype == TYPE_SRV || qtype == TYPE_TXT || qtype == TYPE_ANY
                qname.equals(host, true) -> qtype == TYPE_A || qtype == TYPE_ANY
                else -> false
            }
            if (hit) {
                asked = true
                if (qclass and 0x8000 != 0) wantsUnicast = true
            }
        }
        if (!asked) return
        val questionsEnd = r.pos
        if (packet.port != MDNS_PORT) {
            val questions = packet.data.copyOfRange(questionsStart, questionsEnd)
            send(buildAnswer(10, 10, qid, questions, qd, legacy = true), packet.address, packet.port)
            return
        }
        val answer = buildAnswer(TTL, HOST_TTL)
        if (wantsUnicast) send(answer, packet.address, MDNS_PORT)
        val now = System.currentTimeMillis()
        if (now - lastAnsweredAt >= 1_000) {
            lastAnsweredAt = now
            send(answer)
        }
    }

    private fun joinGroups() {
        val s = socket ?: return
        if (s.isClosed) return
        val nics = runCatching {
            NetworkInterface.getNetworkInterfaces().toList().filter { nic ->
                nic.isUp && !nic.isLoopback && nic.supportsMulticast() &&
                    nic.inetAddresses.toList().any { it is Inet4Address }
            }
        }.getOrDefault(emptyList())
        val present = nics.map { "${it.name}#${it.index}" }.toSet()
        synchronized(joined) {
            joined.retainAll(present)
            for (nic in nics) {
                val key = "${nic.name}#${nic.index}"
                if (key in joined) continue
                try {
                    s.joinGroup(InetSocketAddress(GROUP, MDNS_PORT), nic)
                    joined.add(key)
                } catch (e: Exception) {
                    val msg = e.message ?: ""
                    if (msg.contains("EADDRINUSE") || msg.contains("already", ignoreCase = true)) {
                        joined.add(key)
                    } else {
                        Log.w(TAG, "joinGroup on ${nic.name} failed: $e")
                    }
                }
            }
        }
    }

    private fun send(packet: ByteArray?, to: InetAddress = GROUP, port: Int = MDNS_PORT) {
        packet ?: return
        val target = socket ?: return
        io.execute {
            try {
                if (!target.isClosed) target.send(DatagramPacket(packet, packet.size, to, port))
            } catch (e: Exception) {
                Log.w(TAG, "mDNS send failed: $e")
            }
        }
    }

    /**
     * The service's records: the PTRs, SRV, TXT and the host's address.
     * TTL 0 is the goodbye. A [legacy] answer echoes the query and leaves
     * the cache-flush bit off.
     */
    private fun buildAnswer(
        ttl: Int,
        hostTtl: Int,
        qid: Int = 0,
        questions: ByteArray? = null,
        qd: Int = 0,
        legacy: Boolean = false,
    ): ByteArray? {
        if (port <= 0) return null
        val address = localIpv4() ?: return null
        val flush = if (legacy) 1 else 0x8001
        val label = instanceLabel
        val serviceLabels = SERVICE.split('.')
        val body = ByteArrayOutputStream(512)
        body.names(SERVICES.split('.')); body.u16(TYPE_PTR); body.u16(1); body.u32(ttl)
        body.lengthPrefixed { it.names(serviceLabels) }
        body.names(serviceLabels); body.u16(TYPE_PTR); body.u16(1); body.u32(ttl)
        body.lengthPrefixed { it.names(listOf(label) + serviceLabels) }
        body.names(listOf(label) + serviceLabels); body.u16(TYPE_SRV); body.u16(flush); body.u32(hostTtl)
        body.lengthPrefixed { it.u16(0); it.u16(0); it.u16(port); it.names(host.split('.')) }
        body.names(listOf(label) + serviceLabels); body.u16(TYPE_TXT); body.u16(flush); body.u32(ttl)
        body.lengthPrefixed { t ->
            for (entry in TXT) {
                val bytes = entry.toByteArray(Charsets.UTF_8)
                t.write(bytes.size)
                t.write(bytes)
            }
        }
        body.names(host.split('.')); body.u16(TYPE_A); body.u16(flush); body.u32(hostTtl)
        body.lengthPrefixed { it.write(address.address) }
        val out = ByteArrayOutputStream(512 + body.size())
        out.u16(qid); out.u16(0x8400); out.u16(if (questions != null) qd else 0)
        out.u16(5); out.u16(0); out.u16(0)
        questions?.let { out.write(it) }
        body.writeTo(out)
        return out.toByteArray()
    }

    private fun localIpv4(): Inet4Address? = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .sortedByDescending { it.name.startsWith("wlan") }
            .flatMap { nic -> nic.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .firstOrNull { it.isSiteLocalAddress }
    }.getOrNull()

    /** A name as labels, each written as is: an instance label may hold dots. */
    private fun ByteArrayOutputStream.names(labels: List<String>) {
        for (label in labels) {
            val bytes = label.toByteArray(Charsets.UTF_8)
            write(bytes.size)
            write(bytes)
        }
        write(0)
    }

    private companion object {
        const val TAG = "AirPlay"
        val io = BoundedWorker("airplay-mdns-tx", capacity = 32)
        const val SERVICE = "_raop._tcp.local"
        const val SERVICES = "_services._dns-sd._udp.local"
        const val DACP_SERVICE = "_dacp._tcp.local"
        const val ANNOUNCE_INTERVAL_MS = 30_000L
        const val TTL = 4500
        const val HOST_TTL = 120
        val GROUP: InetAddress = InetAddress.getByName("224.0.0.251")
        const val MDNS_PORT = 5353
        const val TYPE_A = 1
        const val TYPE_PTR = 12
        const val TYPE_TXT = 16
        const val TYPE_SRV = 33
        const val TYPE_ANY = 255

        /** What an AirPlay 1 speaker says it can do: ALAC or PCM, RSA, metadata. */
        val TXT = listOf(
            "txtvers=1", "ch=2", "cn=0,1", "da=true", "et=0,1", "ek=1", "md=0,1,2",
            "pw=false", "sf=0x4", "sr=44100", "ss=16", "sv=false", "tp=UDP",
            "vn=65537", "vs=105.1", "am=KioskSatellite", "fv=76400.10",
        )
    }
}
