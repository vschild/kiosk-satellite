package me.jxl.kiosk_satellite.plugins

import java.util.UUID

/**
 * Settings page buttons and discovered choices for one plugin session. The
 * host starts every run, so a result for a run that was canceled, replaced
 * or timed out is dropped. A target is `button:<id>` or `choices:<key>`.
 */
class PluginSetup(private val manifest: PluginManifest) {
    class Run(val id: String, val target: String, val origin: String) {
        var state = "running"
        var message = ""
        var code = ""
        var confirm: Map<String, String>? = null
        var deadline = 0L
    }

    /** A run that ended without the plugin finishing it, for the settings.cancel event. */
    data class Ended(val run: String, val reason: String)

    private val runs = linkedMapOf<String, Run>()
    private val choices = linkedMapOf<String, List<Map<String, String>>>()

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

    @Synchronized fun setChoices(key: String, ids: Array<out String?>, labels: Array<out String?>?) {
        require(key in manifest.choiceKeys) { "Setting $key does not take plugin choices" }
        require(ids.size <= MAX_CHOICES && (labels == null || labels.size == ids.size)) { "Choices are at most 200 IDs with one label each" }
        require(ids.all { it != null && it.isNotEmpty() && it.length <= 512 } && ids.toSet().size == ids.size) { "Choice IDs must be unique and 1 to 512 characters" }
        require(labels == null || labels.all { it == null || it.length <= 80 }) { "Choice labels must be at most 80 characters" }
        choices[key] = ids.mapIndexed { i, id -> mapOf("id" to id!!, "label" to (labels?.get(i)?.takeIf { it.isNotBlank() } ?: id)) }
    }

    @Synchronized fun snapshot(): Map<String, Any?> = mapOf(
        "runs" to runs.mapValues { (_, run) ->
            mapOf("run" to run.id, "state" to run.state, "message" to run.message, "code" to run.code, "origin" to run.origin, "confirm" to run.confirm)
        },
        "choices" to LinkedHashMap(choices),
    )

    private fun active(run: String) = runs.values.firstOrNull { it.id == run && it.state == "running" }

    companion object {
        /** A run with nothing heard from the plugin for this long fails. */
        const val ANSWER_MS = 60_000L
        /** How long a question waits for the person to answer. */
        const val CONFIRM_MS = 120_000L
        const val MAX_MESSAGE = 1000
        const val MAX_CHOICES = 200
    }
}
