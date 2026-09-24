allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// ---------------------------------------------------------------------------------------
// compileSdk floor for plugin modules.
//
// flutter_plugin_android_lifecycle (reached through image_picker) requires every module that
// depends on it to compile against API 36. Plugins that still declare 34 fail the build at
// :<plugin>:checkDebugAarMetadata with a message that reads like a minSdk problem but is not:
//
//   Dependency ':flutter_plugin_android_lifecycle' requires libraries and applications that
//   depend on it to compile against version 36 or later of the Android APIs.
//   :file_picker is currently compiled against android-34.
//
// Upgrading the offending package is the real fix, and pubspec.yaml does that for file_picker
// and just_audio. This block is the safety net for the next one, so a stale transitive plugin
// costs a rebuild rather than an afternoon of bisecting.
//
// Two things about the shape of this block are deliberate:
//
//  * It sits BEFORE `evaluationDependsOn(":app")` below. That call forces evaluation, and
//    registering an afterEvaluate hook on an already-evaluated project throws
//    "Cannot run Project.afterEvaluate(Action) when the project is already evaluated".
//    The state.executed branch covers the case anyway, but order still matters.
//  * It uses reflection rather than a typed cast to com.android.build.gradle.BaseExtension.
//    The Android Gradle Plugin is not on the root project's buildscript classpath in
//    Flutter's current template, so naming that class here does not compile.
// ---------------------------------------------------------------------------------------
val compileSdkFloor = 36

fun Project.raiseCompileSdkFloor() {
    val androidExt = extensions.findByName("android") ?: return
    runCatching {
        val current = androidExt.javaClass
            .getMethod("getCompileSdkVersion")
            .invoke(androidExt) as? String

        val level = current?.removePrefix("android-")?.toIntOrNull() ?: return

        if (level < compileSdkFloor) {
            androidExt.javaClass
                .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                .invoke(androidExt, compileSdkFloor)
            logger.lifecycle("compileSdk floor: raised $name from $level to $compileSdkFloor")
        }
    }.onFailure {
        logger.info("compileSdk floor skipped for $name: ${it.message}")
    }
}

subprojects {
    if (state.executed) {
        raiseCompileSdkFloor()
    } else {
        afterEvaluate { raiseCompileSdkFloor() }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
