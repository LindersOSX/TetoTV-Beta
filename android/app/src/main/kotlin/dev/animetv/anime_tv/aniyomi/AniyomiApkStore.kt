package dev.animetv.anime_tv.aniyomi

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.android.apksig.ApkVerifier
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import org.json.JSONArray
import org.json.JSONObject

/** Trusted host only. No class loading, application contexts or writable files cross into the worker. */
internal class AniyomiApkStore(private val context: Context) {
    private val root = File(context.codeCacheDir, "aniyomi-verified").apply { mkdirs() }.canonicalFile
    private val preferences = context.getSharedPreferences("aniyomi_native_approvals_v1", Context.MODE_PRIVATE)
    private val inspections = linkedMapOf<String, JSONObject>()

    @Synchronized fun inspect(path: String, kind: String): JSONObject {
        check(Build.VERSION.SDK_INT >= 26) { "android_26_required" }
        val source = File(path).canonicalFile
        require(listOf(context.cacheDir.canonicalFile, context.filesDir.canonicalFile).any {
            source.toPath().startsWith(it.toPath()) && source != it
        } && source.isFile && source.length() in 1..AniyomiPolicy.MAX_APK_BYTES.toLong()) { "invalid_import_file" }
        require(inspections.size < 8 && preferences.all.size < 32) { "extension_limit_reached" }
        val temporary = File.createTempFile("inspect-", ".apk", root)
        try {
            FileOutputStream(temporary).use { output ->
                check(temporary.setReadOnly()) { "readonly_apk_required" }
                source.inputStream().use { input ->
                    val buffer = ByteArray(32 * 1024)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= AniyomiPolicy.MAX_APK_BYTES) { "apk_too_large" }
                        output.write(buffer, 0, count)
                    }
                }
                output.fd.sync()
            }
            val identity = verify(temporary, kind)
            val snapshot = File(root, identity.getString("apkSha256") + ".apk")
            if (snapshot.exists()) {
                require(sha256(snapshot) == identity.getString("apkSha256")) { "snapshot_integrity_failed" }
            } else {
                check(temporary.renameTo(snapshot)) { "snapshot_storage_failed" }
            }
            val inspectionId = UUID.randomUUID().toString()
            inspections[inspectionId] = identity
            return JSONObject(identity.toString()).put("inspectionId", inspectionId)
        } finally {
            // Only this operation's own temporary file is removed; approved snapshots are retained.
            if (temporary.exists()) temporary.delete()
        }
    }

    @Synchronized fun approve(inspectionId: String, checkAccess: () -> Unit): JSONObject {
        val approved = inspections.remove(inspectionId) ?: throw IllegalArgumentException("inspection_expired")
        val current = verify(snapshot(approved), approved.getString("kind"))
        require(sameIdentity(approved, current)) { "identity_changed" }
        val extensionId = current.getString("extensionId")
        val previous = preferences.getString(extensionId, null)?.let(::JSONObject)
        if (previous != null) {
            require(previous.getString("certificateSha256") == current.getString("certificateSha256")) {
                "signer_change_requires_revocation"
            }
            require(current.getLong("versionCode") >= previous.getLong("versionCode")) { "version_downgrade" }
        }
        // Shares the revoke monitor: either this commit precedes its clear, or revocation
        // removes the inspection token before approve can start. Recheck generation here too.
        checkAccess()
        check(preferences.edit().putString(extensionId, current.toString()).commit()) { "approval_storage_failed" }
        return current
    }

    @Synchronized fun approved(extensionId: String): Pair<JSONObject, File> {
        val stored = preferences.getString(extensionId, null)?.let(::JSONObject)
            ?: throw IllegalArgumentException("extension_not_approved")
        val file = snapshot(stored)
        // Reverify actual bytes and signer on every invocation, including after process restart.
        val current = verify(file, stored.getString("kind"))
        // Approvals created before local-proxy capability inspection are
        // upgraded only after the immutable APK, signer and every legacy
        // identity field have been reverified. The freshly inspected value is
        // then persisted before any extension code may execute.
        val persisted = if (!stored.has(LOCAL_PROXY_IDENTITY_FIELD)) {
            require(sameLegacyIdentity(stored, current)) { "approved_identity_changed" }
            check(preferences.edit().putString(extensionId, current.toString()).commit()) {
                "approval_storage_failed"
            }
            current
        } else {
            stored
        }
        require(sameIdentity(persisted, current)) { "approved_identity_changed" }
        return current to file
    }

    @Synchronized fun listApproved(): List<JSONObject> = preferences.all.values.mapNotNull {
        runCatching { JSONObject(it as String) }.getOrNull()
    }

    @Synchronized fun clearInspections() { inspections.clear() }

    @Synchronized fun revoke(extensionId: String?) {
        inspections.clear()
        val edit = preferences.edit()
        if (extensionId == null) edit.clear() else edit.remove(extensionId)
        check(edit.commit()) { "revocation_storage_failed" }
    }

    private fun snapshot(identity: JSONObject): File {
        val hash = identity.getString("apkSha256")
        require(hash.matches(Regex("[0-9a-f]{64}"))) { "invalid_snapshot_identity" }
        return File(root, "$hash.apk").canonicalFile.also {
            require(it.parentFile == root && it.isFile) { "snapshot_unavailable" }
        }
    }

    @Suppress("DEPRECATION")
    private fun verify(file: File, kind: String): JSONObject {
        require(file.length() in 1..AniyomiPolicy.MAX_APK_BYTES.toLong()) { "invalid_apk_size" }
        val verified = ApkVerifier.Builder(file).setMinCheckedPlatformVersion(26).build().verify()
        require(verified.isVerified && verified.signerCertificates.size == 1) { "apk_signature_invalid_or_multisigner" }
        val certificate = digest(verified.signerCertificates.single().encoded)
        val info = context.packageManager.getPackageArchiveInfo(
            file.absolutePath,
            PackageManager.GET_META_DATA or PackageManager.GET_CONFIGURATIONS,
        ) ?: throw IllegalArgumentException("apk_manifest_invalid")
        val packageName = info.packageName
        val version = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        val hash = sha256(file)
        require(AniyomiPolicy.validIdentity(packageName, version, hash, certificate)) { "invalid_apk_identity" }
        val feature = when (kind) {
            "anime" -> "tachiyomi.animeextension"
            "manga" -> "tachiyomi.extension"
            else -> throw IllegalArgumentException("invalid_kind")
        }
        require(info.reqFeatures?.any { it.name == feature } == true) { "extension_feature_missing" }
        val versionName = info.versionName ?: throw IllegalArgumentException("version_missing")
        val declaredLibrary = if (kind == "anime") {
            info.applicationInfo?.metaData?.get("aniyomix.extensionLib")?.toString()
        } else {
            null
        }
        val api = AniyomiPolicy.apiVersion(kind, versionName, declaredLibrary)
        val classValue = info.applicationInfo?.metaData?.getString("$feature.class")
            ?: throw IllegalArgumentException("extension_class_missing")
        val classes = classValue.split(';').map { if (it.startsWith('.')) packageName + it else it }
        require(classes.size in 1..16 && classes.all {
            it.length <= 300 && it.startsWith("$packageName.") &&
                it.matches(Regex("[A-Za-z_$][A-Za-z0-9_$]*(\\.[A-Za-z_$][A-Za-z0-9_$]*)+"))
        }) { "extension_class_invalid" }
        var dexSignals = AniyomiDexLocalProxyDetector.Signals()
        ZipFile(file).use { zip ->
            val entries = zip.entries()
            var count = 0
            var dexBytes = 0L
            var dexCount = 0
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                require(++count <= 4096) { "apk_entry_limit" }
                require(!entry.name.startsWith("lib/") && !entry.name.endsWith(".so")) { "native_code_unsupported" }
                if (entry.name.matches(Regex("classes([2-9][0-9]*)?\\.dex"))) {
                    require(entry.size > 0) { "invalid_dex" }
                    dexCount++
                    dexBytes += entry.size
                    require(dexCount <= 8 && dexBytes <= AniyomiPolicy.MAX_DEX_BYTES) { "dex_limit" }
                    val inspected = AniyomiDexLocalProxyDetector.inspect(readDexBytes(zip, entry))
                        ?: throw IllegalArgumentException("invalid_dex")
                    dexSignals = dexSignals.merge(inspected)
                }
            }
            require(dexCount > 0 && (Build.VERSION.SDK_INT >= 27 || dexCount == 1)) { "unsupported_dex_layout" }
        }
        return JSONObject().put("extensionId", "aniyomi:$kind:$packageName")
            .put("kind", kind).put("packageName", packageName).put("versionCode", version)
            .put("versionName", versionName).put("apkSha256", hash).put("certificateSha256", certificate)
            .put("apiVersion", api).put("classNames", JSONArray(classes))
            .put(LOCAL_PROXY_IDENTITY_FIELD, dexSignals.requiresLocalProxy)
    }

    private fun sameIdentity(a: JSONObject, b: JSONObject): Boolean = listOf(
        "extensionId", "packageName", "versionCode", "apkSha256", "certificateSha256", "kind", "apiVersion", "classNames",
        LOCAL_PROXY_IDENTITY_FIELD,
    ).all { a.get(it).toString() == b.get(it).toString() }

    private fun sameLegacyIdentity(a: JSONObject, b: JSONObject): Boolean = listOf(
        "extensionId", "packageName", "versionCode", "apkSha256", "certificateSha256", "kind", "apiVersion", "classNames",
    ).all { a.get(it).toString() == b.get(it).toString() }

    private fun readDexBytes(zip: ZipFile, entry: ZipEntry): ByteArray {
        require(entry.size in 1..AniyomiPolicy.MAX_DEX_BYTES.toLong() && entry.size <= Int.MAX_VALUE) {
            "invalid_dex"
        }
        val bytes = ByteArray(entry.size.toInt())
        zip.getInputStream(entry).use { input ->
            var offset = 0
            while (offset < bytes.size) {
                val count = input.read(bytes, offset, bytes.size - offset)
                require(count > 0) { "invalid_dex" }
                offset += count
            }
            require(input.read() == -1) { "invalid_dex" }
        }
        return bytes
    }

    companion object {
        const val LOCAL_PROXY_IDENTITY_FIELD = "requiresLocalProxy"
        fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        fun sha256(file: File): String = file.inputStream().use { input ->
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(32 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
            digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        }
    }
}
