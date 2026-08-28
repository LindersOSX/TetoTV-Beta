package dev.animetv.anime_tv

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdateIdentityPolicyTest {
    @Test
    fun `beta 2 0 22 can replace 2 0 21 at equal code with the same signer`() {
        val issues = appUpdateIdentityIssues(
            archiveVersionCode = 410001,
            archiveVersionName = "2.0.22",
            installedVersionCode = 410001,
            installedVersionName = "2.0.21",
            signerMatches = true,
        )

        assertTrue(issues.isEmpty())
    }

    @Test
    fun `equal code rejects only the same build or another signer`() {
        val sameVersion = appUpdateIdentityIssues(
            archiveVersionCode = 410001,
            archiveVersionName = "2.0.21",
            installedVersionCode = 410001,
            installedVersionName = "2.0.21",
            signerMatches = true,
        )
        val wrongSigner = appUpdateIdentityIssues(
            archiveVersionCode = 410001,
            archiveVersionName = "2.0.22",
            installedVersionCode = 410001,
            installedVersionName = "2.0.21",
            signerMatches = false,
        )

        assertTrue(AppUpdateIdentityIssue.SAME_BUILD in sameVersion)
        assertFalse(AppUpdateIdentityIssue.SIGNER_MISMATCH in sameVersion)
        assertTrue(AppUpdateIdentityIssue.SIGNER_MISMATCH in wrongSigner)
    }

    @Test
    fun `lower code is always reported as a downgrade`() {
        val issues = appUpdateIdentityIssues(
            archiveVersionCode = 410007,
            archiveVersionName = "2.0.30",
            installedVersionCode = 410008,
            installedVersionName = "2.0.31",
            signerMatches = true,
        )

        assertTrue(AppUpdateIdentityIssue.VERSION_DOWNGRADE in issues)
        assertFalse(AppUpdateIdentityIssue.SAME_BUILD in issues)
        assertFalse(AppUpdateIdentityIssue.SIGNER_MISMATCH in issues)
    }
}
