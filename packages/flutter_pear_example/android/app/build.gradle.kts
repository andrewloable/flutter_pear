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

// E7.2: hand-rolled native QR scanner (CameraX + ZXing), owned directly by
// this app module -- NOT a Flutter plugin. See CLAUDE.md / bd
// flutter_pear-jqe for why: this project's AGP 9.0.1 / Kotlin 2.3.20
// toolchain has a confirmed, structural incompatibility with every
// camera/permission Flutter plugin (file_picker already broke the build over
// this; mobile_scanner and permission_handler both have open upstream issues
// for the exact same gap). This app module's own Kotlin isn't a separate
// Gradle plugin subproject, so it isn't affected.
//
// LICENSING (flutter_pear-64q, resolved): `androidx.camera:*` is Apache-2.0,
// confirmed via each artifact's POM. This used to also depend on
// `com.google.mlkit:barcode-scanning`, whose own POM declares the "ML Kit
// Terms of Service" (a proprietary Google EULA, not an OSI license) and
// transitively pulled in closed-source `com.google.android.gms:*` --
// swapped for `com.google.zxing:core` (confirmed Apache-2.0 via its
// zxing-parent POM's <licenses> block), a pure-JVM barcode decoder with no
// Android Gradle module of its own -- zero risk of the AGP9/Kotlin-plugin
// class of breakage described above, unlike a second Flutter-plugin-shaped
// dependency would have been.
dependencies {
    val cameraxVersion = "1.6.1"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-view:$cameraxVersion")
    implementation("com.google.zxing:core:3.5.3")
    testImplementation("junit:junit:4.13.2")
}
