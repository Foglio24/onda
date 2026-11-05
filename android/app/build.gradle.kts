plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

/**
 * The iPhone app's translations, used as they are: the keys are the app's Italian text, so the
 * Android app reads the same files (`L10n`) and both apps always say the same things.
 */
abstract class CollectStrings : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sources: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun collect() {
        val out = outputDir.get().asFile.resolve("l10n")
        out.deleteRecursively()
        out.mkdirs()
        sources.files.forEach { file ->
            val language = file.parentFile.name.removeSuffix(".lproj")
            file.copyTo(out.resolve("$language.strings"), overwrite = true)
        }
    }
}

val collectStrings = tasks.register<CollectStrings>("collectStrings") {
    sources.from(fileTree(rootDir.resolve("../Seaglass/Resources")) { include("*.lproj/Localizable.strings") })
    outputDir.set(layout.buildDirectory.dir("generated/l10n"))
}

// The release key stays out of the repository: CI builds the keystore from the ANDROID_SIGNING_KEY
// secret and the public certificate in signing/ (see .github/workflows/android.yml). Without it,
// builds are signed with the computer's debug key, which can't update an installed release.
val keystore = System.getenv("SEAGLASS_KEYSTORE")?.let(::file)?.takeIf { it.exists() }

android {
    namespace = "com.onda.seaglass"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.onda.seaglass"
        minSdk = 29
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
    }

    // Only the app's languages: the libraries' other translations stay out of the APK.
    androidResources {
        localeFilters += listOf("it", "en", "fr", "es", "de", "pt", "zh", "ja", "ru", "tr", "ar")
    }

    signingConfigs {
        if (keystore != null) {
            create("seaglass") {
                storeFile = keystore
                storePassword = System.getenv("SEAGLASS_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("SEAGLASS_KEY_ALIAS") ?: "seaglass"
                keyPassword = System.getenv("SEAGLASS_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            if (keystore != null) signingConfig = signingConfigs.getByName("seaglass")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.getByName(if (keystore != null) "seaglass" else "debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions {
        unitTests.all { it.testLogging { events("passed", "failed", "skipped"); showStandardStreams = true } }
    }
    packaging {
        resources.excludes += setOf("META-INF/*.version", "META-INF/LICENSE*", "META-INF/NOTICE*", "DebugProbesKt.bin")
    }
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(collectStrings, CollectStrings::outputDir)
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation(libs.androidx.core)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(libs.androidx.lifecycle.viewmodel)
    implementation(libs.androidx.palette)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.session)
    implementation(libs.media3.datasource.okhttp)
    implementation(libs.coil.compose)
    implementation(libs.coil.network)
    implementation(libs.okhttp)
    implementation(libs.haze)
    implementation(libs.haze.glass)
    implementation(libs.haze.blur)
    implementation(libs.coroutines.android)

    // The checks in src/test run on the computer (or CI) against the real services.
    testImplementation(libs.junit)
    testImplementation(libs.json)
}
