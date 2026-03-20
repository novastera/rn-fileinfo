package com.novastera.rnfileinfo.download

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap

/**
 * Thread-safe singleton registry for active download tasks.
 * Handles metadata persistence with atomic writes (tmp → fsync → rename).
 */
object DownloadRegistry {

    private val activeTasks = ConcurrentHashMap<String, DownloadTask>()

    fun register(task: DownloadTask) {
        activeTasks[task.id] = task
    }

    fun get(id: String): DownloadTask? = activeTasks[id]

    fun remove(id: String) {
        activeTasks.remove(id)
    }

    fun allActive(): List<DownloadTask> = activeTasks.values.toList()

    fun clear() {
        activeTasks.clear()
    }

    // ─── Metadata Persistence ──────────────────────────────────────

    /**
     * Atomic write: serialize → write to .tmp → fsync → rename to final
     */
    fun persistMetadata(task: DownloadTask) {
        try {
            val json = JSONObject().apply {
                put("id", task.id)
                put("url", task.url)
                put("fileUri", task.destinationPath)
                put("downloadedBytes", task.downloadedBytes)
                put("totalBytes", task.totalBytes)
                put("etag", task.etag ?: "")
                put("lastModified", task.lastModified ?: "")
                put("status", task.status.value)
                put("headers", JSONObject(task.headers))
                put("createdAt", System.currentTimeMillis())
                put("updatedAt", System.currentTimeMillis())
            }

            val tmpFile = File(task.tmpMetadataPath)
            val finalFile = File(task.metadataPath)

            // Ensure parent directory exists
            tmpFile.parentFile?.mkdirs()

            // Write to tmp file
            FileOutputStream(tmpFile).use { fos ->
                fos.write(json.toString().toByteArray(Charsets.UTF_8))
                fos.fd.sync() // fsync
            }

            // Atomic rename
            tmpFile.renameTo(finalFile)
        } catch (_: Exception) {
            // Non-fatal — metadata will be reconstructed on next checkpoint
        }
    }

    fun deleteMetadata(task: DownloadTask) {
        try {
            File(task.metadataPath).delete()
            File(task.tmpMetadataPath).delete()
        } catch (_: Exception) { /* non-fatal */ }
    }

    /**
     * Load metadata from a .download JSON file.
     * Returns null if the file is invalid or the data file is missing.
     */
    fun loadMetadata(metadataFile: File): DownloadTask? {
        return try {
            val jsonStr = metadataFile.readText(Charsets.UTF_8)
            val json = JSONObject(jsonStr)

            val fileUri = json.optString("fileUri", "")
            val dataFile = File(fileUri)

            // Data file must exist
            if (fileUri.isEmpty() || !dataFile.exists()) {
                metadataFile.delete()
                return null
            }

            val task = DownloadTask().apply {
                id = json.optString("id", "")
                url = json.optString("url", "")
                destinationPath = fileUri
                downloadedBytes = json.optLong("downloadedBytes", 0L)
                totalBytes = json.optLong("totalBytes", -1L)
                etag = json.optString("etag", "").takeIf { it.isNotEmpty() }
                lastModified = json.optString("lastModified", "").takeIf { it.isNotEmpty() }
                status = DownloadStatus.PAUSED // always restore as paused

                // Parse headers
                val headersJson = json.optJSONObject("headers")
                headers = if (headersJson != null) {
                    val map = mutableMapOf<String, String>()
                    headersJson.keys().forEach { key ->
                        map[key] = headersJson.optString(key, "")
                    }
                    map
                } else {
                    emptyMap()
                }
            }

            // File size consistency check
            val actualSize = dataFile.length()
            if (actualSize != task.downloadedBytes) {
                if (actualSize < task.downloadedBytes) {
                    task.downloadedBytes = actualSize
                } else {
                    dataFile.delete()
                    task.downloadedBytes = 0
                }
            }

            if (task.id.isEmpty()) {
                metadataFile.delete()
                return null
            }

            task
        } catch (_: Exception) {
            metadataFile.delete()
            null
        }
    }
}
