# Standalone ImGui + Metal iOS demo

This repository workflow builds a standalone ARM64 iOS dynamic library containing a small Dear ImGui interface rendered with Metal.

## Build

1. Open **Actions**.
2. Select **Build standalone ImGui Metal demo**.
3. Choose **Run workflow**.
4. Download `StandaloneImGuiDemo-arm64` from the completed run's Artifacts section.

## Integration boundary

The exported `CreateStandaloneImGuiDemoController()` factory is intended for an iOS app you own or are authorized to develop. This sample does not attach to, inject into, inspect, hook, or modify a third-party game or process.

Dear ImGui is fetched at the pinned `v1.91.9b` tag during the workflow. The resulting `.dylib` is a build artifact, not a signed or installable iOS app.
