# Flutter and AndroidX/plugin consumer rules are applied automatically by AGP/R8.
# Minimal Cronet / cronet_http keep rules to preserve JNI and Play Services reflection under R8.
-keep class io.flutter.plugins.cronet_http.** { *; }
-keep class org.chromium.net.** { *; }
-keep class com.google.android.gms.net.** { *; }
