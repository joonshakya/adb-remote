plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "local.adbremote.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "local.adbremote.android"
        minSdk = 29
        targetSdk = 36
        versionCode = 4
        versionName = "0.4"
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Sideloaded: sign with the local debug key.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }

    sourceSets["main"].apply {
        // The same helper files the iOS app ships (scrcpy-server, helper jar, TV viewer APK).
        assets.srcDir("../../App/Resources")
        // libAdbBridge.so (AdbKit in Swift), built by bridge/build.sh.
        jniLibs.srcDir("../bridge/out/jniLibs")
    }
    packaging { jniLibs.useLegacyPackaging = true }
}

kotlin { jvmToolchain(17) }

val buildBridge by tasks.registering(Exec::class) {
    description = "Builds the Swift AdbKit bridge (libAdbBridge.so)"
    workingDir = file("../bridge")
    commandLine("./build.sh", "release")
}
tasks.named("preBuild") { dependsOn(buildBridge) }

dependencies {
    val bom = platform("androidx.compose:compose-bom:2025.10.01")
    implementation(bom)
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
