package dev.animetv.anime_tv.aniyomi

import java.net.InetAddress
import org.junit.Assert.*
import org.junit.Test

class AniyomiPolicyTest {
    @Test fun `worker concurrency stays single process safe before Android 10`() {
        assertEquals(1, AniyomiNativeHost.workerCapacity(26))
        assertEquals(1, AniyomiNativeHost.workerCapacity(28))
        assertEquals(3, AniyomiNativeHost.workerCapacity(29))
        assertEquals(3, AniyomiNativeHost.workerCapacity(35))
    }

    @Test fun `developer permission is checked after issuing every lease`() {
        var enabled = true
        val policy = AniyomiLease { enabled }
        val initial = policy.issue()
        policy.check(initial)
        enabled = false
        rejects { policy.check(initial) }
        rejects { policy.issue() }
        enabled = true
        policy.revoke()
        rejects { policy.check(initial) }
        policy.check(policy.issue())
    }

    @Test fun `unsupported API generations are not silently accepted`() {
        assertEquals("14", AniyomiPolicy.apiVersion("anime", "14.123"))
        assertEquals("16", AniyomiPolicy.apiVersion("anime", "16.0.123"))
        assertEquals("16", AniyomiPolicy.apiVersion("anime", "1.2.3", "16"))
        assertEquals("14", AniyomiPolicy.apiVersion("anime", "1.2.3", "14.0"))
        assertEquals("1.4", AniyomiPolicy.apiVersion("manga", "1.4.99"))
        assertEquals("1.5", AniyomiPolicy.apiVersion("manga", "1.5.1"))
        for (version in listOf("12.1", "17.1", "14notanapi")) {
            rejects { AniyomiPolicy.apiVersion("anime", version) }
        }
        for (declared in listOf("13", "17", "16beta", "16.0.1")) {
            rejects { AniyomiPolicy.apiVersion("anime", "14.1", declared) }
        }
        rejects { AniyomiPolicy.apiVersion("manga", "1.6.1") }
    }

    @Test fun `identity requires actual full digests and valid package version`() {
        assertTrue(AniyomiPolicy.validIdentity("eu.example.extension.en.fixture", 4, "a".repeat(64), "b".repeat(64)))
        assertFalse(AniyomiPolicy.validIdentity("../../fixture", 4, "a".repeat(64), "b".repeat(64)))
        assertFalse(AniyomiPolicy.validIdentity("eu.example.fixture", 0, "a".repeat(64), "b".repeat(64)))
        assertFalse(AniyomiPolicy.validIdentity("eu.example.fixture", 4, "catalog-asserted", "b".repeat(64)))
    }

    @Test fun `broker URLs reject local endpoints credentials and non HTTPS capabilities`() {
        assertEquals("example.com", AniyomiPolicy.publicHttps("https://example.com/path?q=hello").host)
        for (url in listOf(
            "http://example.com", "file:///data/user/0/private", "content://package/document/1", "intent://player",
            "https://user:password@example.com/path", "https://example.com:8443", "https://localhost/",
            "https://host.local/path", "https://metadata.google.internal/", "https://127.0.0.1/",
            "https://169.254.169.254/", "https://10.0.0.1/", "https://2130706433/", "https://example.com/#fragment",
            "https://example.com/\r\nHost:evil", "https://example.com\\@127.0.0.1/",
        )) rejects { AniyomiPolicy.publicHttps(url) }
    }

    @Test fun `DNS policy blocks reserved v4 and v6 including mixed answer hazards`() {
        for (address in listOf("0.0.0.0", "127.0.0.1", "10.3.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254",
            "100.64.0.1", "100.127.255.254", "198.18.0.1", "192.0.2.1", "198.51.100.1", "203.0.113.1", "224.0.0.1",
            "::1", "fc00::1", "fe80::1", "2001:db8::1", "2002:7f00:1::1", "64:ff9b::7f00:1")) {
            assertFalse(address, AniyomiPolicy.publicAddress(InetAddress.getByName(address)))
        }
        for (address in listOf("1.1.1.1", "8.8.8.8", "2606:4700:4700::1111")) {
            assertTrue(address, AniyomiPolicy.publicAddress(InetAddress.getByName(address)))
        }
        val mixed = listOf("1.1.1.1", "127.0.0.1").map(InetAddress::getByName)
        assertFalse(mixed.all(AniyomiPolicy::publicAddress))
    }

    @Test fun `payload size is bytes not UTF16 characters`() {
        assertEquals("abc", AniyomiPolicy.boundedText("abc", 3))
        rejects { AniyomiPolicy.boundedText("éé", 3) }
        rejects { AniyomiPolicy.boundedText("a\u0000b", 3) }
    }

    @Test fun `broker keeps Binder metadata small independently of file descriptor body budget`() {
        assertEquals(4 * 1024 * 1024, AniyomiPolicy.MAX_HTTP_BYTES)
        assertEquals(16 * 1024, AniyomiPolicy.MAX_HTTP_REPLY_BYTES)
        assertTrue(AniyomiPolicy.MAX_HTTP_REPLY_BYTES * 2 + 1024 < 64 * 1024)
        assertEquals(16, AniyomiPolicy.MAX_HTTP_REQUESTS)
        assertEquals(30_000L, AniyomiPolicy.DEADLINE_MS)
    }

    @Test fun `JSON nesting is bounded before the Android recursive parser`() {
        val valid = "{\"text\":\"escaped \\\" brackets [[[[ and apostrophe '\",\"items\":[true,false,null,-1.2e3]}"
        assertEquals(valid, AniyomiPolicy.boundedJsonText(valid, 1024))
        assertEquals("[".repeat(16) + "]".repeat(16), AniyomiPolicy.boundedJsonText("[".repeat(16) + "]".repeat(16), 100))
        rejects { AniyomiPolicy.boundedJsonText("[".repeat(17) + "]".repeat(17), 100) }
        rejects { AniyomiPolicy.boundedJsonText("{'single': 'quote'}", 100) }
        rejects { AniyomiPolicy.boundedJsonText("{ /* \" */ \"x\": [] }", 100) }
        rejects { AniyomiPolicy.boundedJsonText("{\"unterminated\":\"text}", 100) }
    }

    private fun rejects(block: () -> Unit) {
        try { block(); fail("Expected rejection") } catch (_: IllegalArgumentException) {} catch (_: IllegalStateException) {}
    }
}
