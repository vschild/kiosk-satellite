package me.jxl.kiosk_satellite

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WebViewFreezeTest {
    private fun matches(url: String?, prefix: String) =
        WebViewFreeze.matchesPrefix(url, prefix)

    @Test
    fun originMatchesItsOwnPages() {
        assertTrue(matches("https://ha.example.net/lovelace/0", "https://ha.example.net"))
        assertTrue(matches("https://ha.example.net", "https://ha.example.net"))
        assertTrue(matches("https://ha.example.net?x=1", "https://ha.example.net"))
        assertTrue(matches("https://ha.example.net#top", "https://ha.example.net"))
        assertTrue(matches("http://127.0.0.1:8124/lovelace", "http://127.0.0.1:8124"))
    }

    @Test
    fun anotherPortOnTheSameHostIsAnotherOrigin() {
        assertFalse(matches("https://ha.example.net:8095/#/discover", "https://ha.example.net"))
        assertFalse(matches("http://127.0.0.1:81245/", "http://127.0.0.1:8124"))
    }

    @Test
    fun aLongerHostIsAnotherOrigin() {
        assertFalse(matches("https://ha.example.network/", "https://ha.example.net"))
    }

    @Test
    fun aBareSchemeStillMatchesEveryPage() {
        assertTrue(matches("https://ha.example.net:8095/", "http"))
        assertTrue(matches("http://192.168.1.10:8123/", "http"))
        assertFalse(matches("file:///android_asset/page.html", "http"))
    }

    @Test
    fun noUrlNeverMatches() {
        assertFalse(matches(null, "http"))
    }
}
