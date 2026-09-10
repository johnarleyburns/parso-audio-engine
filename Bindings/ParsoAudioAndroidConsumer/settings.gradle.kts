import org.gradle.api.initialization.resolve.RepositoriesMode

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven {
            url = uri("../ParsoAudioAndroid/build/maven-repository")
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "parso-audio-android-consumer"
