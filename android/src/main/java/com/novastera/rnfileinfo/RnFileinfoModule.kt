package com.novastera.rnfileinfo

import com.facebook.react.bridge.*
import com.facebook.react.module.annotations.ReactModule
import com.novastera.rnfileinfo.download.*
import java.io.File
import java.lang.ref.WeakReference

@ReactModule(name = RnFileinfoModule.NAME)
class RnFileinfoModule(private val reactContext: ReactApplicationContext) : NativeRnFileinfoSpec(reactContext) {

    companion object {
        const val NAME = "RnFileinfo"
    }

    // Lazy-init download queue — only created when first download starts
    private var downloadQueue: DownloadQueue? = null

    private fun getOrCreateQueue(): DownloadQueue {
        if (downloadQueue == null) {
            downloadQueue = DownloadQueue(WeakReference(reactContext))
        }
        return downloadQueue!!
    }

    override fun getName(): String = NAME

    // ════════════════════════════════════════════════════════════════
    // PATH HELPERS
    // ════════════════════════════════════════════════════════════════

    private fun cleanPath(path: String): String {
        return if (path.startsWith("file://")) {
            path.substring(7)
        } else {
            path
        }
    }

    // ════════════════════════════════════════════════════════════════
    // FILE INFO METHODS (existing)
    // ════════════════════════════════════════════════════════════════

    override fun getFileInfo(path: String, promise: Promise) {
        try {
            val cleanedPath = cleanPath(path)
            val file = File(cleanedPath)

            if (!file.exists()) {
                promise.reject("FILE_NOT_FOUND", "File not found: $path")
                return
            }

            val fileInfo = WritableNativeMap().apply {
                putString("path", file.absolutePath)
                putString("name", file.name)
                putDouble("size", file.length().toDouble())
                putBoolean("isFile", file.isFile)
                putBoolean("isDirectory", file.isDirectory)
                putDouble("createdAt", file.lastModified().toDouble())
                putDouble("modifiedAt", file.lastModified().toDouble())
            }

            promise.resolve(fileInfo)
        } catch (e: Exception) {
            promise.reject("UNKNOWN_ERROR", "Unexpected error: ${e.message}", e)
        }
    }

    override fun getDirectoryInfo(path: String, options: ReadableMap?, promise: Promise) {
        try {
            val cleanedPath = cleanPath(path)
            val file = File(cleanedPath)

            if (!file.exists()) {
                promise.reject("DIRECTORY_NOT_FOUND", "Directory not found: $path")
                return
            }

            if (!file.isDirectory) {
                promise.reject("NOT_A_DIRECTORY", "Path is not a directory: $path")
                return
            }

            val recursive = if (options?.hasKey("recursive") == true) options.getBoolean("recursive") else false
            val includeHidden = if (options?.hasKey("includeHidden") == true) options.getBoolean("includeHidden") else false
            val maxDepth = if (options?.hasKey("maxDepth") == true) options.getInt("maxDepth") else Int.MAX_VALUE

            val fileInfos = mutableListOf<WritableMap>()
            scanDirectory(file, fileInfos, recursive, includeHidden, maxDepth, 0)

            val result = WritableNativeArray()
            fileInfos.forEach { result.pushMap(it) }
            promise.resolve(result)
        } catch (e: Exception) {
            promise.reject("UNKNOWN_ERROR", "Unexpected error: ${e.message}", e)
        }
    }

    private fun scanDirectory(
        directory: File,
        fileInfos: MutableList<WritableMap>,
        recursive: Boolean,
        includeHidden: Boolean,
        maxDepth: Int,
        currentDepth: Int
    ) {
        if (currentDepth >= maxDepth) return

        val files = directory.listFiles() ?: return

        val MAX_FILES_PER_BATCH = 1000
        if (files.size > MAX_FILES_PER_BATCH) {
            for (i in files.indices step MAX_FILES_PER_BATCH) {
                val endIndex = minOf(i + MAX_FILES_PER_BATCH, files.size)
                val batch = files.sliceArray(i until endIndex)
                processFileBatch(batch, fileInfos, recursive, includeHidden, maxDepth, currentDepth)
            }
            return
        }

        for (file in files) {
            if (!includeHidden && file.name.startsWith(".")) continue

            val fileInfo = WritableNativeMap().apply {
                putString("path", file.absolutePath)
                putString("name", file.name)
                putDouble("size", file.length().toDouble())
                putBoolean("isFile", file.isFile)
                putBoolean("isDirectory", file.isDirectory)
                putDouble("createdAt", file.lastModified().toDouble())
                putDouble("modifiedAt", file.lastModified().toDouble())
            }

            fileInfos.add(fileInfo)

            if (recursive && file.isDirectory) {
                scanDirectory(file, fileInfos, recursive, includeHidden, maxDepth, currentDepth + 1)
            }
        }
    }

