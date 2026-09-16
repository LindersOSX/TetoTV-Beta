import java.security.MessageDigest

plugins {
    id("com.android.library")
}

val vendoredRoot =
    rootProject.projectDir.parentFile.resolve("third_party/app_cash_quickjs/upstream")
val nativeRoot = vendoredRoot.resolve("quickjs/common/native")
val quickJsVersion = nativeRoot.resolve("quickjs/VERSION").readText().trim()

android {
    namespace = "app.cash.quickjs"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 24
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_TOOLCHAIN=clang",
                    "-DANDROID_STL=c++_static",
                    "-DQUICKJS_SOURCE_ROOT=${nativeRoot.invariantSeparatorsPath}",
                    "-DQUICKJS_VERSION=$quickJsVersion",
                )
                cFlags += "-fstrict-aliasing"
                cppFlags += "-fstrict-aliasing"
            }
        }
    }

    compileOptions {
        // Preserve 0.9.2's Java 8 class shape, including the synthetic access
        // bridges that extension bytecode may have resolved against.
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    sourceSets.getByName("main").java.srcDirs(
        vendoredRoot.resolve("quickjs/common/java"),
        vendoredRoot.resolve("quickjs/android/src/main/java"),
    )

    buildTypes {
        release {
            externalNativeBuild {
                cmake {
                    arguments += "-DCMAKE_BUILD_TYPE=MinSizeRel"
                    cFlags += listOf(
                        "-g0",
                        "-Os",
                        "-fomit-frame-pointer",
                        "-DNDEBUG",
                        "-fvisibility=hidden",
                    )
                    cppFlags += listOf(
                        "-g0",
                        "-Os",
                        "-fomit-frame-pointer",
                        "-DNDEBUG",
                        "-fvisibility=hidden",
                    )
                }
            }
        }
        debug {
            externalNativeBuild {
                cmake {
                    cFlags += listOf("-g", "-DDEBUG", "-DDUMP_LEAKS")
                    cppFlags += listOf("-g", "-DDEBUG", "-DDUMP_LEAKS")
                }
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

val sourceManifest = projectDir.resolve("SOURCE_MANIFEST.sha256")

val verifyVendoredQuickJs by tasks.registering {
    inputs.file(sourceManifest)
    inputs.dir(vendoredRoot)
    doLast {
        if (!sourceManifest.isFile) {
            throw GradleException("Cash App QuickJS source manifest is missing.")
        }
        val expected = sourceManifest.readLines()
            .filter { line -> line.isNotBlank() && !line.startsWith("#") }
            .associate { line ->
                val separator = line.indexOf("  ")
                if (separator <= 0) {
                    throw GradleException("Malformed QuickJS source manifest line: $line")
                }
                line.substring(separator + 2) to line.substring(0, separator).lowercase()
            }
        val actualPaths = vendoredRoot.walkTopDown()
            .filter { file -> file.isFile }
            .map { file -> file.relativeTo(vendoredRoot).invariantSeparatorsPath }
            .toSet()
        if (actualPaths != expected.keys) {
            throw GradleException(
                "Cash App QuickJS source inventory differs from the reviewed manifest. " +
                    "Missing=${expected.keys - actualPaths}; unexpected=${actualPaths - expected.keys}",
            )
        }
        expected.forEach { (relativePath, expectedSha256) ->
            val source = vendoredRoot.resolve(relativePath)
            val actualSha256 = MessageDigest.getInstance("SHA-256")
                .digest(source.readBytes())
                .joinToString("") { byte -> "%02x".format(byte) }
            if (actualSha256 != expectedSha256) {
                throw GradleException(
                    "Cash App QuickJS source failed integrity verification: $relativePath",
                )
            }
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(verifyVendoredQuickJs)
}

dependencies {
    // Source-only annotations. Upstream 0.9.2 published 1.1.0 as an API
    // dependency; this internal, non-published module uses the already-verified
    // 1.2.0 compiler artifact without exposing or packaging it. Annotation
    // retention and the app.cash.quickjs runtime descriptors remain unchanged.
    compileOnly("androidx.annotation:annotation:1.2.0")
}
