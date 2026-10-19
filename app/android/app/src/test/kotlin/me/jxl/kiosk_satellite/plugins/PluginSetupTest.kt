package me.jxl.kiosk_satellite.plugins

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PluginSetupTest {
    private fun manifest(change: (JSONObject) -> Unit = {}) = JSONObject("""{
      "schemaVersion":1,"apiVersion":1,"id":"bridge","name":"Bridge",
      "version":"1.0.0","minAndroidSdk":24,"entryClass":"example.Bridge",
      "description":"Example","author":"Example","license":"Apache-2.0",
      "capabilities":[],
      "settings":[
        {"key":"host","type":"string","title":"Host","default":"","group":"Connection"},
        {"key":"token","type":"secret","title":"Token","default":"","group":"Connection"},
        {"key":"device","type":"string","title":"Device","default":"","choices":"plugin","group":"Device","visibleWhen":{"key":"host","notEmpty":true}},
        {"key":"timeout","type":"number","title":"Timeout","default":30,"min":5,"max":300,"step":5}
      ],
      "buttons":[
        {"id":"test","title":"Test connection","label":"Test","group":"Connection","visibleWhen":{"key":"host","notEmpty":true}},
        {"id":"pair","title":"Pair","label":"Pair","group":"Pairing","confirm":{"title":"Pair?","message":"Press the bridge button first.","confirmLabel":"Pair"}}
      ],
      "groups":[{"title":"Pairing"}]
    }""").also(change)

    private fun rejects(action: () -> Unit) {
        // A missing manifest key throws JSONException, like every other manifest field.
        try { action(); fail("Expected invalid input to be rejected") } catch (_: IllegalArgumentException) {} catch (_: org.json.JSONException) {}
    }

    @Test fun buttonsAndChoicesValidate() {
        val value = PluginManifest(manifest())
        assertTrue(value.hasButton("test"))
        assertFalse(value.hasButton("show"))
        assertEquals(setOf("device"), value.choiceKeys)
        // A button shows by the saved settings, like the setting it names.
        val empty = JSONObject(value.config(JSONObject()))
        assertFalse(value.buttonVisible("test", empty))
        assertTrue(value.buttonVisible("pair", empty))
        assertTrue(value.buttonVisible("test", JSONObject(value.config(JSONObject().put("host", "10.0.0.2")))))
        assertFalse(value.settingVisible("device", empty))

        fun button(change: (JSONObject) -> Unit) = manifest { change(it.getJSONArray("buttons").getJSONObject(0)) }
        rejects { PluginManifest(button { it.remove("label") }) }
        rejects { PluginManifest(button { it.put("id", "Test") }) }
        rejects { PluginManifest(button { it.put("label", "x".repeat(41)) }) }
        rejects { PluginManifest(button { it.put("visibleWhen", JSONObject().put("key", "token").put("notEmpty", true)) }) }
        rejects { PluginManifest(button { it.put("visibleWhen", JSONObject().put("key", "missing").put("notEmpty", true)) }) }
        rejects { PluginManifest(button { it.put("confirm", JSONObject().put("title", "Sure?")) }) }
        rejects { PluginManifest(button { it.put("confirm", JSONObject("""{"title":"a","message":"b","confirmLabel":"c","extra":1}""")) }) }
        rejects { PluginManifest(manifest { it.getJSONArray("buttons").put(JSONObject("""{"id":"test","title":"Again","label":"Go"}""")) }) }
        rejects { PluginManifest(manifest { it.put("buttons", JSONArray((0..20).map { i -> JSONObject("""{"id":"b$i","title":"B","label":"B"}""") })) }) }
        // Plugin choices belong to top-level text settings.
        fun device(change: (JSONObject) -> Unit) = manifest { change(it.getJSONArray("settings").getJSONObject(2)) }
        rejects { PluginManifest(device { it.put("choices", "static") }) }
        rejects { PluginManifest(device { it.put("type", "select").put("options", JSONArray().put("a")).put("default", "a") }) }
        rejects { PluginManifest(manifest { it.getJSONArray("settings").getJSONObject(1).put("choices", "plugin") }) }
    }

    @Test fun manifestsWithoutTheNewKeysAreUnchanged() {
        val value = PluginManifest(manifest { it.remove("buttons"); it.remove("groups"); it.getJSONArray("settings").getJSONObject(2).remove("choices") })
        assertEquals(0, value.buttons.length())
        assertTrue(value.choiceKeys.isEmpty())
    }

    @Test fun partialUpdatesKeepEverySavedValue() {
        val value = PluginManifest(manifest())
        val saved = JSONObject(value.config(JSONObject().put("host", "bridge.local").put("token", "secret").put("timeout", 120)))
        val next = value.config(value.merged(saved, JSONObject().put("device", "lamp-1")))
        assertEquals("secret", next["token"])
        assertEquals(120, next["timeout"])
        assertEquals("lamp-1", next["device"])
        // An admin patch sends the masked marker for a secret it did not touch.
        val patched = value.config(value.merged(saved, value.unmasked(JSONObject().put("token", PluginManifest.SECRET_SET).put("timeout", 60), saved)))
        assertEquals("secret", patched["token"])
        assertEquals(60, patched["timeout"])
        value.checkValues(JSONObject().put("timeout", 10))
        rejects { value.checkValues(JSONObject().put("timeout", 7)) }
        rejects { value.checkValues(JSONObject().put("unknown", 1)) }
    }

    @Test fun runsReportUntilTheyEndAndStaleOnesAreDropped() {
        val setup = PluginSetup(PluginManifest(manifest()))
        val (first, replaced) = setup.start("button:test", "remote", 0)
        assertNull(replaced)
        assertTrue(setup.result(first.id, "running", "Connecting", 1_000))
        assertEquals("Connecting", run(setup, "button:test")["message"])
        // Pressing again replaces the run, and the old one can no longer report.
        val (second, ended) = setup.start("button:test", "device", 2_000)
        assertEquals(PluginSetup.Ended(first.id, "replaced"), ended)
        assertFalse(setup.result(first.id, "success", "Done", 3_000))
        assertTrue(setup.result(second.id, "success", "Connected", 3_000))
        assertFalse(setup.result(second.id, "error", "Late", 4_000))
        assertEquals("success", run(setup, "button:test")["state"])
        assertFalse(setup.hasRunning())
        rejects { setup.result(second.id, "done", "", 0) }
        rejects { setup.result(second.id, "running", "x".repeat(1001), 0) }
    }

    @Test fun cancelForgetsTheRunAndTimeoutsFailQuietOnes() {
        val setup = PluginSetup(PluginManifest(manifest()))
        val (run, _) = setup.start("choices:device", "remote", 0)
        assertTrue(setup.cancel(run.id))
        assertFalse(setup.cancel(run.id))
        assertFalse(setup.result(run.id, "success", "", 1))
        assertTrue(@Suppress("UNCHECKED_CAST") (setup.snapshot()["runs"] as Map<String, Any>).isEmpty())

        val (quiet, _) = setup.start("button:test", "remote", 0)
        assertTrue(setup.expire(PluginSetup.ANSWER_MS - 1).isEmpty())
        // Progress pushes the deadline out.
        setup.result(quiet.id, "running", "Still scanning", 50_000)
        assertTrue(setup.expire(PluginSetup.ANSWER_MS).isEmpty())
        assertEquals(listOf(PluginSetup.Ended(quiet.id, "timeout")), setup.expire(50_000 + PluginSetup.ANSWER_MS))
        assertEquals("timeout", run(setup, "button:test")["code"])
        assertFalse(setup.result(quiet.id, "success", "", 200_000))
    }

    @Test fun oneQuestionAtATimeWaitsLongerForThePerson() {
        val setup = PluginSetup(PluginManifest(manifest()))
        val (run, _) = setup.start("button:pair", "device", 0)
        assertTrue(setup.confirm(run.id, "Trust this bridge?", "SHA-256 AB:CD", "Trust", 0))
        try { setup.confirm(run.id, "Again?", "", "Yes", 0); fail() } catch (_: IllegalStateException) {}
        assertEquals("Trust", (run(setup, "button:pair")["confirm"] as Map<*, *>)["confirmLabel"])
        assertTrue(setup.expire(PluginSetup.ANSWER_MS + 1).isEmpty())
        assertTrue(setup.answer(run.id, 70_000))
        assertFalse(setup.answer(run.id, 70_000))
        assertNull(run(setup, "button:pair")["confirm"])
        rejects { setup.confirm(run.id, "", "", "Yes", 0) }
        // A question nobody answers times out the run.
        assertTrue(setup.confirm(run.id, "Pair?", "", "Pair", 80_000))
        assertEquals(1, setup.expire(80_000 + PluginSetup.CONFIRM_MS).size)
        assertNull(run(setup, "button:pair")["confirm"])
    }

    @Test fun choicesBelongToDeclaredSettingsAndFallBackToTheirIds() {
        val setup = PluginSetup(PluginManifest(manifest()))
        setup.setChoices("device", arrayOf("lamp-1", "lamp-2"), arrayOf("Kitchen", null))
        @Suppress("UNCHECKED_CAST")
        val choices = (setup.snapshot()["choices"] as Map<String, List<Map<String, String>>>)["device"]
        assertEquals(listOf(mapOf("id" to "lamp-1", "label" to "Kitchen"), mapOf("id" to "lamp-2", "label" to "lamp-2")), choices)
        rejects { setup.setChoices("host", arrayOf("a"), null) }
        rejects { setup.setChoices("device", arrayOf("a", "a"), null) }
        rejects { setup.setChoices("device", arrayOf(""), null) }
        rejects { setup.setChoices("device", arrayOf("a"), arrayOf("A", "B")) }
        rejects { setup.setChoices("device", Array(201) { "id$it" }, null) }
        rejects { setup.setChoices("device", arrayOf("a"), arrayOf("x".repeat(81))) }
    }

    @Suppress("UNCHECKED_CAST")
    private fun run(setup: PluginSetup, target: String) = (setup.snapshot()["runs"] as Map<String, Map<String, Any?>>).getValue(target)
}
