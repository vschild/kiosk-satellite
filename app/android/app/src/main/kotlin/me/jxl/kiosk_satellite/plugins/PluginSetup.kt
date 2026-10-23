package me.jxl.kiosk_satellite.plugins

import java.io.File
import java.io.IOException
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * Settings page buttons and discovered choices for one plugin session. The
 * host starts every run, so a result for a run that was canceled, replaced
 * or timed out is dropped. A target is `button:<id>` or `choices:<key>`,
 * where a key is a setting key or the dotted path of a list row field.
 *
 * The latest list for each key is kept in [store], so a restarted plugin
 * shows its choices by label before it can list them again.
 */
class PluginSetup(private val manifest: PluginManifest, private val store: File? = null) {
    class Run(val id: String, val target: String, val origin: String) {
        var state = "running"
        var message = ""
        var code = ""
        var confirm: Map<String, String>? = null
        var deadline = 0L
    }

    /** A run that ended without the plugin finishing it, for the settings.cancel event. */
    data class Ended(val run: String, val reason: String)

    /** One key's choices. The revision changes with every new list, also across sessions. */
    class Listed(val revision: Long, val items: List<Map<String, String>>)

    private val runs = linkedMapOf<String, Run>()
    private val choices = linkedMapOf<String, Listed>()
    /** Choices the plugin turned off for this session, such as while the device they come from is unreachable. */
    private val off = linkedSetOf<String>()
    private val writing = Any()

    init { restore() }

    /** Starts a run on [target] and hands back the one it replaced, if that was still running. */
    @Synchronized fun start(target: String, origin: String, now: Long): Pair<Run, Ended?> {
        require(origin == "device" || origin == "remote") { "Invalid setup origin" }
        val previous = runs[target]?.takeIf { it.state == "running" }
        val run = Run(UUID.randomUUID().toString(), target, origin).also { it.deadline = now + ANSWER_MS }
        runs[target] = run
        return run to previous?.let { Ended(it.id, "replaced") }
    }

    /** Records progress or the outcome. False once [run] is over, so the plugin can stop its work. */
    @Synchronized fun result(run: String, state: String, message: String, now: Long): Boolean {
        require(state in setOf("running", "success", "error")) { "Setup state must be running, success or error" }
        require(message.length <= MAX_MESSAGE) { "Setup messages must be at most 1000 characters" }
        val current = active(run) ?: return false
        current.state = state
        current.message = message
        // A finished run has nothing left to confirm.
        if (state != "running") current.confirm = null
        current.deadline = now + if (current.confirm != null) CONFIRM_MS else ANSWER_MS
        return true
    }

    /** Asks the person who started [run] to confirm a step. One question at a time. */
    @Synchronized fun confirm(run: String, title: String, message: String, confirmLabel: String, now: Long): Boolean {
        require(title.isNotBlank() && title.length <= 80 && message.length <= MAX_MESSAGE && confirmLabel.isNotBlank() && confirmLabel.length <= 40) { "Invalid setup confirmation" }
        val current = active(run) ?: return false
        check(current.confirm == null) { "This run is already waiting for an answer" }
        current.confirm = mapOf("title" to title, "message" to message, "confirmLabel" to confirmLabel)
        current.deadline = now + CONFIRM_MS
        return true
    }

    /** Takes the answer to a pending confirmation. False when nothing on [run] was waiting. */
    @Synchronized fun answer(run: String, now: Long): Boolean {
        val current = active(run) ?: return false
        if (current.confirm == null) return false
        current.confirm = null
        current.deadline = now + ANSWER_MS
        return true
    }

    /** Stops [run] and forgets it, so the row goes back to its description. */
    @Synchronized fun cancel(run: String): Boolean {
        val current = active(run) ?: return false
        runs.remove(current.target)
        return true
    }

    /** Ends the running runs with nothing heard before their deadline. */
    @Synchronized fun expire(now: Long): List<Ended> = runs.values.filter { it.state == "running" && it.deadline <= now }.map { run ->
        run.state = "error"
        run.message = ""
        run.code = "timeout"
        run.confirm = null
        Ended(run.id, "timeout")
    }

    @Synchronized fun hasRunning() = runs.values.any { it.state == "running" }

    /** The first form: IDs with optional labels, at most 200. */
    fun setChoices(key: String, ids: Array<out String?>, labels: Array<out String?>?) {
        require(key in manifest.choiceKeys) { "Setting $key does not take plugin choices" }
        require(ids.size <= MAX_CHOICES && (labels == null || labels.size == ids.size)) { "Choices are at most 200 IDs with one label each" }
        require(labels == null || labels.all { it == null || it.length <= 80 }) { "Choice labels must be at most 80 characters" }
        list(key, ids.mapIndexed { i, id -> choice(id, labels?.get(i), null, null) })
    }

    /** Choices with a group heading, a detail line, a value, a category and an icon each, at most 2000. */
    fun setChoices(key: String, items: List<Map<String, Any?>?>) {
        require(key in manifest.choiceKeys) { "Setting $key does not take plugin choices" }
        require(items.size <= MAX_RICH_CHOICES) { "Choices are at most 2000" }
        list(key, items.map { item ->
            require(item != null && item.keys.all { it in CHOICE_FIELDS }) { "A choice holds only id, label, group, detail, value, category and icon" }
            choice(item["id"], item["label"], item["group"], item["detail"], item["icon"], item["value"], item["category"])
        })
    }

