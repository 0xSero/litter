plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21"
    id("com.github.triplet.play")
}

val googleServicesFile = file("google-services.json")
if (googleServicesFile.exists()) {
    apply(plugin = "com.google.gms.google-services")
}

fun projectPropOrEnv(name: String): String? =
    (findProperty(name) as? String)?.takeIf { it.isNotBlank() }
        ?: System.getenv(name)?.takeIf { it.isNotBlank() }

val uploadStoreFile = projectPropOrEnv("LITTER_UPLOAD_STORE_FILE")
val uploadStorePassword = projectPropOrEnv("LITTER_UPLOAD_STORE_PASSWORD")
val uploadKeyAlias = projectPropOrEnv("LITTER_UPLOAD_KEY_ALIAS")
val uploadKeyPassword = projectPropOrEnv("LITTER_UPLOAD_KEY_PASSWORD")
val hasUploadSigning = listOf(uploadStoreFile, uploadStorePassword, uploadKeyAlias, uploadKeyPassword).all { !it.isNullOrBlank() }

android {
    namespace = "com.sigkitten.litter.android"
    compileSdk = 35
    ndkVersion = projectPropOrEnv("ANDROID_NDK_VERSION") ?: "30.0.14904198"

    defaultConfig {
        applicationId = "com.sigkitten.litter.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 11
        versionName = "1.5.0"
        buildConfigField("boolean", "ENABLE_ON_DEVICE_BRIDGE", "true")
        buildConfigField("String", "RUNTIME_STARTUP_MODE", "\"hybrid\"")
        buildConfigField("String", "APP_RUNTIME_TRANSPORT", "\"app_bridge_rpc_transport\"")
        manifestPlaceholders["runtimeStartupMode"] = "hybrid"
        manifestPlaceholders["enableOnDeviceBridge"] = "true"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    if (hasUploadSigning) {
        signingConfigs {
            create("upload") {
                storeFile = file(uploadStoreFile!!)
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (hasUploadSigning) {
                signingConfig = signingConfigs.getByName("upload")
            }
            ndk {
                debugSymbolLevel = "NONE"
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    sourceSets {
        getByName("main") {
            java.srcDir("../../../shared/rust-bridge/generated/kotlin")
            assets.srcDir("../../ios/Sources/Litter/Resources/Themes")
        }
    }

    bundle {
        storeArchive {
            enable = false
        }
    }
}

play {
    defaultToAppBundles.set(true)
    track.set(projectPropOrEnv("LITTER_PLAY_TRACK") ?: "internal")
    projectPropOrEnv("LITTER_PLAY_PROMOTE_TRACK")?.let { promoteTrack.set(it) }

    // Release status:
    //   completed   → 100% rollout (default, matches historical behavior)
    //   inProgress  → staged rollout, requires userFraction
    //   draft       → upload only, no release
    //   halted      → pause current rollout
    val statusName = (projectPropOrEnv("LITTER_PLAY_RELEASE_STATUS") ?: "completed").lowercase()
    releaseStatus.set(
        when (statusName) {
            "inprogress", "in_progress" -> com.github.triplet.gradle.androidpublisher.ReleaseStatus.IN_PROGRESS
            "draft" -> com.github.triplet.gradle.androidpublisher.ReleaseStatus.DRAFT
            "halted" -> com.github.triplet.gradle.androidpublisher.ReleaseStatus.HALTED
            else -> com.github.triplet.gradle.androidpublisher.ReleaseStatus.COMPLETED
        }
    )

    // Staged rollout percentage (0.0–1.0). Only honored when releaseStatus is
    // IN_PROGRESS or HALTED. Ignored otherwise so we never accidentally stage
    // a COMPLETED release.
    projectPropOrEnv("LITTER_PLAY_USER_FRACTION")?.toDoubleOrNull()?.let { fraction ->
        userFraction.set(fraction.coerceIn(0.0, 1.0))
    }

    val serviceAccountPath = projectPropOrEnv("LITTER_PLAY_SERVICE_ACCOUNT_JSON")
    if (!serviceAccountPath.isNullOrBlank()) {
        serviceAccountCredentials.set(file(serviceAccountPath))
    }
}

dependencies {
    implementation(project(":core:bridge"))

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.core:core-splashscreen:1.0.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.browser:browser:1.8.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation(platform("androidx.compose:compose-bom:2024.09.00"))
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-service:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:syntax-highlight:4.6.2") {
        exclude(group = "org.jetbrains", module = "annotations-java5")
    }
    implementation("io.noties:prism4j:2.0.0") {
        exclude(group = "org.jetbrains", module = "annotations-java5")
    }
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("com.android.billingclient:billing-ktx:7.0.0")

    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-ui:1.4.1")
    implementation("androidx.media3:media3-transformer:1.4.1")

    implementation("io.github.webrtc-sdk:android:144.7559.04")

    // Alleycat remote-host pairing QR scanner
    implementation("androidx.camera:camera-core:1.3.4")
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    implementation("androidx.glance:glance-appwidget:1.1.0")
    implementation("androidx.glance:glance-material3:1.1.0")

    implementation(platform("com.google.firebase:firebase-bom:33.0.0"))
    implementation("com.google.firebase:firebase-messaging")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.09.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("tools.fastlane:screengrab:2.1.1")
}
