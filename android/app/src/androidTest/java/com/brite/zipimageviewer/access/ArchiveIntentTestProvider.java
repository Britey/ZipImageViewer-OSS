package com.brite.zipimageviewer.access;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.InputStream;
import java.io.FileOutputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;

// Runs in the test APK's own process, which cannot load Kotlin from the target APK.
public class ArchiveIntentTestProvider extends ContentProvider {
    private final AtomicInteger opens = new AtomicInteger();
    @Override public boolean onCreate() { return true; }
    private String fixture(Uri uri) throws FileNotFoundException {
        if ("one".equals(uri.getLastPathSegment())) return "plain.cbz";
        if ("two".equals(uri.getLastPathSegment())) return "plain.zip";
        if ("encrypted".equals(uri.getLastPathSegment())) return "encrypted.zip";
        throw new FileNotFoundException("Unknown test fixture");
    }
    @Override public synchronized ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Read only");
        String name = fixture(uri);
        File file = new File(getContext().getCacheDir(), name);
        if (!file.exists()) {
            try (InputStream input = getContext().getAssets().open("archive-fixtures/" + name);
                 FileOutputStream output = new FileOutputStream(file)) {
                byte[] bytes = new byte[8192];
                int count;
                while ((count = input.read(bytes)) != -1) output.write(bytes, 0, count);
            } catch (IOException error) { throw new FileNotFoundException(error.getMessage()); }
        }
        opens.incrementAndGet();
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        String[] columns = projection == null ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
        MatrixCursor cursor = new MatrixCursor(columns);
        Object[] row = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) {
                try { row[i] = "External " + fixture(uri); }
                catch (FileNotFoundException ignored) { row[i] = "Unknown archive"; }
            }
        }
        cursor.addRow(row);
        return cursor;
    }
    @Override public String getType(Uri uri) { return "application/octet-stream"; }
    @Override public Bundle call(String method, String arg, Bundle extras) {
        if ("reset".equals(method)) opens.set(0);
        Bundle result = new Bundle();
        result.putInt("opens", opens.get());
        return result;
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
