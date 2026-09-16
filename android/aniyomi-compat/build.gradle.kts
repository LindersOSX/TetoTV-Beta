plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "dev.animetv.anime_tv.aniyomi.compat"
    compileSdk = 36
    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets.getByName("main").assets.srcDir("../../third_party/aniyomi_compat")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        // Legacy APKs call Interface$DefaultImpls; do not remove those bridges.
        jvmDefault = org.jetbrains.kotlin.gradle.dsl.JvmDefaultMode.ENABLE
    }
}

dependencies {
    api("io.reactivex:rxjava:1.3.8")
    // Match the published Aniyomi host ABI. Current Yuzono APKs call OkHttp 5
    // Kotlin-duration overloads that do not exist in OkHttp 4.x.
    api("com.squareup.okhttp3:okhttp:5.4.0")
    api("org.jsoup:jsoup:1.19.1")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.1")
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    api("org.jetbrains.kotlinx:kotlinx-serialization-json-okio:1.9.0")
    api("uy.kohesive.injekt:injekt-core:1.16.1")
    api("androidx.preference:preference-ktx:1.2.1")
    // Current Aniyomi/Yuzono extensions use this exact host JavaScript ABI.
    // Build the reviewed 0.9.2 source locally so every ELF LOAD segment is
    // compatible with Android devices that use 16 KiB memory pages.
    implementation(project(":cash-quickjs-android"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
