# to.holepunch.bare.kit.* is bare-kit's entire native-binding Java surface
# (Worklet, IPC, their callback interfaces): libbare-kit.so calls back into
# these via JNI (GetMethodID/CallVoidMethod) using the unobfuscated names it
# was built against. R8 has no other signal that these methods are used --
# release builds crash at runtime ("JNI DETECTED ERROR IN APPLICATION: mid ==
# null", from libbare-kit.so's MessageQueue.nativePollOnce integration)
# without this rule. Ships as a consumer rule so app devs never have to add
# it themselves.
-keep class to.holepunch.bare.kit.** { *; }
