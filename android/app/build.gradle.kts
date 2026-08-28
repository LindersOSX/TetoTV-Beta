import java.io.FileInputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.security.interfaces.ECKey
import java.security.interfaces.RSAKey
import java.util.Properties
import javax.naming.ldap.LdapName

fun loadReleaseCertificate(
    storeFile: File,
    storePassword: String,
    keyAlias: String,
): X509Certificate? {
    // Android signing stores may be JKS or PKCS12 regardless of their file
    // extension. Inspect both formats without logging paths or credentials.
    for (type in listOf("PKCS12", "JKS")) {
        val certificate = runCatching {
            val keyStore = KeyStore.getInstance(type)
            FileInputStream(storeFile).use { input ->
                keyStore.load(input, storePassword.toCharArray())
            }
            keyStore.getCertificate(keyAlias) as? X509Certificate
        }.getOrNull()
        if (certificate != null) return certificate
    }
    return null
}

fun X509Certificate.hasAndroidDebugSubject(): Boolean = runCatching {
    LdapName(subjectX500Principal.name).rdns.any { rdn ->
        rdn.type.equals("CN", ignoreCase = true) &&
            rdn.value.toString().equals("Android Debug", ignoreCase = true)
    }
}.getOrDefault(false)

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use(keystoreProperties::load)
}
val validateReleaseSigning: () -> Unit = {
    if (!keystorePropertiesFile.exists()) {
        throw GradleException(
            "Release signing is not configured. Restore android/key.properties " +
                "and the original keystore before building an update.",
        )
    }
    val requiredSigningProperties = listOf(
        "keyAlias",
        "keyPassword",
        "storeFile",
        "storePassword",
    )
    if (requiredSigningProperties.any { keystoreProperties.getProperty(it).isNullOrBlank() }) {
        throw GradleException(
            "Release signing is incomplete. Configure every required entry in " +
                "android/key.properties before building an update.",
        )
    }

    val releaseKeyAlias = keystoreProperties.getProperty("keyAlias").trim()
    val releaseStoreFile = file(keystoreProperties.getProperty("storeFile").trim())
    if (!releaseStoreFile.isFile) {
        throw GradleException(
            "The configured release keystore could not be found. Restore the " +
                "original keystore before building an update.",
        )
    }
    if (
        releaseKeyAlias.equals("androiddebugkey", ignoreCase = true) ||
        releaseStoreFile.name.equals("debug.keystore", ignoreCase = true)
    ) {
        throw GradleException(
            "Refusing to create a release signed with an Android debug key. " +
                "Configure a dedicated, securely stored release key first.",
        )
    }

    val releaseCertificate = loadReleaseCertificate(
        storeFile = releaseStoreFile,
        storePassword = keystoreProperties.getProperty("storePassword"),
        keyAlias = releaseKeyAlias,
    ) ?: throw GradleException(
        "The configured release signing certificate could not be inspected. " +
            "Verify the keystore format, alias, and local credentials.",
    )
    if (releaseCertificate.hasAndroidDebugSubject()) {
        throw GradleException(
            "Refusing to create a release signed with an Android debug " +
                "certificate. Configure a dedicated release certificate first.",
        )
    }
    runCatching { releaseCertificate.checkValidity() }.getOrElse {
        throw GradleException(
            "The configured release certificate is expired or not yet valid.",
        )
    }
    val signatureAlgorithm = releaseCertificate.sigAlgName.uppercase()
    if ("SHA1" in signatureAlgorithm || "MD5" in signatureAlgorithm) {
        throw GradleException(
            "The configured release certificate uses an obsolete signature algorithm.",
        )
    }
    val publicKeyIsStrong = when (val publicKey = releaseCertificate.publicKey) {
        is RSAKey -> publicKey.modulus.bitLength() >= 2_048
        is ECKey -> (publicKey.params?.order?.bitLength() ?: 0) >= 256
        else -> false
    }
    if (!publicKeyIsStrong) {
        throw GradleException(
            "The configured release certificate must use RSA-2048 or stronger, " +
                "or an EC key with at least 256-bit security parameters.",
        )
    }
}

// Inspect the resolved task graph instead of only the command-line task name.
// Aggregate invocations such as `gradlew assemble` schedule release tasks even
// though the requested task itself does not contain the word "release".
gradle.taskGraph.whenReady {
    val releaseTaskScheduled = allTasks.any { task ->
        task.project.path == project.path &&
            task.name.contains("release", ignoreCase = true)
    }
    if (releaseTaskScheduled) validateReleaseSigning()
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.animetv.anime_tv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Use a unique reverse-domain application ID before store publishing.
        applicationId = "dev.animetv.anime_tv"
        // Flutter currently requires API 24. This supports Fire OS 6+
        // (API 25+) but cannot be installed on Fire OS 5 (API 22).
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++20", "-fexceptions", "-frtti")
            }
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                // Keep Android 7/Fire OS compatibility through v2 while also
                // enabling v3 integrity protection on Android 9 and newer.
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    // media_kit loads libmpv through Dart FFI and explicitly requests extracted
    // native libraries. Honor that request for older Fire OS/Android TV loaders
    // instead of silently overriding it with AGP's modern in-APK default.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildFeatures {
        prefab = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    lint {
        // Flutter owns and regenerates the ignored local.properties file. Its
        // Windows path escaping is valid for Gradle but trips this lint check.
        disable += "PropertyEscape"
    }
}

// Flutter's Gradle plugin seeds every supported ABI into non-split APKs. A
// dependency that ships x86_64 libraries can therefore make an ARM release
// appear x86_64-compatible even though libflutter.so and libapp.so were only
// compiled for ARM. Restrict final release packaging to TetoTV's supported
// public ABIs without changing debug builds used by x86_64 emulators or
// conflicting with Flutter's split-per-ABI configuration.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.add("lib/x86_64/**")
    }
}

val discordSocialSdkAar = file("libs/discord_partner_sdk.aar")
val discordSocialSdkSha256 =
    "85a5b0c9b2b828c84d27a7d7839d834bd7dac323895a691e2a19e056543d2faa"

val verifyDiscordSocialSdk by tasks.registering {
    inputs.file(discordSocialSdkAar)
    doLast {
        if (!discordSocialSdkAar.isFile) {
            throw GradleException(
                "The reviewed Discord Social SDK AAR is missing. Restore it from " +
                    "the pinned artifact documented in third_party/discord_social_sdk.",
            )
        }
        val actual = MessageDigest.getInstance("SHA-256")
            .digest(discordSocialSdkAar.readBytes())
            .joinToString("") { byte -> "%02x".format(byte) }
        if (actual != discordSocialSdkSha256) {
            throw GradleException(
                "The Discord Social SDK AAR failed its integrity check. " +
                    "Do not build or distribute this artifact.",
            )
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(verifyDiscordSocialSdk)
}

dependencies {
    implementation(files(discordSocialSdkAar))
    implementation("androidx.browser:browser:1.8.0")
    // Pinned to the last libtorrent4j Android build targeting API 24. The
    // subsequent 2.1.0-39 artifacts require API 28, which would drop Fire OS
    // 6 and Android 7 devices currently supported by TetoTV.
    implementation("org.libtorrent4j:libtorrent4j:2.1.0-38")
    implementation("org.libtorrent4j:libtorrent4j-android-arm:2.1.0-38")
    implementation("org.libtorrent4j:libtorrent4j-android-arm64:2.1.0-38")
    implementation("androidx.media:media:1.8.0")
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")
    implementation("androidx.tvprovider:tvprovider:1.1.0")
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
