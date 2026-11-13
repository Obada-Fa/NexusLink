plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.nexuslink.nexuslink"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.nexuslink.nexuslink"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val releaseStore = System.getenv("NEXUSLINK_RELEASE_KEYSTORE")
    val releaseStorePassword = System.getenv("NEXUSLINK_RELEASE_STORE_PASSWORD")
    val releaseKeyAlias = System.getenv("NEXUSLINK_RELEASE_KEY_ALIAS")
    val releaseKeyPassword = System.getenv("NEXUSLINK_RELEASE_KEY_PASSWORD")
    val releaseRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
    if (releaseRequested && listOf(releaseStore, releaseStorePassword, releaseKeyAlias, releaseKeyPassword).any { it.isNullOrBlank() }) {
        throw GradleException("Release signing requires the four NEXUSLINK_RELEASE_* environment variables. Verify the existing installed APK certificate before choosing a key.")
    }
    if (!releaseStore.isNullOrBlank()) {
        signingConfigs.create("nexuslinkRelease") {
            storeFile = file(releaseStore)
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
        }
    }
    // "Nexus Test" (debug/profile) builds are signed with one permanent test key
    // when the four NEXUSLINK_TEST_* variables are set, so every test release
    // installs as an update. Without them Gradle falls back to the machine's
    // debug key, which phones with a released test build will refuse.
    val testStore = System.getenv("NEXUSLINK_TEST_KEYSTORE")
    val testSigning = listOf(
        testStore,
        System.getenv("NEXUSLINK_TEST_STORE_PASSWORD"),
        System.getenv("NEXUSLINK_TEST_KEY_ALIAS"),
        System.getenv("NEXUSLINK_TEST_KEY_PASSWORD"),
    ).none { it.isNullOrBlank() }
    if (testSigning) {
        signingConfigs.create("nexuslinkTest") {
            storeFile = file(testStore!!)
            storePassword = System.getenv("NEXUSLINK_TEST_STORE_PASSWORD")
            keyAlias = System.getenv("NEXUSLINK_TEST_KEY_ALIAS")
            keyPassword = System.getenv("NEXUSLINK_TEST_KEY_PASSWORD")
        }
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".test"
            manifestPlaceholders["appLabel"] = "Nexus Test"
            if (testSigning) signingConfig = signingConfigs.getByName("nexuslinkTest")
        }
        maybeCreate("profile").apply {
            applicationIdSuffix = ".test"
            manifestPlaceholders["appLabel"] = "Nexus Test"
            if (testSigning) signingConfig = signingConfigs.getByName("nexuslinkTest")
        }
        release {
            manifestPlaceholders["appLabel"] = "Nexus"
            if (!releaseStore.isNullOrBlank()) signingConfig = signingConfigs.getByName("nexuslinkRelease")
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

dependencies {
    testImplementation("junit:junit:4.13.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.work:work-runtime:2.12.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
