package com.brite.zipimageviewer.data;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/** Test APK only. Java keeps this separate provider process independent of the target's Kotlin runtime. */
public final class ImportTestProvider extends ContentProvider {
    private final ConcurrentHashMap<String, AtomicInteger> opens = new ConcurrentHashMap<>();
    private final Set<String> revoked = ConcurrentHashMap.newKeySet();
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "application/zip"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sortOrder) {
        MatrixCursor cursor = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        cursor.addRow(new Object[]{uri.getLastPathSegment(), null});
        return cursor;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new IllegalArgumentException("Read only");
        if ("denied".equals(uri.getPathSegments().get(0))) throw new SecurityException("Fixture permission denied");
        String key = uri.toString();
        opens.computeIfAbsent(key, ignored -> new AtomicInteger()).incrementAndGet();
        if (revoked.contains(key)) throw new FileNotFoundException("Source is now offline");
        String name = uri.getLastPathSegment();
        if (!"encrypted.zip".equals(name) && !"plain.zip".equals(name) && !"unicode-password.7z".equals(name)) {
            throw new FileNotFoundException("Unknown fixture");
        }
        File file = new File(getContext().getCacheDir(), "import-provider-" + uri.getPathSegments().get(0) + "-" + name);
        try (InputStream input = getContext().getAssets().open("archive-fixtures/" + name);
             FileOutputStream output = new FileOutputStream(file)) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
        } catch (IOException error) {
            FileNotFoundException wrapped = new FileNotFoundException(error.getMessage());
            wrapped.initCause(error);
            throw wrapped;
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Bundle call(String method, String arg, Bundle extras) {
        if (arg == null) throw new IllegalArgumentException("Missing fixture URI");
        if ("revoke".equals(method)) revoked.add(arg);
        AtomicInteger count = opens.get(arg);
        Bundle result = new Bundle();
        result.putInt("opens", count == null ? 0 : count.get());
        return result;
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException("Read only"); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException("Read only"); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException("Read only"); }
}
