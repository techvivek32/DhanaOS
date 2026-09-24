# DhanaOS release shrinking rules.
# R8 is on for release builds (isMinifyEnabled), so anything reached only by reflection
# has to be kept explicitly or it disappears from the APK and fails at runtime.

# ---- Flutter engine ----
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ---- Supabase / Ktor / OkHttp ----
# The realtime socket and the Postgrest client resolve classes reflectively.
-keep class io.ktor.** { *; }
-dontwarn io.ktor.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**
-keepclassmembers class * {
    @kotlinx.serialization.Serializable <fields>;
}

# ---- Kotlin coroutines / serialization ----
-keepclassmembers class kotlinx.coroutines.** { volatile <fields>; }
-dontwarn kotlinx.coroutines.**
-keepattributes *Annotation*, InnerClasses, Signature, Exceptions

# ---- record (audio capture for the intake voice note) ----
-keep class com.llfbandit.record.** { *; }

# ---- just_audio / ExoPlayer ----
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# ---- image_picker / file_picker ----
-keep class androidx.lifecycle.** { *; }
-keep class androidx.core.content.FileProvider { *; }

# ---- desugaring ----
-dontwarn java.lang.invoke.**
-dontwarn build.IgnoreJava8API

# Keep line numbers so a release crash report is still readable.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
