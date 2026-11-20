# Verification preference

Run verification locally. Do not add workflows, enable GitHub Actions, or dispatch hosted CI without explicit authorization.

Run shared and Android checks locally. Run iOS builds and simulator tests on a Mac with `scripts/verify-ios.sh`; see `docs/react-native/MACOS.md`. When working without a Mac, record the commit and checks for Mac verification instead of using hosted runners.

# Generated files and repository hygiene

- Keep shared iOS setup versioned: `.xcode.env` with portable Node discovery, `PrivacyInfo.xcprivacy`, `Podfile.lock`, the Xcode project, shared schemes, and application plists. CocoaPods/React Native may update these; review and include necessary updates with the related work rather than treating them as unexplained user edits.
- Keep machine-specific Node paths in ignored `.xcode.env.local`, not `.xcode.env`. Keep dependencies, build outputs, diagnostics, and Xcode user state in existing ignored locations (`Pods/`, `node_modules/`, `build/`, `work/`, `DerivedData/`, and `xcuserdata/`). Add narrow ignore rules for genuinely disposable new output; never ignore required project configuration merely to hide a dirty status.
- Before handing off, inspect `git status --short --untracked-files=all`. Stage intended new source/configuration/documentation files so no task-created, non-ignored files remain untracked. Include shared generated setup in commits when committing is requested; do not create automatic build-time commits or commit without authorization.
- Do not use `assume-unchanged` or `skip-worktree` to hide tracked changes. Preserve unrelated changes, and describe pre-existing differences as such rather than attributing them to the owner.
