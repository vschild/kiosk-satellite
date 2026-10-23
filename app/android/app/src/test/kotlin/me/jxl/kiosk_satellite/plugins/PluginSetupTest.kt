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
        // Plugin choices belong to text settings and text row fields.
        fun device(change: (JSONObject) -> Unit) = manifest { change(it.getJSONArray("settings").getJSONObject(2)) }
        rejects { PluginManifest(device { it.put("choices", "static") }) }
        rejects { PluginManifest(device { it.put("type", "select").put("options", JSONArray().put("a")).put("default", "a") }) }
        rejects { PluginManifest(manifest { it.getJSONArray("settings").getJSONObject(1).put("choices", "plugin") }) }
        rejects { PluginManifest(panels { it.getJSONArray("fields").getJSONObject(1).put("choices", "static") }) }
        rejects { PluginManifest(panels { it.getJSONArray("fields").getJSONObject(2).put("choices", "plugin") }) }
        rejects { PluginManifest(panels { it.getJSONArray("fields").getJSONObject(2).getJSONArray("fields").getJSONObject(0).put("type", "icon") }) }
        // A choices setting or row field may say what its picker shows before the plugin lists any.
        PluginManifest(device { it.put("emptyText", "Add a bridge first.") })
        PluginManifest(panels { it.getJSONArray("fields").getJSONObject(1).put("emptyText", "Add a computer first.") })
        rejects { PluginManifest(manifest { it.getJSONArray("settings").getJSONObject(1).put("emptyText", "No choices") }) }
        rejects { PluginManifest(device { it.put("emptyText", "x".repeat(201)) }) }
    }

    /** A list of panels, each with a sensor and a nested list of tiles that pick a sensor too. */
    private fun panels(change: (JSONObject) -> Unit = {}) = manifest { manifest ->
        manifest.getJSONArray("settings").put(JSONObject("""{
          "key":"panels","type":"list","title":"Panels","default":[],
          "fields":[
            {"key":"label","type":"string","title":"Label"},
            {"key":"sensor","type":"string","title":"Sensor","choices":"plugin","required":true},
            {"key":"tiles","type":"list","title":"Tiles","fields":[
              {"key":"sensor","type":"string","title":"Sensor","choices":"plugin"}
            ]}
          ]
        }""").also(change))
    }

    @Test fun rowFieldsTakeChoicesByTheirPath() {
        val value = PluginManifest(panels())
        assertEquals(setOf("device", "panels.sensor", "panels.tiles.sensor"), value.choiceKeys)
        // A refresh follows the list that holds the field. The fields of a row have no say.
        val empty = JSONObject(value.config(JSONObject()))
        assertTrue(value.choicesVisible("panels.tiles.sensor", empty))
        assertFalse(value.choicesVisible("panels.label", empty))
        assertFalse(value.choicesVisible("panels", empty))
        assertFalse(value.choicesVisible("device", empty))
        assertTrue(value.choicesVisible("device", JSONObject(value.config(JSONObject().put("host", "bridge.local")))))
        val hidden = PluginManifest(panels { it.put("visibleWhen", JSONObject().put("key", "host").put("notEmpty", true)) })
        assertFalse(hidden.choicesVisible("panels.sensor", JSONObject(hidden.config(JSONObject()))))
        // A required field with choices still needs a value.
        rejects { value.config(JSONObject().put("panels", JSONArray().put(JSONObject().put("sensor", "")))) }
        assertEquals("cpu", (value.config(JSONObject().put("panels", JSONArray().put(JSONObject().put("sensor", "cpu"))))["panels"] as List<*>)
            .let { (it[0] as Map<*, *>)["sensor"] })

        val setup = PluginSetup(value)
        setup.setChoices("panels.tiles.sensor", arrayOf("cpu"), arrayOf("CPU"))
        assertEquals(listOf(mapOf("id" to "cpu", "label" to "CPU")), choices(setup)["panels.tiles.sensor"])
        rejects { setup.setChoices("panels", arrayOf("a"), null) }
        rejects { setup.setChoices("panels.label", arrayOf("a"), null) }
        rejects { setup.setChoices("tiles.sensor", arrayOf("a"), null) }
    }

    @Test fun choicesTurnOffAndBackOn() {
        val setup = PluginSetup(PluginManifest(panels()))
        assertEquals(emptyList<String>(), setup.snapshot()["choicesOff"])
        setup.setChoicesEnabled("panels.sensor", false)
        setup.setChoicesEnabled("device", false)
        assertFalse(setup.choicesEnabled("panels.sensor"))
        assertEquals(listOf("panels.sensor", "device"), setup.snapshot()["choicesOff"])
        setup.setChoicesEnabled("panels.sensor", true)
        assertTrue(setup.choicesEnabled("panels.sensor"))
        assertEquals(listOf("device"), setup.snapshot()["choicesOff"])
        rejects { setup.setChoicesEnabled("host", false) }
        rejects { setup.setChoicesEnabled("panels.label", false) }
    }

    @Test fun richChoicesCarryGroupsAndDetails() {
        val setup = PluginSetup(PluginManifest(panels()))
        setup.setChoices("panels.sensor", listOf(
            mapOf("id" to "cpu.temp", "label" to "CPU temperature", "group" to "CPU", "detail" to "54 °C"),
            mapOf("id" to "gpu.temp", "label" to " ", "group" to "", "detail" to null),
            mapOf("id" to "fan", "icon" to "fan"),
            mapOf("id" to "pump", "icon" to "mdi:water-pump"),
            mapOf("id" to "fps", "value" to "144 FPS", "category" to "Other"),
        ))
        assertEquals(listOf(
            mapOf("id" to "cpu.temp", "label" to "CPU temperature", "group" to "CPU", "detail" to "54 °C"),
            mapOf("id" to "gpu.temp", "label" to "gpu.temp"),
            mapOf("id" to "fan", "label" to "fan", "icon" to "mdi:fan"),
            mapOf("id" to "pump", "label" to "pump", "icon" to "mdi:water-pump"),
            mapOf("id" to "fps", "label" to "fps", "value" to "144 FPS", "category" to "Other"),
        ), choices(setup)["panels.sensor"])
        // The longer limits apply to this form only.
        setup.setChoices("device", (0 until 2000).map { mapOf("id" to "id$it", "label" to "x".repeat(120), "group" to "g".repeat(120), "detail" to "d".repeat(120)) })
        assertEquals(2000, choices(setup).getValue("device").size)
        rejects { setup.setChoices("device", (0..2000).map { mapOf("id" to "id$it") }) }
        rejects { setup.setChoices("device", Array(201) { "id$it" }, null) }
        for (field in listOf("label", "group", "detail")) {
            rejects { setup.setChoices("device", listOf(mapOf("id" to "a", field to "x".repeat(121)))) }
            rejects { setup.setChoices("device", listOf(mapOf("id" to "a", field to 1))) }
        }
        rejects { setup.setChoices("device", listOf(mapOf("label" to "No id"))) }
        rejects { setup.setChoices("device", listOf(mapOf("id" to "x".repeat(513)))) }
        rejects { setup.setChoices("device", listOf(mapOf("id" to "a"), mapOf("id" to "a"))) }
        rejects { setup.setChoices("device", listOf(mapOf("id" to "a", "icon" to "<svg>"))) }
        rejects { setup.setChoices("device", listOf(mapOf("id" to "a", "color" to "red"))) }
        for (field in listOf("value", "category")) {
            rejects { setup.setChoices("device", listOf(mapOf("id" to "a", field to "x".repeat(41)))) }
        }
        rejects { setup.setChoices("device", listOf(null)) }
        rejects { setup.setChoices("host", listOf(mapOf("id" to "a"))) }
        // A refused list leaves the last one in place.
        assertEquals(2000, choices(setup).getValue("device").size)
    }

    @Test fun anUnchangedListIsSentOnce() {
        val setup = PluginSetup(PluginManifest(panels()))
        val sent = mutableMapOf<String, Long>()
        setup.setChoices("device", arrayOf("a"), null)
        setup.setChoices("panels.sensor", arrayOf("b"), null)
        assertEquals(setOf("device", "panels.sensor"), choices(setup, sent).keys)
        setup.start("button:test", "remote", 0)
        // A run update carries the revisions alone.
        val update = setup.snapshot(sent)
        assertTrue((update["choices"] as Map<*, *>).isEmpty())
        assertEquals(setOf("device", "panels.sensor"), (update["choiceRevisions"] as Map<*, *>).keys)
        val before = (update["choiceRevisions"] as Map<*, *>)["device"] as Long
        setup.setChoices("device", arrayOf("a", "c"), null)
        assertEquals(setOf("device"), choices(setup, sent).keys)
        assertTrue((setup.snapshot(sent)["choiceRevisions"] as Map<*, *>)["device"] as Long > before)
    }

    @Test fun theLatestListOutlivesTheSession() {
        val store = java.nio.file.Files.createTempDirectory("choices").toFile()
        try {
            val first = PluginSetup(PluginManifest(panels()), store)
            assertFalse(first.hasChoices())
            first.setChoices("device", arrayOf("lamp-1"), arrayOf("Kitchen"))
            first.setChoices("panels.tiles.sensor", listOf(mapOf("id" to "cpu", "label" to "CPU", "group" to "Board", "detail" to "40 °C")))
            first.setChoices("device", arrayOf("lamp-2"), arrayOf("Hallway"))
            val revision = first.listed("device")!!.revision
            // A new session starts on the kept lists, with the same revisions.
            val second = PluginSetup(PluginManifest(panels()), store)
            assertTrue(second.hasChoices())
            assertEquals(choices(first), choices(second))
            assertEquals(revision, second.listed("device")!!.revision)
            // A new list replaces the kept one, under a newer revision.
            second.setChoices("device", arrayOf("lamp-3"), null)
            assertTrue(second.listed("device")!!.revision > revision)
            assertEquals(listOf(mapOf("id" to "lamp-3", "label" to "lamp-3")), choices(PluginSetup(PluginManifest(panels()), store))["device"])
            // An update that drops a key forgets its list. A damaged file is dropped too.
            java.io.File(store, "panels.sensor.json").writeText("{")
            val updated = PluginSetup(PluginManifest(manifest()), store)
            assertEquals(setOf("device"), choices(updated).keys)
            assertEquals(setOf("device.json"), store.list()!!.toSet())
        } finally {
            store.deleteRecursively()
        }
    }

    @Test fun manifestsWithoutTheNewKeysAreUnchanged() {
        val value = PluginManifest(manifest { it.remove("buttons"); it.remove("groups"); it.getJSONArray("settings").getJSONObject(2).remove("choices") })
        assertEquals(0, value.buttons.length())
        assertTrue(value.choiceKeys.isEmpty())
    }

    @Test fun updatesDropSettingsAndRowFieldsTheyNoLongerDeclare() {
        val list = """{"key":"panels","type":"list","title":"Panels","default":[],"fields":[{"key":"sensor","type":"string","title":"Sensor"},
          {"key":"lines","type":"list","title":"Lines","fields":[{"key":"sensor","type":"string","title":"Sensor"}]}]}"""
        val value = PluginManifest(manifest { it.getJSONArray("settings").put(JSONObject(list)) })
        val line = JSONObject().put("sensor", "fan").put("color", "#FFFFFF")
        val saved = JSONObject().put("host", "bridge.local").put("removed", true)
            .put("panels", JSONArray().put(JSONObject().put("sensor", "cpu").put("chart", "gpu").put("lines", JSONArray().put(line))))
        rejects { value.config(saved) }
        val kept = value.config(value.kept(saved))
        assertEquals("bridge.local", kept["host"])
        val panel = (kept["panels"] as List<*>)[0] as Map<*, *>
        assertEquals("cpu", panel["sensor"])
        assertFalse(panel.containsKey("chart"))
        assertEquals(mapOf("sensor" to "fan"), (panel["lines"] as List<*>)[0])
        // A changed type still fails.
        rejects { value.config(value.kept(JSONObject().put("timeout", "slow"))) }
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
    private fun choices(setup: PluginSetup, sent: MutableMap<String, Long>? = null) = setup.snapshot(sent)["choices"] as Map<String, List<Map<String, String>>>

    @Suppress("UNCHECKED_CAST")
    private fun run(setup: PluginSetup, target: String) = (setup.snapshot()["runs"] as Map<String, Map<String, Any?>>).getValue(target)
}
