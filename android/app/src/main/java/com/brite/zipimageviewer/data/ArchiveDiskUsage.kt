package com.brite.zipimageviewer.data

import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException

object ArchiveDiskUsage {
    fun allocatedBytes(file: File): Long? = try {
        val stat = Os.lstat(file.absolutePath)
        if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_blocks < 0 || stat.st_blocks > Long.MAX_VALUE / 512) null
        else stat.st_blocks * 512
    } catch (_: Exception) { null }

    fun requireRegularFile(file: File) {
        val stat = try { Os.lstat(file.absolutePath) } catch (error: Exception) { throw IOException("Cannot inspect extracted image ${file.name}", error) }
        if (!OsConstants.S_ISREG(stat.st_mode)) throw ImportFailure("Extracted image is not a regular file: ${file.name}")
    }

    fun directoryBytes(root: File): Long {
        var total = 0L
        fun visit(directory: File) {
            val children = directory.listFiles() ?: throw ImportFailure("Cached image directory could not be read.")
            for (file in children) {
                val stat = try { Os.lstat(file.absolutePath) } catch (error: Exception) { throw IOException("Cannot inspect cached storage", error) }
                when {
                    OsConstants.S_ISDIR(stat.st_mode) -> visit(file)
                    OsConstants.S_ISREG(stat.st_mode) -> {
                        val bytes = allocatedBytes(file) ?: stat.st_size
                        if (bytes < 0 || bytes > Long.MAX_VALUE - total) throw ImportFailure("Cached storage accounting overflowed.")
                        total += bytes
                    }
                    else -> throw ImportFailure("Cached storage contains a link or special file.")
                }
            }
        }
        visit(root)
        return total
    }
}
