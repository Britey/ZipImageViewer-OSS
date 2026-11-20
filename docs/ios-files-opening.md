# Opening archives from iOS Files

Zip Image Viewer registers as a viewer for ZIP, CBZ, and 7z files in both Debug
and Release. In Files, touch and hold an archive and choose **Open With → Zip
Image Viewer**. On iOS versions that expose app destinations through sharing,
use **Share** and select Zip Image Viewer from the app row (or **More**).

The scene receives files both when the app launches and when it is already
running. Requests arriving during startup wait for the native library and its
presenter. Opening another archive closes the current reader through its normal
progress-saving path, then imports the requested file. Reopening an unchanged
source uses the existing cache and saved reading position.

Opening through Files retains the same extracted pages and previews as the
in-app picker. Close and relaunch the app, then reopen the library entry without
needing permission to the source again, even if the source has moved or been
deleted. Ordinary cache eviction/removal still applies. An archive larger than
the configured cache budget is explicitly marked temporary and is removed after
its reader and image work close; reopening it requires selecting its source.

The existing coordinated, security-scoped import pipeline reads a private copy;
external originals are never edited or deleted. Non-in-place copies delivered to
the app’s own `Documents/Inbox` are removed after import, failure, or cancellation.
In-place files and sources outside that Inbox are preserved. A multi-file
delivery opens the first supported archive in URL order; additional items are
ignored and their app-owned Inbox copies are removed. Access is retained while a
startup request waits and through import completion, failure, or cancellation. A
failed library bootstrap releases the pending request, so the user can retry
after recovery. Encrypted archives use the existing password prompt. Unsupported, missing, or unreadable files show
an error. A request made during another import, a document picker, or another
reserved operation shows a busy error; finish that operation and open the file
again from Files.

This adds document viewing, not a Files storage provider or third-party browser
settings. No broad `public.data` document handler or file-sharing access to the
app's private library is registered.

## Verification

Dated build/test evidence and simulator troubleshooting belong in
the [macOS guide](react-native/MACOS.md) for the Xcode build and simulator test commands.
