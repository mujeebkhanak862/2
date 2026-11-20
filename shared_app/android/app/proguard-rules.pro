# Audit fix (Section 4 "Release signing" / Section 13 #7) — release
# build ab minifyEnabled/shrinkResources use karti hai, isliye yeh file
# zaroori ho gayi (pehle release sirf debug-signed, unminified thi).
#
# Components jo AndroidManifest.xml mein by-name declared hain (Activity,
# Service, AccessibilityService — MainActivity, ScreenCaptureService,
# InputAccessibilityService) Android Gradle Plugin ke apne default
# consumer ProGuard rules se already kept rehte hain automatically, is
# liye unke liye explicit -keep yahan zaroori nahi. Flutter ka apna
# engine bhi apni consumer rules khud laata hai (flutter.gradle ke
# through) — yeh file sirf is app ke apne reflection-sensitive hisso ke
# liye hai.

# MethodChannel/EventChannel dispatch string-based hai (Kotlin `when` par
# method-name match), koi runtime reflection-by-class-name nahi use hoti
# — isliye handler classes (ClipboardHandler, InputHandler, waghera) ko
# explicitly keep karne ki zaroorat nahi.

# Kotlin metadata annotations rakhte hain (kuch libraries reflection ke
# liye inhe padhti hain) — standard safe-default.
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# Crash stack traces readable rakhne ke liye (line numbers strip mat
# karo, sirf source file name generic kar do).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
