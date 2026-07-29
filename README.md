# Githulhu

Githulhu is a focused GitHub client for iPhone. It clones repositories into
user-selected Files locations and provides status, diff, staging, commit,
pull, push, conflict resolution, and branch management without bundling a
code editor.

## Requirements

- Xcode 16+
- iOS 17+
- A GitHub OAuth App

Open `Githulhu.xcodeproj`, select a Development Team, and place the OAuth app's
client ID and client secret in the `GITHUB_CLIENT_ID` and
`GITHUB_CLIENT_SECRET` build settings. OAuth tokens are stored in the iOS
Keychain; SwiftData stores repository bookmarks and operation history only.

Register the OAuth App with `githulhu://oauth/callback` as its **Authorization
callback URL**. Device Flow is not used and should remain disabled. Githulhu
opens GitHub in the system authentication browser and uses authorization code
flow with PKCE.

For the `Build Sideload IPA` GitHub Actions workflow, add the OAuth app client
ID as a repository Actions variable named `GITHULHU_CLIENT_ID` under
**Settings → Secrets and variables → Actions → Variables**. The client ID is
public application metadata. Add the OAuth app client secret separately as an
Actions repository **secret** named `GITHULHU_CLIENT_SECRET`; never commit it to
the repository. Existing `GITHULU_CLIENT_ID` and `GITHULU_CLIENT_SECRET`
settings remain accepted by the build workflow during the rename.

GitHub currently requires a client secret for authorization-code token
exchange, even with PKCE. Native apps cannot keep an embedded client secret
confidential, so treat it as an application identifier rather than authority:
it cannot access a user without that user completing authorization. Rotate it
from the OAuth App settings and rebuild the app if it is abused.

The app can only access folders explicitly granted through the Files picker.

## Safety boundaries

- Pull merges; it never rebases.
- Force push and reset are not exposed.
- A branch can only be deleted after it has been merged into the current
  branch.
- Binary and oversized conflicts are reported but cannot be edited in-app.
