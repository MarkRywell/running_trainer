plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    // Must match the Kotlin `package` in MainActivity.kt and the directory it
    // lives in. Renaming one without the other fails the build with a missing
    // class rather than anything that names the real cause.
    namespace = "com.markrywell.runningtrainer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The store-facing identity. `com.example.*` is the Flutter template
        // placeholder and is rejected by Google Play, so this is a real
        // reverse-domain name.
        //
        // It cannot be changed after a store submission — Play keys the app to
        // this string permanently, and a different one is a different app. So it
        // also decides where the app's data lives: `shared_preferences` writes
        // under the applicationId, which is why every logged week, profile and
        // coach decision disappears when this changes. That is the intended
        // behaviour for a rename, but it is not a thing to do casually.
        applicationId = "com.markrywell.runningtrainer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
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
