# Provider DEX is loaded after shrink time. Its references are invisible to R8.
-keep class eu.kanade.tachiyomi.** { *; }
-keep interface eu.kanade.tachiyomi.** { *; }
-keep class tachiyomi.core.common.util.lang.** { *; }
-keep class uy.kohesive.injekt.** { *; }
-keep interface uy.kohesive.injekt.** { *; }
# Injekt reads genericSuperclass at runtime. Full-mode R8 strips Signature from
# otherwise-unkept anonymous addSingleton/inject subclasses, including those in
# the host dispatcher. Keeping only the Injekt package or Signature attributes
# does not retain these external subclasses; setup then fails before APK loading.
-keep,allowobfuscation class ** extends uy.kohesive.injekt.api.FullTypeReference { *; }
-keep class dev.mihon.injekt.** { *; }
-keep class rx.** { *; }
-keep interface rx.** { *; }
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-keep class okio.** { *; }
-keep interface okio.** { *; }
# QuickJs has Java methods reached from its reviewed host-owned JNI library.
-keep,allowoptimization class app.cash.quickjs.** { public protected *; }
-keep class org.jsoup.** { *; }
-keep interface org.jsoup.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep interface kotlinx.coroutines.** { *; }
-keep class kotlinx.serialization.** { *; }
-keep interface kotlinx.serialization.** { *; }
-keep class kotlin.** { *; }
-keep interface kotlin.** { *; }
# Loaded parent-first by exact name for extension DEX bytecode that bundles a
# worker-local NanoHTTPD helper. Never broaden this to all aniyomi.lib classes.
-keep class aniyomi.lib.m3u8server.M3u8ServerManager { *; }
-keepattributes Signature,InnerClasses,EnclosingMethod,RuntimeVisibleAnnotations,AnnotationDefault
