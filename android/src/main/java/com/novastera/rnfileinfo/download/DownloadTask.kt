package com.novastera.rnfileinfo.download

/**
 * Download status states matching the spec state machine.
 */
enum class DownloadStatus(val value: String) {
    IDLE("idle"),
    STARTING("starting"),
    DOWNLOADING("downloading"),
    PAUSED("paused"),
    RETRYING("retrying"),
    COMPLETED("completed"),
    FAILED("failed"),
    CANCELLED("cancelled");

    companion object {
        fun fromString(s: String): DownloadStatus =
            entries.firstOrNull { it.value == s } ?: IDLE
    }
}

/**
 * Mutable download task model.
 * NOT a data class — avoids copy() duplicating large maps.
 * All byte counters are Long (64-bit) to support files > 2 GB.
 */
class DownloadTask {
    var id: String = ""
    var url: String = ""
    var destinationPath: String = ""
    var headers: Map<String, String> = emptyMap()
    var status: DownloadStatus = DownloadStatus.IDLE
    var downloadedBytes: Long = 0L
    var totalBytes: Long = -1L
    var etag: String? = null
    var lastModified: String? = null
    var retryCount: Int = 0

    val metadataPath: String get() = "$destinationPath.download"
    val tmpMetadataPath: String get() = "$destinationPath.download.tmp"

    val progress: Double
        get() = if (totalBytes > 0) downloadedBytes.toDouble() / totalBytes else -1.0
}
