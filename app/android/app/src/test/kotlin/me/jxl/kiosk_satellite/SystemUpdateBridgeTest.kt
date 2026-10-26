package me.jxl.kiosk_satellite

import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.os.Binder
import android.os.Looper
import android.os.Parcel
import android.view.Display
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDisplay

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30], manifest = Config.NONE, application = Application::class)
class SystemUpdateBridgeTest {
    private lateinit var context: Application

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
    }

    @Test
    fun detectsTheUpdaterFromItsProperty() {
        assertEquals(SystemUpdater.BISCUIT, SystemUpdater.detect(props("ro.biscuit.ota" to "1")))
        assertEquals(SystemUpdater.ECHO, SystemUpdater.detect(props("ro.echo.ota" to "1")))
        assertNull(SystemUpdater.detect(props()))
        assertNull(SystemUpdater.detect(props("ro.echo.ota" to "0")))
        // Dot releases 2026.10.7 to 2026.10.9 set both. EchoService would
        // install into one slot only there, so BiscuitService wins.
        assertEquals(
            SystemUpdater.BISCUIT,
            SystemUpdater.detect(props("ro.echo.ota" to "1", "ro.biscuit.ota" to "1")),
        )
        // The Dot-only features do not make an updater.
        assertNull(SystemUpdater.detect(props("ro.biscuit.pryon" to "1")))
    }

    @Test
    fun echoServiceAnswersWithAScreen() = answersOnEveryDevice(headless = false)

    @Test
    fun echoServiceAnswersWithoutAScreen() = answersOnEveryDevice(headless = true)

    @Test
    fun biscuitServiceKeepsItsNames() {
        val service = FakeUpdater(SystemUpdater.BISCUIT)
        val bridge = Bridge(SystemUpdater.BISCUIT)
        assertEquals("biscuit", bridge.call("updater"))
        assertEquals(STATUS, bridge.call("status"))
        assertEquals(listOf(8), service.codes)
        assertEquals(listOf(SystemUpdater.BISCUIT.descriptor), service.descriptors)
    }

    @Test
    fun withoutAnUpdaterNothingIsCalled() {
        val bridge = Bridge(null)
        assertNull(bridge.call("updater"))
        assertNull(bridge.call("status"))
    }

    private fun answersOnEveryDevice(headless: Boolean) {
        setScreen(headless)
        assertEquals(headless, Headless.active(context))
        val service = FakeUpdater(SystemUpdater.ECHO)
        val bridge = Bridge(SystemUpdater.ECHO)
        assertEquals("echo", bridge.call("updater"))
        assertEquals(STATUS, bridge.call("status"))
        assertEquals(true, bridge.call("check"))
        assertEquals(true, bridge.call("install"))
        assertEquals(listOf(8, 9, 10), service.codes)
        assertEquals(List(3) { "me.jxl.echo.service.IEchoService" }, service.descriptors)
    }

    private fun props(vararg set: Pair<String, String>): (String) -> String =
        { name -> set.toMap()[name] ?: "" }

    // A 1x1 stub display is what a device without a panel reports.
    private fun setScreen(headless: Boolean) {
        val display = ShadowDisplay.getDefaultDisplay()
        val shadow = shadowOf(display)
        shadow.setRealWidth(if (headless) 1 else 1080)
        shadow.setRealHeight(if (headless) 1 else 1920)
        Headless::class.java.getDeclaredField("cached").apply { isAccessible = true }
            .set(Headless, null)
        assertEquals(Display.DEFAULT_DISPLAY, display.displayId)
    }

    /** The ROM's updater, answering the bind the bridge makes. */
    private inner class FakeUpdater(updater: SystemUpdater) : Binder() {
        val codes = mutableListOf<Int>()
        val descriptors = mutableListOf<String>()

        init {
            shadowOf(context).setComponentNameAndServiceForBindServiceForIntent(
                Intent(updater.descriptor).setPackage(updater.packageName),
                ComponentName(updater.packageName, "${updater.packageName}.Service"),
                this,
            )
        }

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            codes += code
            for (d in SystemUpdater.entries) {
                data.setDataPosition(0)
                if (runCatching { data.enforceInterface(d.descriptor) }.isSuccess) descriptors += d.descriptor
            }
            reply!!.writeNoException()
            if (code == 8) reply.writeString(STATUS) else reply.writeInt(1)
            return true
        }
    }

    /** The bridge behind a messenger that plays Dart's side of the channel. */
    private inner class Bridge(updater: SystemUpdater?) : BinaryMessenger {
        private var handler: BinaryMessenger.BinaryMessageHandler? = null

        init {
            SystemUpdateBridge(context, this, updater)
        }

        fun call(method: String): Any? {
            var answer: ByteBuffer? = null
            var answered = false
            val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, null))
                .apply { order(ByteOrder.nativeOrder()); rewind() }
            handler!!.onMessage(message) {
                answer = it
                answered = true
            }
            val deadline = System.currentTimeMillis() + 5000
            while (!answered && System.currentTimeMillis() < deadline) {
                shadowOf(Looper.getMainLooper()).idle()
                Thread.sleep(5)
            }
            assertTrue("$method did not answer", answered)
            val reply = answer!!.apply { order(ByteOrder.nativeOrder()); rewind() }
            return StandardMethodCodec.INSTANCE.decodeEnvelope(reply)
        }

        override fun send(channel: String, message: ByteBuffer?) {}

        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}

        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            this.handler = handler
        }
    }

    private companion object {
        const val STATUS = """{"current":"2026.10.20","state":"idle"}"""
    }
}
