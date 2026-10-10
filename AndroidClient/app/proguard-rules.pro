# R8 rules for the release build. The app has no reflection, JNI or
# serialization of its own; CameraX, ML Kit and Play In-App Update ship their
# own consumer rules. Keep line numbers so Play Console crash traces are
# readable (the mapping file is embedded in the .aab automatically).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
