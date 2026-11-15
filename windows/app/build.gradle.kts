import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.multiplatform)
}

// The version is the first "## X.Y.Z" heading of windows/CHANGELOG.md, so a release can't be cut
// without its entry. The updater compares it with the windows-v* releases.
val appVersion: String = rootDir.resolve("CHANGELOG.md").readLines()
    .firstNotNullOfOrNull { Regex("""^## (\d+\.\d+\.\d+)""").find(it)?.groupValues?.get(1) }
    ?: error("windows/CHANGELOG.md needs a \"## X.Y.Z\" heading")
version = appVersion

// FFmpeg's native libraries for the machine that runs the app: Windows for the installer (CI
// passes -Pnative=windows-x86_64), this computer's for tests and running it during development.
val native: String = (findProperty("native") as String?) ?: run {
    val os = System.getProperty("os.name").lowercase()
    val arch = if (System.getProperty("os.arch").contains("aarch64")) "arm64" else "x86_64"
    when {
        "win" in os -> "windows-$arch"
        "mac" in os -> "macosx-$arch"
        else -> "linux-$arch"
    }
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(libs.okhttp)
    implementation(libs.json)
    implementation(libs.coroutines.core)
    implementation(libs.coroutines.swing)
    implementation(libs.jna)
    implementation(libs.jna.platform)
    implementation(libs.javacpp)
    implementation(libs.ffmpeg)
    runtimeOnly(variantOf(libs.javacpp) { classifier(native) })
    runtimeOnly(variantOf(libs.ffmpeg) { classifier(native) })
    testImplementation(kotlin("test-junit"))
}

// The app's version, for the updater and Settings.
val generateBuildConfig by tasks.registering {
    val out = layout.buildDirectory.dir("generated/buildconfig")
    inputs.property("version", appVersion)
    outputs.dir(out)
    doLast {
        val file = out.get().asFile.resolve("com/onda/seaglass/BuildConfig.kt")
        file.parentFile.mkdirs()
        file.writeText(
            """
            |package com.onda.seaglass
            |
            |object BuildConfig {
            |    const val VERSION = "$appVersion"
            |}
            |""".trimMargin(),
        )
    }
}

// The translations: the iPhone app's own tables (the Italian text is the key), plus Windows-only
// lines in src/main/l10n-windows, as on Android.
val copyTranslations by tasks.registering(Copy::class) {
    from(rootDir.resolve("../Seaglass/Resources")) {
        include("*.lproj/Localizable.strings")
        eachFile { path = "l10n/" + file.parentFile.name.removeSuffix(".lproj") + ".strings" }
        includeEmptyDirs = false
    }
    from(projectDir.resolve("src/main/l10n-windows")) { into("l10n-windows") }
    into(layout.buildDirectory.dir("generated/l10n"))
}

sourceSets.main {
    kotlin.srcDir(generateBuildConfig)
    resources.srcDir(copyTranslations)
}

tasks.test {
    // Tests that talk to the real YouTube Music skip themselves when it refuses this machine.
    systemProperty("seaglass.live", findProperty("live") ?: "false")
}

compose.desktop {
    application {
        mainClass = "com.onda.seaglass.MainKt"
        jvmArgs += listOf("-Dfile.encoding=UTF-8", "-Xss2m")
        nativeDistributions {
            // The app image only: the installer around it is Inno Setup's (installer/Seaglass.iss).
            targetFormats(TargetFormat.Exe)
            packageName = "Seaglass"
            packageVersion = appVersion
            description = "Seaglass"
            vendor = "Seaglass"
            includeAllModules = true
            windows {
                iconFile.set(project.file("src/main/resources/icon.ico"))
            }
        }
        buildTypes.release.proguard {
            isEnabled.set(false)
        }
    }
}

tasks.register("printVersion") {
    doLast { println(appVersion) }
}
