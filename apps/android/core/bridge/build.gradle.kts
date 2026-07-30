plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

fun String.asBuildFlag(): Boolean =
    equals("1") || equals("true", ignoreCase = true) || equals("yes", ignoreCase = true)

val androidAbis = System.getenv("ANDROID_ABIS")
    ?.split(",")
    ?.map { it.trim() }
    ?.filter { it.isNotBlank() }
    ?: listOf("arm64-v8a", "x86_64")

val ghosttyHeader = file("src/main/cpp/include/ghostty.h")
val ghosttyLibrariesAvailable = ghosttyHeader.isFile &&
    androidAbis.all { abi -> file("src/main/jniLibs/$abi/libghostty.so").isFile }
val enableGhosttyJni = System.getenv("LITTER_ENABLE_GHOSTTY_ANDROID")?.asBuildFlag()
    ?: (findProperty("litter.enableGhosttyAndroid") as? String)?.asBuildFlag()
    ?: ghosttyLibrariesAvailable

android {
    namespace = "com.litter.android.core.bridge"
    compileSdk = 36
    ndkVersion = System.getenv("ANDROID_NDK_VERSION")?.takeIf { it.isNotBlank() } ?: "30.0.14904198"

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")

        ndk {
            abiFilters += androidAbis
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    if (enableGhosttyJni) {
        externalNativeBuild {
            cmake {
                path = file("src/main/cpp/CMakeLists.txt")
            }
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    api("net.java.dev.jna:jna:5.14.0@aar")
}
