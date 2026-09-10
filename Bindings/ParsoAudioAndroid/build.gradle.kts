import org.gradle.api.JavaVersion
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library") version "8.7.3"
    id("org.jetbrains.kotlin.android") version "2.0.21"
    id("maven-publish")
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

val parsoNdkVersion = providers.gradleProperty("parsoNdkVersion")
    .orElse("30.0.16248370")
    .get()
val parsoCmakeVersion = providers.gradleProperty("parsoCmakeVersion")
    .orElse("4.1.2")
    .get()

android {
    namespace = "com.parsoaudio"
    compileSdk = 35
    ndkVersion = parsoNdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 26

        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }

        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DPARSO_BUILD_TESTS=OFF",
                    "-DPARSO_BUILD_SHARED_API=ON",
                    "-DPARSO_BUILD_CODEC_BRIDGES=ON",
                    "-DPARSO_BUILD_CODEC_FIXTURE_TESTS=OFF",
                    "-DCMAKE_BUILD_TYPE=Release",
                )
                cppFlags += listOf("-std=c++17")
                targets += listOf("ParsoAPI", "ParsoAndroidJNI")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../CMakeLists.txt")
            version = parsoCmakeVersion
        }
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

publishing {
    repositories {
        maven {
            name = "localStaging"
            url = layout.buildDirectory.dir("maven-repository").get().asFile.toURI()
        }
    }
    publications {
        register<MavenPublication>("release") {
            groupId = "com.parsoaudio"
            artifactId = "parso-audio-android"
            version = "0.1.0"
            afterEvaluate {
                from(components["release"])
            }
        }
    }
}
