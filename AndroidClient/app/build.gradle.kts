plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val appVersion = rootProject.file("../VERSION").readText().trim()
val versionParts = appVersion.split(".")
val computedVersionCode = versionParts[0].toInt() * 10000 + versionParts[1].toInt() * 100 + versionParts[2].toInt()

android {
    namespace = "com.sidescreen.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.sidescreen.app"
        minSdk = 26
        targetSdk = 36
        versionCode = computedVersionCode
        versionName = appVersion
    }

    // Release signing: reads the upload key from env vars (set as GitHub Secrets in CI,
    // or exported locally). Falls back to the debug key when they are absent so that
    // `./gradlew assembleRelease` keeps working on a fresh checkout.
    val keystorePath = System.getenv("SIDESCREEN_KEYSTORE_PATH")
    val hasReleaseKey = keystorePath != null && File(keystorePath).exists()

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = File(keystorePath!!)
                storePassword = System.getenv("SIDESCREEN_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("SIDESCREEN_KEY_ALIAS")
                keyPassword = System.getenv("SIDESCREEN_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        // Separate package so a debug build installs next to the Play Store build
        // (different signing keys would otherwise force an uninstall).
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = false
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("SIDESCREEN_KEYSTORE_PATH not set: signing release with the debug key (not suitable for Play Store).")
                signingConfigs.getByName("debug")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    buildFeatures {
        viewBinding = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")

    // Wireless mode (0.8.0)
    implementation("androidx.camera:camera-core:1.3.1")
    implementation("androidx.camera:camera-camera2:1.3.1")
    implementation("androidx.camera:camera-lifecycle:1.3.1")
    implementation("androidx.camera:camera-view:1.3.1")
    implementation("com.google.mlkit:barcode-scanning:17.2.0")

    testImplementation("junit:junit:4.13.2")
}
