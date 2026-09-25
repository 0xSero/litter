# The WebRTC AAR has no consumer rules. Native code looks up classes/members
# marked with CalledByNative (including constructors and observer interfaces).
# Preserve those entry points and their JNI descriptor types, while allowing
# unreferenced non-JNI WebRTC code and the app's ordinary code to be optimized.
-keepclasseswithmembers,includedescriptorclasses class org.webrtc.** {
    @org.webrtc.CalledByNative* *;
}
-keepclasseswithmembers,includedescriptorclasses class ** {
    @org.jni_zero.CalledByNative* *;
}
