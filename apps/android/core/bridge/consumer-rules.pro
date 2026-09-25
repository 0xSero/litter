# JNA dispatches through native code and reflection. Its AAR does not ship these
# rules; retain the small interop runtime and its Structure/Callback subclasses,
# not the generated UniFFI data records or the rest of the app.
# https://github.com/java-native-access/jna/blob/5.19.1/www/FrequentlyAskedQuestions.md#jna-on-android
-keep class com.sun.jna.* { *; }
-keep class * extends com.sun.jna.Structure { *; }
-keep class * implements com.sun.jna.Callback { *; }
-keepattributes RuntimeVisibleAnnotations

# JNA's optional desktop integration references AWT, absent on Android.
-dontwarn java.awt.**

# Rust/UniFFI direct mapping and the bridge's Java_* JNI entry points use native
# method names. The app's default proguard-android-optimize.txt also provides
# this rule, but the bridge must carry the contract for other consumers.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# ghostty_jni.cpp resolves these concrete callback methods with GetMethodID.
# Keep the interfaces too: Kotlin SAM implementations can be synthesized after
# keep-rule matching, and must inherit these exact native-facing method names.
-keep interface com.litter.android.core.bridge.GhosttyInputCallback {
    public void onInput(byte[]);
}
-keep interface com.litter.android.core.bridge.GhosttyWakeupListener {
    public void onWakeup();
}
-keepclassmembers class * implements com.litter.android.core.bridge.GhosttyInputCallback {
    public void onInput(byte[]);
}
-keepclassmembers class * implements com.litter.android.core.bridge.GhosttyWakeupListener {
    public void onWakeup();
}
