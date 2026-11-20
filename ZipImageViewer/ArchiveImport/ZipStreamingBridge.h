#pragma once
@import ZipArchive;

// Narrow declarations for the minizip compatibility API exported by pinned
// SSZipArchive 2.6.0. The public package exports the info struct but not this API.
// Keep these signatures checked against SSZipArchive/minizip/mz_compat.h on upgrades.
void *unzOpen64(const void *path);
int unzClose(void *file);
int unzGoToFirstFile(void *file);
int unzGoToNextFile(void *file);
int unzGetCurrentFileInfo64(void *file, unz_file_info64 *info, char *name,
    unsigned long nameSize, void *extra, unsigned long extraSize, char *comment, unsigned long commentSize);
int64_t unzGetOffset64(void *file);
int unzSetOffset64(void *file, int64_t offset);
int unzOpenCurrentFilePassword(void *file, const char *password);
int unzReadCurrentFile(void *file, void *buffer, uint32_t length);
int unzCloseCurrentFile(void *file);
