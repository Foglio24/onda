import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.compose.multiplatform)
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        freeCompilerArgs.addAll("-opt-in=kotlin.time.ExperimentalTime")
    }
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(libs.okhttp)
    implementation(libs.json)
    implementation(libs.coroutines.core)
    implementation(libs.coroutines.swing)
    testImplementation(kotlin("test-junit"))
}

compose.desktop {
    application {
        mainClass = "com.onda.seaglass.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Exe, TargetFormat.Msi)
            packageName = "Seaglass"
            packageVersion = project.findProperty("seaglass.version") as String? ?: "0.1.0"
            description = "Seaglass — YouTube Music player"
            copyright = "© Seaglass"
            vendor = "Seaglass"
            windows {
                menuGroup = "Seaglass"
                upgradeUuid = "A7C3E91F-2B4D-4F6A-9E1C-8D5B0A3F7C2E"
                shortcut = true
                dirChooser = true
                perUserInstall = true
                // Custom URI scheme for account sign-in (same callback as iPhone/Mac).
                includeAllModules = true
            }
        }
        buildTypes.release.proguard {
            isEnabled.set(false)
        }
    }
}

tasks.register("printVersion") {
    doLast {
        println(project.findProperty("seaglass.version") ?: "0.1.0")
    }
}
