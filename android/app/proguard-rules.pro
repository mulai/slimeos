# R8 rules for the release build, on top of proguard-android-optimize.txt (which keeps
# native method names, Parcelable CREATORs and everything the manifest names).

# FreeRDP's native code finds this class and calls its static On* callbacks by name
# (android_jni_callback.c, android_freerdp.c: JAVA_LIBFREERDP_CLASS).
-keep class com.freerdp.freerdpcore.services.LibFreeRDP { *; }

# File and line numbers in crash reports; retrace them with the release's mapping.txt.
-keepattributes SourceFile,LineNumberTable
