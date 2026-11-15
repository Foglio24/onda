pluginManagement {
    repositories {
        google()
        // Google's mirror of Maven Central first, as android/ does: Maven Central throttles busy networks.
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        // Google's mirror of Maven Central first, as android/ does: Maven Central throttles busy networks.
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        mavenCentral()
    }
}

rootProject.name = "SeaglassWindows"
include(":app")
