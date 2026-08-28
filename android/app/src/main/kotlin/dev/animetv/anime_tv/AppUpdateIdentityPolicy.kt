package dev.animetv.anime_tv

internal enum class AppUpdateIdentityIssue {
    VERSION_DOWNGRADE,
    SAME_BUILD,
    SIGNER_MISMATCH,
}

/** Pure identity gate used before Android's package installer is launched. */
internal fun appUpdateIdentityIssues(
    archiveVersionCode: Long,
    archiveVersionName: String,
    installedVersionCode: Long,
    installedVersionName: String,
    signerMatches: Boolean,
): Set<AppUpdateIdentityIssue> {
    val issues = mutableSetOf<AppUpdateIdentityIssue>()
    if (archiveVersionCode < installedVersionCode) {
        issues += AppUpdateIdentityIssue.VERSION_DOWNGRADE
    } else if (
        archiveVersionCode == installedVersionCode &&
        archiveVersionName == installedVersionName
    ) {
        issues += AppUpdateIdentityIssue.SAME_BUILD
    }
    if (!signerMatches) {
        issues += AppUpdateIdentityIssue.SIGNER_MISMATCH
    }
    return issues
}
