package me.jxl.kiosk_satellite.plugins

import org.json.JSONArray
import org.json.JSONObject

/** SDK event contract and per-session bounds for asynchronous commands. */
internal object PluginHostPolicy {
    fun entityEvent(event: String) = event.startsWith("ha.entity.") &&
        event.removePrefix("ha.entity.").let { it.length <= 255 && it.matches(Regex("[a-z0-9_]+\\.[a-z0-9_]+")) }
    fun validEvent(event: String) = event in events || entityEvent(event)
    val events = setOf(
        "screensaver.state", "screensaver.countdown", "screensaver.view",
        "screen.state", "screen.brightness", "screen.ambient",
        "device.power", "device.network", "device.volume", "device.light", "device.key",
        "detection.motion", "detection.face", "detection.proximity",
        "detection.person", "detection.presence", "voice.interaction", "voice.state", "intercom.state",
        "wakeword.state", "wakeword.detected", "stopword.detected", "camera.view", "browser.state",
        "audio.noise", "voice.text", "voice.level", "voice.overlay", "voice.skin", "voice.appearance",
    )

    /** The key of a Home Assistant subscription event, `ha.subscription.KEY`, or null. */
    fun haSubscriptionKey(event: String) = event.removePrefix("ha.subscription.").takeIf { it != event && haKey(it) }
    fun haKey(key: String) = key.matches(Regex("[A-Za-z0-9_.-]{1,64}"))

    /**
     * A detached copy of a plugin's Home Assistant message with JSON values only, at most 32 KB encoded. The app
     * checks the message itself; this keeps what crosses the channel small and plain.
     */
    fun haMessage(message: Map<*, *>): Map<String, Any?> {
        @Suppress("UNCHECKED_CAST")
        val copy = haJson(message, 0) as Map<String, Any?>
        require(JSONObject(copy).toString().toByteArray().size <= 32_768) { "Home Assistant message is larger than 32 KB" }
        return copy
    }

    private fun haJson(value: Any?, depth: Int): Any? {
        require(depth <= 32) { "Home Assistant message is nested too deeply" }
        return when (value) {
            null, JSONObject.NULL -> null
            is String, is Boolean, is Int, is Long -> value
            is Number -> value.toDouble().also { require(it.isFinite()) { "Home Assistant messages hold finite numbers only" } }
            is Map<*, *> -> LinkedHashMap<String, Any?>().apply {
                for ((key, item) in value) {
                    require(key is String) { "Home Assistant message keys must be strings" }
                    put(key, haJson(item, depth + 1))
                }
            }
            is Iterable<*> -> value.map { haJson(it, depth + 1) }
            is Array<*> -> value.map { haJson(it, depth + 1) }
            is JSONObject, is JSONArray -> haJson(jsonValue(value), depth)
            else -> throw IllegalArgumentException("Home Assistant messages hold JSON values only")
        }
    }

    /**
     * The `device.key` payload. Null for printing and modifier keys, so typed
     * text never reaches a plugin. [name] is Android's KEYCODE_ constant.
     */
    fun keyPayload(name: String, code: Int, scanCode: Int, down: Boolean, repeat: Int, printing: Boolean, modifier: Boolean, time: String): Map<String, Any>? =
        if (printing || modifier) null else mapOf(
            "key" to name.removePrefix("KEYCODE_"),
            "code" to code,
            "scanCode" to scanCode,
            "action" to if (down) "down" else "up",
            "repeat" to repeat,
            "time" to time,
        )
}

internal class PluginCommandBudget {
    private var windowStart: Long? = null
    private var count = 0
    private var pending = 0

    @Synchronized fun acquire(now: Long = System.nanoTime()) {
        if (windowStart == null || now - windowStart!! >= 1_000_000_000L) { windowStart = now; count = 0 }
        check(pending < 8) { "At most 8 KS commands may be pending" }
        check(count < 20) { "At most 20 KS commands per second" }
        pending++; count++
    }
    @Synchronized fun release() { if (pending > 0) pending-- }
}
