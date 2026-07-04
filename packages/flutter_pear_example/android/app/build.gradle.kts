plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_pear_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.flutter_pear_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// E7.2: hand-rolled native QR scanner (CameraX + ML Kit Barcode Scanning),
// owned directly by this app module -- NOT a Flutter plugin. See CLAUDE.md /
// bd flutter_pear-jqe for why: this project's AGP 9.0.1 / Kotlin 2.3.20
// toolchain has a confirmed, structural incompatibility with every
// camera/permission Flutter plugin (file_picker already broke the build over
// this; mobile_scanner and permission_handler both have open upstream issues
// for the exact same gap). This app module's own Kotlin isn't a separate
// Gradle plugin subproject, so it isn't affected.
//
// LICENSING FLAG (unresolved, see bd for the tracking issue): the
// `androidx.camera:*` family is Apache-2.0, confirmed via each artifact's
// POM. `com.google.mlkit:barcode-scanning` is NOT -- its own POM declares
// the "ML Kit Terms of Service" (a proprietary Google EULA, not an OSI
// license), and it transitively pulls in the closed-source
// `com.google.android.gms:play-services-mlkit-barcode-scanning` /
// `play-services-basement` runtime. That fails LICENSING.md's permissive-
// only (MIT/Apache-2.0/BSD/ISC/0BSD) rule for anything this repo bundles.
// This app module isn't part of the published flutter_pear package LICENSING.md
// governs, but shipping a demo with an undisclosed proprietary dependency
// chain still needs an explicit maintainer call (swap for a permissively-
// licensed on-device QR decoder, or accept and document the exception) --
// not silently left mislabeled as Apache-2.0.
dependencies {
    val cameraxVersion = "1.6.1"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-view:$cameraxVersion")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
}
