package com.onda.seaglass.update

import org.json.JSONArray
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The updater takes only windows-v* releases' own installer, with GitHub's checksum. */
class AppUpdaterTest {
    private fun release(tag: String, asset: String = AppUpdater.ASSET, url: String? = null, digest: String? = "sha256:" + "ab".repeat(32), draft: Boolean = false) =
        """{"tag_name":"$tag","draft":$draft,"prerelease":false,"body":"notes $tag","assets":[{"name":"$asset","size":1234,
        "browser_download_url":"${url ?: "https://github.com/Foglio24/onda/releases/download/$tag/$asset"}"${digest?.let { ""","digest":"$it"""" } ?: ""}}]}"""

    @Test
    fun comparesVersionsAsNumbers() {
        assertTrue(AppUpdater.compare("1.2.10", "1.2.9") > 0)
        assertTrue(AppUpdater.compare("1.10.0", "1.9.9") > 0)
        assertEquals(0, AppUpdater.compare("1.0.0", "1.0.0"))
        assertTrue(AppUpdater.compare("0.9.0", "1.0.0") < 0)
    }

    @Test
    fun picksTheNewestWindowsRelease() {
        val releases = JSONArray("[" + listOf(
            release("v1.36.12"),
            release("android-v0.9.0"),
            release("windows-v1.0.0"),
            release("windows-v1.2.0"),
            release("windows-v1.10.0", draft = true),
            release("windows-v1.1.0"),
        ).joinToString(",") + "]")
        val chosen = AppUpdater.parse(releases)
        assertEquals("1.2.0", chosen?.version)
        assertEquals("ab".repeat(32), chosen?.sha256)
        assertEquals(1234, chosen?.size)
    }

    @Test
    fun refusesWhatIsntThisRepositorysOwnInstaller() {
        assertNull(AppUpdater.parse(JSONArray("[${release("windows-v2.0.0", url = "https://evil.example/Seaglass-Setup.exe")}]")), "another host")
        assertNull(AppUpdater.parse(JSONArray("[${release("windows-v2.0.0", url = "https://github.com/Foglio24/onda/releases/download/windows-v9.9.9/Seaglass-Setup.exe")}]")), "another release's asset")
        assertNull(AppUpdater.parse(JSONArray("[${release("windows-v2.0.0", digest = null)}]")), "no checksum to compare with")
        assertNull(AppUpdater.parse(JSONArray("[${release("windows-v2.0.0", asset = "Seaglass-windows.zip")}]")), "not the installer")
        assertNull(AppUpdater.parse(JSONArray("[${release("windows-vnext")}]")), "not a version")
    }

    @Test
    fun hashesWhileCopyingSoReadyFollowsTheFullBar() {
        val bytes = ByteArray(300_000) { (it * 31).toByte() }
        val out = java.io.ByteArrayOutputStream()
        val seen = mutableListOf<Long>()
        val hash = AppUpdater.copyHashing(java.io.ByteArrayInputStream(bytes), out) { seen += it }
        val expected = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        assertEquals(expected, hash)
        assertTrue(bytes.contentEquals(out.toByteArray()))
        assertEquals(bytes.size.toLong(), seen.last())
        assertEquals(seen.sorted(), seen)
    }
}
