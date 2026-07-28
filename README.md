# Githulu

Githulu is a focused GitHub client for iPhone. It clones repositories into
user-selected Files locations and provides status, diff, staging, commit,
pull, push, conflict resolution, and branch management without bundling a
code editor.

## Requirements

- Xcode 16+
- iOS 17+
- A GitHub OAuth App with Device Flow enabled

Open `Githulu.xcodeproj`, select a Development Team, and place the OAuth app's
client ID in the `GITHUB_CLIENT_ID` build setting. OAuth tokens are stored in
the iOS Keychain; SwiftData stores repository bookmarks and operation history
only.

The app can only access folders explicitly granted through the Files picker.

## Safety boundaries

- Pull merges; it never rebases.
- Force push and reset are not exposed.
- A branch can only be deleted after it has been merged into the current
  branch.
- Binary and oversized conflicts are reported but cannot be edited in-app.
