# Opening local and network archives

Version 0.4.0-preview supports three ways to open an archive. Your selected
file app or document provider handles network connections and SMB credentials.
ZipImageViewer reads a granted file into private staging, extracts it and keeps
its existing managed image cache. It does not create a permanent Downloads copy
or change the original archive.

## System files

Open archive uses Android's system document picker by default. Install and
configure a network DocumentsProvider to expose a share in its navigation menu.
Merely installing an SMB file manager does not guarantee that it supplies a
DocumentsProvider. Configure your server, share and username/password in the
provider first, then return to ZipImageViewer and select the archive.

## Choose or remember a file app

Use the library toolbar's three-dot **Open archive using another picker** button
for a one-time choice. Choose an installed file app that supports Android file
selection. Select **Remember this picker** to make it the default.

You can also change **Settings → Opening archives → File picker** to System
files, Choose a file app each time, or an installed compatible app. The main
Open archive button uses this setting. If the app is removed or disabled, choose
another picker in the recovery dialog.

**Show all files** is on by default because providers sometimes report archives
as generic binary files. You may turn it off to request archive MIME filtering;
turn it back on if ZIP, CBZ or 7z files disappear. All selected files still pass
archive validation before opening.

## Share and Open with

In a file manager, browse to a local file or authenticated network share and
choose **Open with → ZipImageViewer**, or **Share → ZipImageViewer**. Send one
archive at a time. The app supports ZIP, CBZ and 7z MIME types, common aliases
and generic binary files. It validates the actual archive format, so unrelated
binary files are rejected. Some senders use unsupported MIME types or fail to
grant read access; use the picker route if the app is missing or cannot read it.
Sharing a textual SMB URL is not the same as sharing the file.

An incoming archive replaces the current reader only after import succeeds.
If another import or password prompt is active, finish or cancel it, then resend
the new archive. Multiple-file sharing is not advertised or silently truncated.

## Transfers, passwords and storage

The entire archive is staged before reading. Progress reports bytes transferred
and a percentage when size is available. Password retries reuse the same staged
archive, including when the original provider is no longer reachable. Passwords
are not saved. Cancel or dismiss the password dialog to discard staging.

Network copy cancellation signals the provider and closes the viewer's owned
descriptor. A 60-second inactivity watchdog attempts to stop a stalled provider;
a provider blocked inside its own implementation may take longer to return.
Keep the app in the foreground for long transfers. If Android kills the process,
reselect the source; abandoned staging is cleaned on next startup.

The retained image cache behaves as before: it is bounded by the configured
byte/count limits and may keep images indefinitely while below those limits.
Archives larger than the retained budget use the existing temporary-reader
behavior. This release does not add a new remove-on-close setting. Cached images
from encrypted archives are decrypted in app-private storage. Clearing the
library removes the viewer's copies, not any separate cache a file manager keeps.

## Implementation and verification

The viewer still has no INTERNET or broad storage permission. System selection
uses ACTION_OPEN_DOCUMENT; alternate apps use ACTION_GET_CONTENT with
CATEGORY_OPENABLE. Scoped package queries list compatible pickers. Neither route
requires a permanent URI grant because import creates the viewer's private copy.
External requests use ACTION_VIEW or ACTION_SEND with a single content URI;
raw filesystem paths and network addresses are rejected. The single activity
receives subsequent intents through onNewIntent and does not replay launches on
configuration changes.

Instrumentation covers intent parsing/resolution, cold and warm opening,
configuration changes, missing permissions, invalid replacement preservation,
provider-backed password retries, source revocation and staging cleanup. Run
`testDebugUnitTest`, `connectedDebugAndroidTest` and `lintDebug` from `android/`.
Actual network-provider and OEM behavior also requires interoperability tests;
see the delivered validation report for the tested apps/devices.
