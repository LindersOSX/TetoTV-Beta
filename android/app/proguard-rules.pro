# Flutter, media_kit and mpv communicate through generated JNI and reflection.
-keep class io.flutter.** { *; }
-keep class com.alexmercerind.** { *; }
-keep class androidx.media.** { *; }
-keep class androidx.tvprovider.** { *; }
-keep class org.libtorrent4j.swig.libtorrent_jni { *; }
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

# Flutter's engine includes optional Play Store deferred-component references.
# TetoTV ships one self-contained TV APK and does not use dynamic features.
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