    private fun choice(id: Any?, label: Any?, group: Any?, detail: Any?, icon: Any? = null, value: Any? = null, category: Any? = null): Map<String, String> {
        require(id is String && id.isNotEmpty() && id.length <= 512) { "Choice IDs must be unique and 1 to 512 characters" }
        require(listOf(label, group, detail).all { it == null || (it is String && it.length <= MAX_CHOICE_TEXT) }) { "Choice labels, groups and details must be at most 120 characters" }
        require(listOf(value, category).all { it == null || (it is String && it.length <= MAX_CHOICE_TAG) }) { "Choice values and categories must be at most 40 characters" }
        require(icon == null || (icon is String && (icon.isEmpty() || icon.matches(ICON)))) { "Choice icons must be MDI names such as mdi:thermometer" }
        return buildMap {
            put("id", id)
            put("label", (label as String?)?.takeIf { it.isNotBlank() } ?: id)
            (group as String?)?.takeIf { it.isNotBlank() }?.let { put("group", it) }
            (detail as String?)?.takeIf { it.isNotBlank() }?.let { put("detail", it) }
            (icon as String?)?.takeIf { it.isNotEmpty() }?.let { put("icon", if (it.startsWith("mdi:")) it else "mdi:$it") }
            (value as String?)?.takeIf { it.isNotBlank() }?.let { put("value", it) }
            (category as String?)?.takeIf { it.isNotBlank() }?.let { put("category", it) }
        }
    }

    private fun list(key: String, items: List<Map<String, String>>) {
        require(items.map { it["id"] }.toSet().size == items.size) { "Choice IDs must be unique and 1 to 512 characters" }
        val listed = synchronized(this) {
            // Milliseconds keep a revision from repeating after a restart.
            Listed(maxOf((choices[key]?.revision ?: 0) + 1, System.currentTimeMillis()), items).also { choices[key] = it }
        }
        save(key, listed)
    }

    @Synchronized fun listed(key: String): Listed? = choices[key]

    @Synchronized fun hasChoices() = choices.isNotEmpty()

    @Synchronized fun setChoicesEnabled(key: String, enabled: Boolean) {
        require(key in manifest.choiceKeys) { "Setting $key does not take plugin choices" }
        if (enabled) off.remove(key) else off.add(key)
    }

    @Synchronized fun choicesEnabled(key: String) = key !in off

    /**
     * Runs, the revision of each key's choices and the choices themselves. With [sent], only the
     * lists whose revision it lacks come along, and it records them, so an unchanged list is not
     * sent on every run update.
     */
    @Synchronized fun snapshot(sent: MutableMap<String, Long>? = null): Map<String, Any?> = mapOf(
        "runs" to runs.mapValues { (_, run) ->
            mapOf("run" to run.id, "state" to run.state, "message" to run.message, "code" to run.code, "origin" to run.origin, "confirm" to run.confirm)
        },
        "choiceRevisions" to choices.mapValues { it.value.revision },
        "choicesOff" to off.toList(),
        "choices" to LinkedHashMap(choices.filter { (key, listed) -> sent == null || sent.put(key, listed.revision) != listed.revision }.mapValues { it.value.items }),
    )

    /** Writes the list unless a newer one took its place meanwhile. Choices still work when the file cannot be written. */
    private fun save(key: String, listed: Listed) {
        val dir = store ?: return
        synchronized(writing) {
            if (listed(key) !== listed) return
            val target = File(dir, "$key.json")
            val partial = File(dir, ".$key.json.partial")
            try {
                dir.mkdirs()
                val json = JSONObject().put("revision", listed.revision).put("choices", JSONArray(listed.items.map { JSONObject(it) }))
                partial.writeText(json.toString())
                if (!partial.renameTo(target)) throw IOException("Cannot keep the choices")
            } catch (_: IOException) {
                partial.delete()
            }
        }
    }

    /** Loads the kept lists of the keys this version declares and forgets the others. */
    private fun restore() {
        val dir = store ?: return
        for (file in dir.listFiles().orEmpty()) {
            val key = file.name.removeSuffix(".json")
            if (key !in manifest.choiceKeys || file.name == key) { file.delete(); continue }
            try {
                val json = JSONObject(file.readText())
                val array = json.getJSONArray("choices")
                val items = (0 until array.length()).map { i ->
                    val item = array.getJSONObject(i)
                    choice(item.opt("id"), item.opt("label"), item.opt("group"), item.opt("detail"), item.opt("icon"), item.opt("value"), item.opt("category"))
                }
                choices[key] = Listed(json.getLong("revision"), items)
            } catch (_: Exception) {
                file.delete()
            }
        }
    }

    private fun active(run: String) = runs.values.firstOrNull { it.id == run && it.state == "running" }

    companion object {
        /** A run with nothing heard from the plugin for this long fails. */
        const val ANSWER_MS = 60_000L
        /** How long a question waits for the person to answer. */
        const val CONFIRM_MS = 120_000L
        const val MAX_MESSAGE = 1000
        const val MAX_CHOICES = 200
        const val MAX_RICH_CHOICES = 2000
        const val MAX_CHOICE_TEXT = 120
        const val MAX_CHOICE_TAG = 40
        private val CHOICE_FIELDS = setOf("id", "label", "group", "detail", "icon", "value", "category")
        private val ICON = Regex("(mdi:)?[a-z0-9][a-z0-9-]{0,79}")
    }
}
