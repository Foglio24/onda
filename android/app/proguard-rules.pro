# ML Kit (lyrics translation) finds its parts by name, through Firebase's component registrars listed
# in the manifest and created by reflection. R8's full mode keeps a kept class's name but not its
# constructor or methods, which left the registrars empty: the language identifier was never
# registered and translating failed with a NullPointerException. Keep them whole.
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keep class com.google.firebase.components.** { *; }
