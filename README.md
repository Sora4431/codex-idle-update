# Codex Idle Update

An unofficial macOS utility that applies prepared ChatGPT desktop updates when Codex is idle.

## Try the preview

Requires macOS 14 or later on an Apple Silicon or Intel Mac, with the Codex-enabled ChatGPT.app in the Applications folder.

1. Download and extract the ZIP from the [v0.1.2 preview release](https://github.com/Sora4431/codex-idle-update/releases/tag/v0.1.2-preview).
2. Move **Codex Idle Update.app** to Applications and open it.
3. Select **Enable Auto Updates**. If macOS requests permission to run in the background, click **Open System Settings** and grant permission there.
4. To turn it off, open the app and select **Disable Auto Updates**.

The preview has not been signed with Developer ID or notarized by Apple. If macOS blocks the downloaded copy, use a signed and notarized build.

## How it works

After you log in, a macOS LaunchAgent runs the helper every five minutes. If ChatGPT's built-in updater has staged a new build, the helper checks for local Codex activity. Once the app has been idle for long enough, the helper requests a normal quit. It waits for the built-in updater to finish, reopens ChatGPT in the background, and checks the installed build number.

The helper relies on local ChatGPT data structures. If it cannot verify the expected databases or activity state, it defers the update. A new task can still arrive between the final activity check and the quit request.

On an Apple Silicon Mac, the ZIP was extracted, the app launched, and the bundled helper detected a staged update and active work. First-time setup and a complete ChatGPT update and relaunch on a fresh installation remain unverified, as does execution on Intel hardware.

## Build

Build on macOS with the Xcode Command Line Tools. Use an absolute path to a new ZIP file.

```sh
./distribution/build.sh "$PWD/Codex-Idle-Update-preview.zip"
```

For distribution, set `DEVELOPER_ID_APPLICATION` to the signing identity. Follow [Apple's notarization instructions](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution/) before sharing the signed build.

## License

[MIT License](LICENSE)
