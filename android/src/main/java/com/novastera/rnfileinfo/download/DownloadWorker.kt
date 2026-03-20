package com.novastera.rnfileinfo.download

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactContext
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.io.File
import java.io.FileNotFoundException
import java.io.RandomAccessFile
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL

/**
 * Per-download worker thread using HttpURLConnection.
 * 32 KB buffer, throttled progress (250ms), checkpointed metadata (512KB / 1s).
 */
class DownloadWorker(
    private val task: DownloadTask,
    private val queue: DownloadQueue,
    private val contextRef: WeakReference<ReactContext>,
) : Runnable {

    companion object {
        private const val BUFFER_SIZE = 32 * 1024           // 32 KB
        private const val PROGRESS_INTERVAL_MS = 250L
        private const val CHECKPOINT_BYTES = 512 * 1024L    // 512 KB
    }

    @Volatile
    private var cancelled = false

    override fun run() {
        var connection: HttpURLConnection? = null
        try {
            connection = buildConnection()
            val responseCode = connection.responseCode

            when (responseCode) {
                HttpURLConnection.HTTP_PARTIAL -> {  // 206
                    captureHeaders(connection)
                    resumeWrite(connection)
                }
                HttpURLConnection.HTTP_OK -> {       // 200 — server reset or no range support
                    captureHeaders(connection)
                    // If we had partial data but got 200, server ignored Range → restart
                    if (task.downloadedBytes > 0) {
                        restartFromZero()
                    }
                    resumeWrite(connection)
                }
                in 400..499 -> {
                    throw HttpException(responseCode, connection.responseMessage ?: "Client error")
                }
                in 500..599 -> {
                    throw HttpException(responseCode, connection.responseMessage ?: "Server error")
                }
                else -> {
                    throw HttpException(responseCode, connection.responseMessage ?: "Unexpected response")
                }
            }
        } catch (e: InterruptedException) {
            // Pause requested — state already saved
            task.status = DownloadStatus.PAUSED
            DownloadRegistry.persistMetadata(task)
        } catch (e: Exception) {
            handleError(e)
        } finally {
            connection?.disconnect()
            queue.onDownloadFinished(task.id)
        }
    }

    fun pause() {
        cancelled = true
    }

    // ─── Connection Setup ──────────────────────────────────────────

    private fun buildConnection(): HttpURLConnection {
        val url = URL(task.url)
        val conn = url.openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        conn.instanceFollowRedirects = true
        conn.setRequestProperty("Accept-Encoding", "identity") // disable gzip for range requests

        task.headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }

        // Resume headers
        if (task.downloadedBytes > 0) {
            conn.setRequestProperty("Range", "bytes=${task.downloadedBytes}-")
            task.etag?.let { conn.setRequestProperty("If-Range", it) }
        }

        conn.connect()
        return conn
    }

    private fun captureHeaders(connection: HttpURLConnection) {
        connection.getHeaderField("ETag")?.let { task.etag = it }
        connection.getHeaderField("Last-Modified")?.let { task.lastModified = it }
    }

    // ─── Write Loop ────────────────────────────────────────────────

    private fun resumeWrite(connection: HttpURLConnection) {
        // Parse total bytes from Content-Range or Content-Length
        val totalFromHeader = connection.getHeaderField("Content-Range")
            ?.substringAfterLast('/')?.toLongOrNull()
            ?: connection.contentLengthLong.let {
                if (task.downloadedBytes > 0) task.downloadedBytes + it else it
            }

        if (totalFromHeader > 0) task.totalBytes = totalFromHeader

        // Pre-allocate if total size known and starting fresh
        if (task.downloadedBytes == 0L && task.totalBytes > 0) {
            preallocate(task.destinationPath, task.totalBytes)
        }

        val destFile = File(task.destinationPath)
        destFile.parentFile?.mkdirs()

        val input = connection.inputStream.buffered(BUFFER_SIZE)
        val output = RandomAccessFile(destFile, "rw")

        try {
            output.seek(task.downloadedBytes)
            val buffer = ByteArray(BUFFER_SIZE) // allocated once, reused
            var bytesRead: Int
            var lastProgressMs = System.currentTimeMillis()
            var lastCheckpointBytes = task.downloadedBytes
            var lastCheckpointMs = lastProgressMs

            task.status = DownloadStatus.DOWNLOADING
            DownloadRegistry.persistMetadata(task)

            while (input.read(buffer).also { bytesRead = it } != -1) {
                if (Thread.currentThread().isInterrupted || cancelled) {
                    throw InterruptedException("Download paused")
                }

                output.write(buffer, 0, bytesRead)
                task.downloadedBytes += bytesRead

                val now = System.currentTimeMillis()

                // Checkpoint metadata
                if (task.downloadedBytes - lastCheckpointBytes >= CHECKPOINT_BYTES ||
                    now - lastCheckpointMs >= 1000L
                ) {
                    lastCheckpointBytes = task.downloadedBytes
                    lastCheckpointMs = now
                    DownloadRegistry.persistMetadata(task)
                }

                // Throttled progress event
                if (now - lastProgressMs >= PROGRESS_INTERVAL_MS) {
                    lastProgressMs = now
                    emitProgress()
                }
            }

            completeDownload()
        } finally {
            output.close()
            input.close()
        }
    }

    private fun preallocate(path: String, size: Long) {
        try {
            RandomAccessFile(path, "rw").use { it.setLength(size) }
        } catch (_: Exception) { /* non-fatal */ }
    }

    private fun restartFromZero() {
        File(task.destinationPath).delete()
        task.downloadedBytes = 0
        task.etag = null
        task.lastModified = null
        DownloadRegistry.persistMetadata(task)
    }

    // ─── Completion ────────────────────────────────────────────────

    private fun completeDownload() {
        val actualSize = File(task.destinationPath).length()
        if (task.totalBytes > 0 && actualSize != task.totalBytes) {
            handleError(Exception("Size mismatch: got $actualSize expected ${task.totalBytes}"))
            return
        }
        task.status = DownloadStatus.COMPLETED
        DownloadRegistry.deleteMetadata(task)
        DownloadRegistry.remove(task.id)

        val context = contextRef.get() ?: return
        val params = Arguments.createMap().apply {
            putString("downloadId", task.id)
            putString("uri", task.destinationPath)
        }
        context.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit("downloadComplete", params)
    }

    // ─── Progress Event ────────────────────────────────────────────

    private fun emitProgress() {
        val context = contextRef.get() ?: return
        val params = Arguments.createMap().apply {
            putString("downloadId", task.id)
            putDouble("bytesWritten", task.downloadedBytes.toDouble())
            putDouble("totalBytes", task.totalBytes.toDouble())
            putDouble("progress", task.progress)
        }
        context.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit("downloadProgress", params)
    }

    // ─── Error Handling ────────────────────────────────────────────

    private fun handleError(e: Exception) {
        val code = errorCode(e)
        val isRetryable = code == "NETWORK_ERROR" || code == "TIMEOUT" ||
            (e is HttpException && e.statusCode in 500..599)

        if (isRetryable && task.retryCount < 5) {
            task.retryCount++
            task.status = DownloadStatus.RETRYING
            DownloadRegistry.persistMetadata(task)

            // Exponential backoff: 1s, 2s, 4s, 8s, 16s
            val delayMs = (1L shl (task.retryCount - 1)) * 1000L
            try {
                Thread.sleep(delayMs)
            } catch (_: InterruptedException) {
                task.status = DownloadStatus.PAUSED
                DownloadRegistry.persistMetadata(task)
                return
            }

            if (!cancelled) {
                run() // retry
            }
            return
        }

        task.status = DownloadStatus.FAILED
        DownloadRegistry.persistMetadata(task)

        val context = contextRef.get() ?: return
        val params = Arguments.createMap().apply {
            putString("downloadId", task.id)
            putString("errorCode", code)
            putString("message", e.message ?: "Unknown error")
        }
        context.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit("downloadError", params)
    }

    private fun errorCode(e: Exception): String = when (e) {
        is HttpException -> "HTTP_ERROR"
        is InterruptedException -> "CANCELLED"
        is FileNotFoundException -> "FILE_WRITE_ERROR"
        is SocketTimeoutException -> "TIMEOUT"
        else -> "NETWORK_ERROR"
    }
}

/**
 * Simple HTTP exception with status code.
 */
class HttpException(val statusCode: Int, message: String) : Exception("HTTP $statusCode: $message")
