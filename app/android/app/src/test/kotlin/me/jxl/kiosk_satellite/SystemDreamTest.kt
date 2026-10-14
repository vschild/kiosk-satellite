package me.jxl.kiosk_satellite

import android.app.Application
import android.content.Intent
import android.provider.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 33, 34], manifest = Config.NONE, application = Application::class)
class SystemDreamTest {
    private val context: Application
        get() = RuntimeEnvironment.getApplication()

    @Test
    fun olderAndroidTriesSomnambulatorBeforeReflection() {
        assertEquals(
            listOf("somnambulator", "reflection", "component"),
            SystemDream.attemptOrder(33),
        )
    }

    @Test
    fun android14TriesThePrivilegedCallBeforeTheNoOpLauncher() {
        assertEquals(
            listOf("reflection", "component", "somnambulator"),
            SystemDream.attemptOrder(34),
        )
    }

    @Test
    fun outcomeNamesTheAttemptThatAcceptedTheLaunch() {
        assertEquals(false, SystemDream.outcome(null)["ok"])
        assertEquals("unavailable", SystemDream.outcome(null)["code"])
        assertEquals("somnambulator", SystemDream.outcome("somnambulator")["method"])
        assertEquals(true, SystemDream.outcome("reflection")["ok"])
    }

    @Test
    fun anExplicitOffIsTheOnlyDisabledReading() {
        assertTrue(SystemDream.explicitlyDisabled("0"))
        assertFalse(SystemDream.explicitlyDisabled("1"))
        assertFalse(SystemDream.explicitlyDisabled(null))
    }

    @Test
    fun somnambulatorIntentTargetsSystemUi() {
        val intent = SystemDream.somnambulatorIntent()
        assertEquals(Intent.ACTION_MAIN, intent.action)
        assertEquals(SystemDream.SOMNAMBULATOR_PACKAGE, intent.component!!.packageName)
        assertEquals(SystemDream.SOMNAMBULATOR_CLASS, intent.component!!.className)
        assertTrue(intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }

    @Test
    fun settingsIntentUsesThePublicDreamAction() {
        assertEquals(Settings.ACTION_DREAM_SETTINGS, SystemDream.settingsIntent().action)
    }

    @Test
    fun statusReadsTheSecureScreensaverSwitch() {
        val resolver = context.contentResolver
        Settings.Secure.putString(resolver, Settings.Secure.SCREENSAVER_ENABLED, "0")
        Settings.Secure.putString(
            resolver,
            Settings.Secure.SCREENSAVER_COMPONENTS,
            "com.android.deskclock/.Screensaver",
        )
        val off = SystemDream.readStatus(context)
        assertEquals(false, off["enabled"])
        assertEquals("com.android.deskclock/.Screensaver", off["component"])

        Settings.Secure.putString(resolver, Settings.Secure.SCREENSAVER_ENABLED, null)
        assertEquals(true, SystemDream.readStatus(context)["enabled"])
    }

    @Test
    fun aDisabledScreensaverDoesNotLaunch() {
        Settings.Secure.putString(
            context.contentResolver,
            Settings.Secure.SCREENSAVER_ENABLED,
            "0",
        )
        val started = SystemDream.start(context)
        assertEquals(false, started["ok"])
        assertEquals("disabled", started["code"])
        assertFalse(SystemDream.holding)
    }

    @Test
    fun dreamingBroadcastActionsMatchThePlatform() {
        assertEquals("android.intent.action.DREAMING_STARTED", SystemDream.ACTION_DREAMING_STARTED)
        assertEquals("android.intent.action.DREAMING_STOPPED", SystemDream.ACTION_DREAMING_STOPPED)
        assertNull(SystemDream.isDreaming(context))
    }
}