    private fun processFileBatch(
        files: Array<File>,
        fileInfos: MutableList<WritableMap>,
        recursive: Boolean,
        includeHidden: Boolean,
        maxDepth: Int,
        currentDepth: Int
    ) {
        for (file in files) {
            if (!includeHidden && file.name.startsWith(".")) continue

            val fileInfo = WritableNativeMap().apply {
                putString("path", file.absolutePath)
                putString("name", file.name)
                putDouble("size", file.length().toDouble())
                putBoolean("isFile", file.isFile)
                putBoolean("isDirectory", file.isDirectory)
                putDouble("createdAt", file.lastModified().toDouble())
                putDouble("modifiedAt", file.lastModified().toDouble())
            }

            fileInfos.add(fileInfo)

            if (recursive && file.isDirectory) {
                scanDirectory(file, fileInfos, recursive, includeHidden, maxDepth, currentDepth + 1)
            }
        }
    }

    override fun exists(path: String, promise: Promise) {
        try {
            val cleanedPath = cleanPath(path)
            val file = File(cleanedPath)
            promise.resolve(file.exists())
        } catch (e: Exception) {
            promise.reject("UNKNOWN_ERROR", "Unexpected error: ${e.message}", e)
        }
    }

    override fun isFile(path: String, promise: Promise) {
        try {
            val cleanedPath = cleanPath(path)
            val file = File(cleanedPath)
            promise.resolve(file.exists() && file.isFile)
        } catch (e: Exception) {
            promise.reject("UNKNOWN_ERROR", "Unexpected error: ${e.message}", e)
        }
    }

    override fun isDirectory(path: String, promise: Promise) {
        try {
            val cleanedPath = cleanPath(path)
            val file = File(cleanedPath)
            promise.resolve(file.exists() && file.isDirectory)
        } catch (e: Exception) {
            promise.reject("UNKNOWN_ERROR", "Unexpected error: ${e.message}", e)
        }
    }

    // ════════════════════════════════════════════════════════════════
    // DOWNLOAD MANAGER METHODS
    // ════════════════════════════════════════════════════════════════

    override fun startDownload(
        downloadId: String,
        url: String,
        destinationPath: String,
        headers: ReadableMap,
        resumeData: String?,
        promise: Promise
    ) {
        try {
            val cleanedDest = cleanPath(destinationPath)

            // Path traversal prevention
            if (cleanedDest.contains("..")) {
                promise.reject("FILE_WRITE_ERROR", "Invalid destination path: contains '..'")
                return
            }

            // Convert ReadableMap headers to Map<String, String>
            val headerMap = mutableMapOf<String, String>()
            val iterator = headers.keySetIterator()
            while (iterator.hasNextKey()) {
                val key = iterator.nextKey()
                headerMap[key] = headers.getString(key) ?: ""
            }

            val task = DownloadTask().apply {
                id = downloadId
                this.url = url
                this.destinationPath = cleanedDest
                this.headers = headerMap
                status = DownloadStatus.STARTING
            }

            DownloadRegistry.register(task)
            DownloadRegistry.persistMetadata(task)
            getOrCreateQueue().enqueue(task)

            promise.resolve(null)
        } catch (e: Exception) {
            promise.reject("START_ERROR", "Failed to start download: ${e.message}", e)
        }
    }

    override fun pauseDownload(downloadId: String, promise: Promise) {
        try {
            val task = DownloadRegistry.get(downloadId)
            if (task == null || task.status != DownloadStatus.DOWNLOADING) {
                promise.resolve("")
                return
            }

            getOrCreateQueue().pause(downloadId)
            task.status = DownloadStatus.PAUSED
            DownloadRegistry.persistMetadata(task)

            promise.resolve("") // Android doesn't have iOS-style resume data blobs
        } catch (e: Exception) {
            promise.reject("PAUSE_ERROR", "Failed to pause download: ${e.message}", e)
        }
    }

