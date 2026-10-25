# Our code is entered from the manifest and JNI: keep it whole. ExoPlayer and Guava are
# shrunk to what we use; names are kept so crash logs stay readable.
-keep class local.adbremote.** { *; }
-dontobfuscate
-ignorewarnings
-dontwarn **
