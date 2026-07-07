// Empty on purpose: CBareKit exists only to re-export BareKit.h (see
// include/CBareKit.h) as a Clang module Swift can `import`. Xcode's SPM
// build-phase translation expects at least one compilable source file per
// target even when there's nothing to implement.
