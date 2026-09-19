allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// flutter_js 0.8.x still declares Kotlin/JVM 1.8 while its Android Java
// compile task targets JVM 11. Gradle 9 treats that legacy mismatch as an
// error, so align only that dependency without weakening TetoTV's JVM 17 app.
subprojects {
    if (name == "flutter_js") {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(
                org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11,
            )
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Keep the dependency cache immutable. Vendor the five pinned Java sources,
// modifying only VideoOutput; Dart APIs and native binaries are unchanged.
subprojects {
    if (name == "media_kit_video") {
        plugins.withId("com.android.library") {
            val originalDirectory = file("src/main/java/com/alexmercerind/media_kit_video")
            val sourcePins = mapOf(
                "MediaKitVideoPlugin.java" to "276173158b9786db7e95218ebab236d124ea6106248a73330fb190aad2bc3e06",
                "TextureUpdateCallback.java" to "84a13bdc689fc9d441e1087e6fbf9debb3dfdc1b8b4476cae466bcb049989370",
                "Utils.java" to "6e372d9546ee3762a162867e156b23531be873e9036be2a34c1ec2710474eb3a",
                "VideoOutput.java" to "31b30caa2749e86aff4ce05333b103fd7f5f89b8a219062300cb545b6897ee16",
                "VideoOutputManager.java" to "edcc78b744dbd56e3802a46e6ed03ff09182217da84bfcd6f80589f23885b482",
            )
            val patchDirectory = rootProject.file("../third_party/media_kit_video_android/src")
            extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                sourceSets.getByName("main").java.setSrcDirs(listOf(patchDirectory))
            }
            val verifyPatch = tasks.register("verifyTetoTvVideoSurfacePatch") {
                inputs.dir(originalDirectory)
                doLast {
                    check(originalDirectory.listFiles()?.filter { it.extension == "java" }
                        ?.map { it.name }?.toSet() == sourcePins.keys) {
                        "media_kit_video changed: review the scoped Fire TV surface patch before building."
                    }
                    sourcePins.forEach { (name, expected) ->
                        val hash = java.security.MessageDigest.getInstance("SHA-256")
                            .digest(originalDirectory.resolve(name).readBytes())
                            .joinToString("") { "%02x".format(it) }
                        check(hash == expected) {
                            "media_kit_video changed: review $name before building the scoped Fire TV surface patch."
                        }
                    }
                }
            }
            tasks.withType<JavaCompile>().configureEach { dependsOn(verifyPatch) }
        }
    }
}