    override fun resumeDownload(downloadId: String, resumeData: String?, promise: Promise) {
        try {
            val task = DownloadRegistry.get(downloadId)
            if (task == null) {
                promise.reject("NOT_FOUND", "Download not found: $downloadId")
                return
            }

            // File size consistency check
            val destFile = File(task.destinationPath)
            if (destFile.exists()) {
                val actualSize = destFile.length()
                if (actualSize != task.downloadedBytes) {
                    if (actualSize < task.downloadedBytes) {
                        task.downloadedBytes = actualSize
                    } else {
                        destFile.delete()
                        task.downloadedBytes = 0
                    }
                }
            }

            task.status = DownloadStatus.STARTING
            task.retryCount = 0
            getOrCreateQueue().enqueue(task)

            promise.resolve(null)
        } catch (e: Exception) {
            promise.reject("RESUME_ERROR", "Failed to resume download: ${e.message}", e)
        }
    }

    override fun cancelDownload(downloadId: String, promise: Promise) {
        try {
            getOrCreateQueue().cancel(downloadId)
            promise.resolve(null)
        } catch (e: Exception) {
            promise.reject("CANCEL_ERROR", "Failed to cancel download: ${e.message}", e)
        }
    }

    override fun restoreDownloads(promise: Promise) {
        try {
            val snapshots = WritableNativeArray()

            // Scan common download directories for .download files
            val searchDirs = listOfNotNull(
                reactContext.filesDir,
                reactContext.cacheDir,
                reactContext.externalFilesDir(null),
            )

            for (dir in searchDirs) {
                scanForMetadata(dir, snapshots)
            }

            promise.resolve(snapshots)
        } catch (e: Exception) {
            promise.reject("RESTORE_ERROR", "Failed to restore downloads: ${e.message}", e)
        }
    }

    private fun scanForMetadata(directory: File, snapshots: WritableNativeArray) {
        directory.walkTopDown().forEach { file ->
            if (file.isFile && file.name.endsWith(".download") && !file.name.endsWith(".download.tmp")) {
                val task = DownloadRegistry.loadMetadata(file)
                if (task != null) {
                    DownloadRegistry.register(task)

                    val snapshot = WritableNativeMap().apply {
                        putString("downloadId", task.id)
                        putString("url", task.url)
                        putString("fileUri", task.destinationPath)
                        putDouble("downloadedBytes", task.downloadedBytes.toDouble())
                        putDouble("totalBytes", task.totalBytes.toDouble())
                        putString("etag", task.etag ?: "")
                        putString("lastModified", task.lastModified ?: "")
                        putString("status", task.status.value)

                        val headersMap = WritableNativeMap()
                        task.headers.forEach { (k, v) -> headersMap.putString(k, v) }
                        putMap("headers", headersMap)
                    }

                    snapshots.pushMap(snapshot)
                }
            }
        }
    }

    override fun getDownloadStatus(downloadId: String, promise: Promise) {
        try {
            val task = DownloadRegistry.get(downloadId)
            if (task == null) {
                promise.reject("NOT_FOUND", "Download not found: $downloadId")
                return
            }

            val status = WritableNativeMap().apply {
                putString("downloadId", task.id)
                putString("status", task.status.value)
                putDouble("downloadedBytes", task.downloadedBytes.toDouble())
                putDouble("totalBytes", task.totalBytes.toDouble())
                putDouble("progress", task.progress)
            }

            promise.resolve(status)
        } catch (e: Exception) {
            promise.reject("STATUS_ERROR", "Failed to get download status: ${e.message}", e)
        }
    }

    // ─── Event Emitter Support ─────────────────────────────────────

    override fun addListener(eventName: String?) {
        // Required for NativeEventEmitter — no-op on Android
    }

    override fun removeListeners(count: Double) {
        // Required for NativeEventEmitter — no-op on Android
    }

    // ─── Lifecycle Cleanup ─────────────────────────────────────────

    override fun onCatalystInstanceDestroy() {
        downloadQueue?.shutdown()
        downloadQueue = null
        DownloadRegistry.clear()
    }
}
