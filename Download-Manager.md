# RNFileInfo — Native Download Manager
### Complete Design Specification for React Native TurboModules

> **Zero dependencies · Crash-safe · Resumable · Multi-GB · Parallel · iOS + Android**

---

## Table of Contents

1. [Goals & Constraints](#1-goals--constraints)
2. [Architecture Overview](#2-architecture-overview)
3. [TurboModule Interface](#3-turbomodule-interface)
4. [JS Public API](#4-js-public-api)
5. [State Machine](#5-state-machine)
6. [Core Data Model](#6-core-data-model)
7. [Task Registry](#7-task-registry)
8. [Metadata Persistence (Crash Safety)](#8-metadata-persistence-crash-safety)
9. [iOS Implementation](#9-ios-implementation)
10. [Android Implementation](#10-android-implementation)
11. [Parallel Download Scheduler](#11-parallel-download-scheduler)
12. [Resume Strategy & Validation](#12-resume-strategy--validation)
13. [Progress Events](#13-progress-events)
14. [Error Handling & Retry](#14-error-handling--retry)
15. [Crash Recovery on Startup](#15-crash-recovery-on-startup)
16. [Performance Rules](#16-performance-rules)
17. [Security & Safety Checks](#17-security--safety-checks)
18. [File Layout](#18-file-layout)
19. [Testing Plan](#19-testing-plan)
20. [Future Enhancements](#20-future-enhancements)
21. [Best Practices — React Native, Objective-C++ & Kotlin](#21-best-practices--react-native-objective-c--kotlin)

---

## 1. Goals & Constraints

| Requirement | Target |
|---|---|
| External dependencies | **0** |
| Binary size added | **0 KB** (system APIs only) |
| iOS networking | `URLSession` |
| Android networking | `HttpURLConnection` |
| Expo `DownloadResumable` compatibility | **Drop-in replacement** |
| Max file size | 10+ GB |
| Memory per download | < 50 KB |
| Concurrent downloads | Up to 6 |
| Crash recovery | Full (state file on disk) |
| Min Android API | 16+ |
| Min iOS | 13+ |

**Non-goals:**
- Segmented/chunked parallel downloading (out of scope v1)
- Background URLSession on iOS (future enhancement)

---

## 2. Architecture Overview

```
┌──────────────────────────────────────┐
│           JavaScript Layer           │
│  DownloadResumable  DownloadManager  │
└────────────────┬─────────────────────┘
                 │ TurboModule (JSI)
┌────────────────▼─────────────────────┐
│         NativeDownloadManager        │
│  (RNFileInfoDownloadManagerModule)   │
├──────────────────────────────────────┤
│  Task Registry  │  State Machine     │
│  Metadata Store │  Scheduler         │
├────────────┬─────────────────────────┤
│  iOS       │  Android               │
│  URLSession│  HttpURLConnection     │
│  Download  │  + ExecutorService     │
│  Task      │  + FileOutputStream    │
└────────────┴────────────────────────┘
```

**Key design principles:**
- Native side owns all network I/O and file writing
- JS side only calls methods and receives events
- State is persisted to disk — never rely on in-memory state for recovery
- Progress events are throttled before crossing the JSI bridge

---

## 3. TurboModule Interface

### Codegen Spec (`NativeDownloadManager.ts`)

```ts
import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export interface Spec extends TurboModule {
  // Lifecycle
  startDownload(
    downloadId: string,
    url: string,
    destinationPath: string,
    headers: { [key: string]: string },
    resumeData: string | null   // iOS resume blob (base64) or null
  ): Promise<void>;

  pauseDownload(downloadId: string): Promise<string>;  // returns resumeData (iOS) or ''

  resumeDownload(
    downloadId: string,
    resumeData: string | null
  ): Promise<void>;

  cancelDownload(downloadId: string): Promise<void>;

  // Recovery
  restoreDownloads(): Promise<DownloadSnapshotSpec[]>;

  // Queries
  getDownloadStatus(downloadId: string): Promise<DownloadStatusSpec>;
}

export interface DownloadSnapshotSpec {
  downloadId: string;
  url: string;
  fileUri: string;
  downloadedBytes: number;   // NOTE: JS number is safe up to 2^53, sufficient for 10 GB
  totalBytes: number;
  etag: string;
  lastModified: string;
  headers: { [key: string]: string };
  status: string;
}

export interface DownloadStatusSpec {
  downloadId: string;
  status: string;
  downloadedBytes: number;
  totalBytes: number;
  progress: number;          // 0.0 – 1.0
}

export default TurboModuleRegistry.getEnforcing<Spec>('RNFileInfoDownloadManager');
```

### Events (via `RCTEventEmitter` / `NativeEventEmitter`)

```ts
// Register in JS:
// const emitter = new NativeEventEmitter(NativeModules.RNFileInfoDownloadManager)

type DownloadProgressEvent = {
  downloadId: string;
  bytesWritten: number;
  totalBytes: number;
  progress: number;          // 0.0 – 1.0
};

type DownloadCompleteEvent = {
  downloadId: string;
  uri: string;
};

type DownloadErrorEvent = {
  downloadId: string;
  errorCode: string;         // See error codes in §14
  message: string;
};

type DownloadPausedEvent = {
  downloadId: string;
  downloadedBytes: number;
  resumeData: string;        // iOS base64 blob or '' on Android
};
```

---

## 4. JS Public API

Fully compatible with Expo `DownloadResumable`.

### `DownloadResumable` class

```ts
import NativeDownloadManager from './NativeDownloadManager';
import { NativeEventEmitter, NativeModules } from 'react-native';

const emitter = new NativeEventEmitter(NativeModules.RNFileInfoDownloadManager);

export interface DownloadOptions {
  headers?: Record<string, string>;
  md5?: boolean;             // optional post-download SHA256 check
}

export interface DownloadProgressData {
  totalBytesWritten: number;
  totalBytesExpectedToWrite: number;
}

export interface DownloadResult {
  uri: string;
  status: string;
  bytesWritten: number;
}

export class DownloadResumable {
  private readonly _id: string;
  private readonly _url: string;
  private readonly _fileUri: string;
  private readonly _options: DownloadOptions;
  private readonly _progressCallback?: (data: DownloadProgressData) => void;
  private _resumeData: string | null = null;
  private _progressSub: ReturnType<typeof emitter.addListener> | null = null;

  constructor(
    url: string,
    fileUri: string,
    options: DownloadOptions = {},
    progressCallback?: (data: DownloadProgressData) => void
  ) {
    this._id = _generateId();
    this._url = url;
    this._fileUri = fileUri;
    this._options = options;
    this._progressCallback = progressCallback;
  }

  async downloadAsync(): Promise<DownloadResult> {
    this._subscribeProgress();
    await NativeDownloadManager.startDownload(
      this._id,
      this._url,
      this._fileUri,
      this._options.headers ?? {},
      null
    );
    return this._waitForCompletion();
  }

  async pauseAsync(): Promise<DownloadSnapshot> {
    const resumeData = await NativeDownloadManager.pauseDownload(this._id);
    this._resumeData = resumeData;
    this._unsubscribeProgress();
    return this.savable();
  }

  async resumeAsync(): Promise<DownloadResult> {
    this._subscribeProgress();
    await NativeDownloadManager.resumeDownload(this._id, this._resumeData);
    return this._waitForCompletion();
  }

  async cancelAsync(): Promise<void> {
    this._unsubscribeProgress();
    await NativeDownloadManager.cancelDownload(this._id);
  }

  savable(): DownloadSnapshot {
    return {
      url: this._url,
      fileUri: this._fileUri,
      headers: this._options.headers ?? {},
      resumeData: this._resumeData ?? '',
    };
  }

  private _subscribeProgress() {
    if (this._progressCallback) {
      this._progressSub = emitter.addListener('downloadProgress', (e) => {
        if (e.downloadId === this._id && this._progressCallback) {
          this._progressCallback({
            totalBytesWritten: e.bytesWritten,
            totalBytesExpectedToWrite: e.totalBytes,
          });
        }
      });
    }
  }

  private _unsubscribeProgress() {
    this._progressSub?.remove();
    this._progressSub = null;
  }

  private _waitForCompletion(): Promise<DownloadResult> {
    return new Promise((resolve, reject) => {
      const completeSub = emitter.addListener('downloadComplete', (e) => {
        if (e.downloadId === this._id) {
          completeSub.remove();
          errorSub.remove();
          resolve({ uri: e.uri, status: 'completed', bytesWritten: 0 });
        }
      });
      const errorSub = emitter.addListener('downloadError', (e) => {
        if (e.downloadId === this._id) {
          completeSub.remove();
          errorSub.remove();
          reject(new Error(`[${e.errorCode}] ${e.message}`));
        }
      });
    });
  }
}

// Factory function (Expo API compatible)
export function createDownloadResumable(
  url: string,
  fileUri: string,
  options?: DownloadOptions,
  progressCallback?: (data: DownloadProgressData) => void
): DownloadResumable {
  return new DownloadResumable(url, fileUri, options, progressCallback);
}

// Crash recovery helper
export async function restoreDownloads(): Promise<DownloadResumable[]> {
  const snapshots = await NativeDownloadManager.restoreDownloads();
  return snapshots.map((snap) => {
    const dl = new DownloadResumable(snap.url, snap.fileUri, { headers: snap.headers });
    // @ts-ignore internal state restore
    dl._id = snap.downloadId;
    // @ts-ignore
    dl._resumeData = snap.resumeData ?? null;
    return dl;
  });
}

function _generateId(): string {
  return `dl_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}
```

---

## 5. State Machine

Every download follows a strict state machine. Invalid transitions are silently dropped.

```
                    ┌─────────┐
                    │  IDLE   │
                    └────┬────┘
                         │ startDownload()
                    ┌────▼────┐
                    │STARTING │
                    └────┬────┘
                         │ connection established
              ┌──────────▼──────────┐
              │     DOWNLOADING     │◄──────────────┐
              └──┬──────────────┬───┘               │
          pause()│              │error (retryable)  │
           ┌─────▼─────┐  ┌────▼─────┐             │
           │  PAUSED   │  │ RETRYING │─────────────►┘
           └─────┬─────┘  └────┬─────┘
         resume()│              │max retries exceeded
           ┌─────▼─────┐  ┌────▼────┐
           │(re-STARTING)│  │ FAILED │
           └─────────────┘  └────────┘
              DOWNLOADING
              │
              │ 200 OK (file complete)
         ┌────▼──────┐
         │ COMPLETED │
         └───────────┘
```

**State enum (shared across iOS + Android):**

```
IDLE        = "idle"
STARTING    = "starting"
DOWNLOADING = "downloading"
PAUSED      = "paused"
RETRYING    = "retrying"
COMPLETED   = "completed"
FAILED      = "failed"
CANCELLED   = "cancelled"
```

---

## 6. Core Data Model

### `DownloadTask` (conceptual, native side)

```
id              : String           — UUID or JS-provided ID
url             : String
destinationPath : String           — absolute path
headers         : Map<String,String>
status          : DownloadStatus
downloadedBytes : Int64 / Long     — MUST be 64-bit (supports > 2 GB)
totalBytes      : Int64 / Long     — MUST be 64-bit; -1 if unknown
etag            : String?
lastModified    : String?
metadataPath    : String           — path to .download file
retryCount      : Int
lastProgressAt  : Long             — timestamp ms (for throttling)
lastCheckpointAt: Long             — timestamp ms (for metadata flush)
```

> ⚠️ **Critical:** Never use `Int` / `int` for byte counters. Files > 2 GB overflow 32-bit integers. Use `Long` on Android and `Int64` / `int64_t` on iOS everywhere.

---

## 7. Task Registry

Singleton on the native side. Holds all in-flight tasks.

```
DownloadRegistry
  activeDownloads : Map<String, DownloadTask>

  fun register(task: DownloadTask)
  fun get(id: String): DownloadTask?
  fun remove(id: String)
  fun allActive(): List<DownloadTask>
```

- **Thread-safe** — use `ConcurrentHashMap` on Android, `@synchronized` / actor on iOS
- Never access `activeDownloads` from multiple threads without locking

---

## 8. Metadata Persistence (Crash Safety)

Every download maintains a sidecar file alongside the destination:

```
/downloads/video.mp4          ← partial or complete data
/downloads/video.mp4.download ← JSON metadata (state file)
```

### Metadata JSON schema

```json
{
  "id": "dl_1710000000000_abc1234",
  "url": "https://example.com/video.mp4",
  "fileUri": "/downloads/video.mp4",
  "downloadedBytes": 10485760,
  "totalBytes": 104857600,
  "etag": "\"a1b2c3d4\"",
  "lastModified": "Wed, 12 Mar 2025 12:00:00 GMT",
  "status": "downloading",
  "headers": {},
  "createdAt": 1710000000000,
  "updatedAt": 1710001000000
}
```

### Atomic write pattern (MUST follow this — never write directly)

```
1. Serialize JSON to string
2. Write to  video.mp4.download.tmp
3. fsync()  (flush OS buffers to disk)
4. rename(video.mp4.download.tmp, video.mp4.download)
```

`rename()` is atomic on all POSIX systems. A crash between steps 2 and 4 leaves `.tmp` behind but `.download` is always valid.

### Checkpoint frequency

Update metadata when **either** condition is met:

```
downloadedBytes - lastCheckpointBytes >= 512 * 1024   (512 KB written)
OR
now - lastCheckpointAt >= 1000ms
```

Both thresholds are tunable constants.

### File size consistency check (before resume)

```
actualFileSize = stat(destinationPath).size
if actualFileSize != downloadedBytes:
    if actualFileSize < downloadedBytes:
        truncate file to actualFileSize
        set downloadedBytes = actualFileSize   // safe fallback
    else:
        delete partial file, restart from 0
```

### Completion cleanup

```
1. Verify stat(file).size == totalBytes
2. Delete .download metadata file
3. Emit downloadComplete event
```

---

## 9. iOS Implementation

### Session setup

```objc
// RNFileInfoDownloadManager.m

- (NSURLSession *)session {
  if (!_session) {
    NSURLSessionConfiguration *config =
      [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30;
    config.timeoutIntervalForResource = 0;   // no resource timeout for large files
    config.HTTPMaximumConnectionsPerHost = 4;
    _session = [NSURLSession sessionWithConfiguration:config
                                             delegate:self
                                        delegateQueue:nil];  // nil = background queue
  }
  return _session;
}
```

### Starting a download

```objc
- (void)startDownloadWithTask:(RNFIDownloadTask *)task {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task.url]];
  [task.headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *_) {
    [request setValue:v forHTTPHeaderField:k];
  }];

  NSURLSessionDownloadTask *nativeTask;
  if (task.resumeData.length > 0) {
    nativeTask = [self.session downloadTaskWithResumeData:task.resumeData];
  } else {
    nativeTask = [self.session downloadTaskWithRequest:request];
  }

  task.nativeTask = nativeTask;
  task.status = RNFIStatusDownloading;
  [self persistMetadata:task];
  [nativeTask resume];
}
```

### Progress delegate

```objc
// NSURLSessionDownloadDelegate
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {

  RNFIDownloadTask *task = [self.registry taskForNativeTask:downloadTask];
  if (!task) return;

  task.downloadedBytes = totalBytesWritten;
  task.totalBytes = totalBytesExpectedToWrite;

  // Checkpoint
  int64_t now = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000);
  if ((totalBytesWritten - task.lastCheckpointBytes >= 524288) ||
      (now - task.lastCheckpointAt >= 1000)) {
    task.lastCheckpointBytes = totalBytesWritten;
    task.lastCheckpointAt = now;
    [self persistMetadata:task];
  }

  // Throttled progress event
  if (now - task.lastProgressAt >= 250) {
    task.lastProgressAt = now;
    [self emitProgressForTask:task];
  }
}
```

### Completion delegate

```objc
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {

  RNFIDownloadTask *task = [self.registry taskForNativeTask:downloadTask];
  if (!task) return;

  NSError *error;
  NSURL *dest = [NSURL fileURLWithPath:task.destinationPath];

  // Ensure destination directory exists
  [[NSFileManager defaultManager]
    createDirectoryAtPath:[task.destinationPath stringByDeletingLastPathComponent]
    withIntermediateDirectories:YES attributes:nil error:nil];

  // Remove existing file if present
  [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];

  BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:location toURL:dest error:&error];
  if (!moved) {
    [self failTask:task errorCode:@"FILE_WRITE_ERROR" message:error.localizedDescription];
    return;
  }

  task.status = RNFIStatusCompleted;
  [self deleteMetadata:task];
  [self.registry remove:task.id];
  [self emitEvent:@"downloadComplete" body:@{@"downloadId": task.id, @"uri": task.destinationPath}];
}
```

### Pause

```objc
- (void)pauseDownload:(NSString *)downloadId
             resolver:(RCTPromiseResolveBlock)resolve
             rejecter:(RCTPromiseRejectBlock)reject {

  RNFIDownloadTask *task = [self.registry taskForId:downloadId];
  if (!task || task.status != RNFIStatusDownloading) {
    resolve(@"");
    return;
  }

  [task.nativeTask cancelByProducingResumeData:^(NSData *resumeData) {
    NSString *encoded = [resumeData base64EncodedStringWithOptions:0] ?: @"";
    task.resumeData = resumeData;
    task.status = RNFIStatusPaused;
    [self persistMetadata:task];
    [self emitEvent:@"downloadPaused" body:@{
      @"downloadId": downloadId,
      @"downloadedBytes": @(task.downloadedBytes),
      @"resumeData": encoded
    }];
    resolve(encoded);
  }];
}
```

---

## 10. Android Implementation

### DownloadWorker (per-task thread)

```kotlin
// DownloadTask.kt

class DownloadWorker(
    private val task: DownloadTask,
    private val registry: DownloadRegistry,
    private val eventEmitter: RNEventEmitter,
) : Runnable {

    companion object {
        private const val BUFFER_SIZE = 32 * 1024           // 32 KB
        private const val PROGRESS_INTERVAL_MS = 250L
        private const val CHECKPOINT_BYTES = 512 * 1024L    // 512 KB
    }

    @Volatile private var cancelled = false

    override fun run() {
        var connection: HttpURLConnection? = null
        try {
            connection = buildConnection()
            val responseCode = connection.responseCode

            when (responseCode) {
                HttpURLConnection.HTTP_PARTIAL -> resumeWrite(connection)  // 206
                HttpURLConnection.HTTP_OK -> {                              // 200 — server reset
                    restartFromZero()
                    resumeWrite(connection)
                }
                else -> throw HttpException(responseCode, connection.responseMessage)
            }
        } catch (e: InterruptedException) {
            // Pause requested — state already saved
        } catch (e: Exception) {
            handleError(e)
        } finally {
            connection?.disconnect()
        }
    }

    private fun buildConnection(): HttpURLConnection {
        val url = URL(task.url)
        val conn = url.openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout    = 30_000
        conn.instanceFollowRedirects = true
        conn.setRequestProperty("Accept-Encoding", "identity")  // disable gzip for range requests

        task.headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }

        // Resume headers
        if (task.downloadedBytes > 0) {
            conn.setRequestProperty("Range", "bytes=${task.downloadedBytes}-")
            task.etag?.let    { conn.setRequestProperty("If-Range", it) }
        }

        conn.connect()
        return conn
    }

    private fun resumeWrite(connection: HttpURLConnection) {
        val totalFromHeader = connection.getHeaderField("Content-Range")
            ?.substringAfterLast('/')?.toLongOrNull()
            ?: connection.contentLengthLong.let {
                if (task.downloadedBytes > 0) task.downloadedBytes + it else it
            }

        if (totalFromHeader > 0) task.totalBytes = totalFromHeader

        // Pre-allocate if total size is known and file doesn't exist yet
        if (task.downloadedBytes == 0L && task.totalBytes > 0) {
            preallocate(task.destinationPath, task.totalBytes)
        }

        val destFile = File(task.destinationPath)
        destFile.parentFile?.mkdirs()

        val input = connection.inputStream.buffered(BUFFER_SIZE)
        val output = RandomAccessFile(destFile, "rw")

        try {
            output.seek(task.downloadedBytes)
            val buffer = ByteArray(BUFFER_SIZE)
            var bytesRead: Int
            var lastProgressMs = System.currentTimeMillis()
            var lastCheckpointBytes = task.downloadedBytes

            task.status = DownloadStatus.DOWNLOADING
            registry.persistMetadata(task)

            while (input.read(buffer).also { bytesRead = it } != -1) {
                if (Thread.currentThread().isInterrupted || cancelled) {
                    throw InterruptedException("Download paused")
                }

                output.write(buffer, 0, bytesRead)
                task.downloadedBytes += bytesRead

                val now = System.currentTimeMillis()

                // Checkpoint
                if (task.downloadedBytes - lastCheckpointBytes >= CHECKPOINT_BYTES ||
                    now - lastProgressMs >= 1000L) {
                    lastCheckpointBytes = task.downloadedBytes
                    registry.persistMetadata(task)
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
        registry.persistMetadata(task)
    }

    private fun completeDownload() {
        val actualSize = File(task.destinationPath).length()
        if (task.totalBytes > 0 && actualSize != task.totalBytes) {
            handleError(Exception("Size mismatch: got $actualSize expected ${task.totalBytes}"))
            return
        }
        task.status = DownloadStatus.COMPLETED
        registry.deleteMetadata(task)
        registry.remove(task.id)
        eventEmitter.emit("downloadComplete", mapOf("downloadId" to task.id, "uri" to task.destinationPath))
    }

    private fun emitProgress() {
        val progress = if (task.totalBytes > 0) task.downloadedBytes.toDouble() / task.totalBytes else 0.0
        eventEmitter.emit("downloadProgress", mapOf(
            "downloadId"   to task.id,
            "bytesWritten" to task.downloadedBytes,
            "totalBytes"   to task.totalBytes,
            "progress"     to progress,
        ))
    }

    private fun handleError(e: Exception) {
        task.status = DownloadStatus.FAILED
        registry.persistMetadata(task)
        eventEmitter.emit("downloadError", mapOf(
            "downloadId" to task.id,
            "errorCode"  to errorCode(e),
            "message"    to (e.message ?: "Unknown error"),
        ))
    }

    fun pause() {
        cancelled = true
    }

    private fun errorCode(e: Exception): String = when (e) {
        is HttpException          -> "HTTP_ERROR"
        is InterruptedException   -> "CANCELLED"
        is FileNotFoundException  -> "FILE_WRITE_ERROR"
        is SocketTimeoutException -> "TIMEOUT"
        else                      -> "NETWORK_ERROR"
    }
}
```

### Executor (Android Download Manager)

```kotlin
// DownloadManager.kt

object NativeDownloadManager {
    private val executor = Executors.newFixedThreadPool(4)
    private val workers  = ConcurrentHashMap<String, DownloadWorker>()

    fun start(task: DownloadTask, emitter: RNEventEmitter) {
        val worker = DownloadWorker(task, DownloadRegistry, emitter)
        workers[task.id] = worker
        executor.submit(worker)
    }

    fun pause(id: String) {
        workers[id]?.pause()
        workers.remove(id)
    }

    fun cancel(id: String) {
        pause(id)
        DownloadRegistry.get(id)?.let { task ->
            File(task.destinationPath).delete()
            DownloadRegistry.deleteMetadata(task)
            DownloadRegistry.remove(id)
        }
    }
}
```

---

## 11. Parallel Download Scheduler

```
maxConcurrentDownloads = 4  (configurable; default 4)

DownloadQueue
  activeDownloads : Map<id, DownloadWorker>   (currently running)
  waitingQueue    : LinkedList<DownloadTask>   (FIFO queue)
```

**Scheduling logic:**

```
enqueue(task):
    if activeDownloads.size < maxConcurrentDownloads:
        start(task)
    else:
        waitingQueue.add(task)

onDownloadFinished(task):
    activeDownloads.remove(task.id)
    next = waitingQueue.poll()
    if next != null:
        start(next)
```

iOS: `URLSession` handles connection concurrency natively via `HTTPMaximumConnectionsPerHost`.

---

## 12. Resume Strategy & Validation

### On every resume request:

```
1. Read metadata (.download file)
2. Check file size consistency (§8)
3. Build request:
     Range: bytes=<downloadedBytes>-
     If-Range: <etag>        (if etag is known)
4. Send request
5. Inspect response:
     206 Partial Content → append to existing file
     200 OK              → server changed file, restart from 0
     416 Range Not Sat.  → file already complete OR offset wrong, verify size
     4xx                 → fail with HTTP_ERROR
     5xx                 → retry with backoff
```

### Detecting "fake" Range support

Some servers echo `Accept-Ranges: bytes` but respond with `200 OK` and full content for all `Range` requests. Detect this:

```
If response is 200 AND Content-Length == totalBytes AND downloadedBytes > 0:
    → Server ignored Range header
    → Delete partial file, restart from 0
    → Log warning: "SERVER_RANGE_UNSUPPORTED"
```

### ETag / Last-Modified tracking

Store both in metadata. On resume, if `If-Range` returns a `200`, the server file changed. Always restart clean.

---

## 13. Progress Events

**Throttle rules (prevents bridge saturation on large/fast downloads):**

```
Emit downloadProgress when BOTH:
  1. now - lastProgressEmittedAt >= 250ms
  2. bytesWritten has changed

Do NOT emit on every buffer write
```

**Event payload:**

```ts
{
  downloadId:   string,
  bytesWritten: number,   // Int64-safe JS number
  totalBytes:   number,   // -1 if unknown (no Content-Length)
  progress:     number,   // 0.0 – 1.0; -1 if totalBytes unknown
}
```

---

## 14. Error Handling & Retry

### Error codes

| Code | Trigger |
|---|---|
| `NETWORK_ERROR` | Connection refused, DNS failure, socket closed |
| `TIMEOUT` | Connect or read timeout exceeded |
| `HTTP_ERROR` | Non-2xx response with no retry |
| `FILE_WRITE_ERROR` | Cannot open/write destination file |
| `INSUFFICIENT_STORAGE` | Disk space check failed before start |
| `SERVER_CHANGED_FILE` | ETag mismatch on resume |
| `SERVER_RANGE_UNSUPPORTED` | Server ignored Range header |
| `CHECKSUM_MISMATCH` | Optional SHA256 post-download check failed |

### Retry policy (retryable errors only)

Retryable: `NETWORK_ERROR`, `TIMEOUT`, `HTTP_ERROR` (5xx only)

```
attempt 1 → wait 1s
attempt 2 → wait 2s
attempt 3 → wait 4s
attempt 4 → wait 8s
attempt 5 → wait 16s
attempt 6 → FAILED (emit downloadError)
```

Non-retryable (fail immediately): `FILE_WRITE_ERROR`, `HTTP_ERROR` (4xx), `INSUFFICIENT_STORAGE`

### Pre-flight disk space check

```
Before startDownload():
    available = getAvailableDiskSpace()
    required  = totalBytes > 0 ? totalBytes : estimatedSize
    if available < required + 100MB:
        throw INSUFFICIENT_STORAGE
```

---

## 15. Crash Recovery on Startup

Call once during library initialization:

```
RNFileInfoDownloadManager.restoreDownloads()
```

### Native scan algorithm

```
1. For each directory that has been used for downloads:
     scan for *.download files

2. For each .download file found:
     a. Parse JSON metadata
     b. Verify the partial data file exists at fileUri
     c. Run size consistency check (§8)
     d. Set status = PAUSED
     e. Add to registry (do NOT auto-resume)

3. Return array of snapshots to JS
```

### JS recovery usage

```ts
// Call on app start, e.g. in App.tsx useEffect
const pending = await restoreDownloads();
for (const dl of pending) {
  // Optionally show UI, then:
  dl.resumeAsync();
}
```

### Edge cases

| Scenario | Action |
|---|---|
| `.download` file exists, data file missing | Delete `.download`, skip |
| `.download` file is corrupt / invalid JSON | Delete `.download`, skip |
| Data file exists, no `.download` file | Ignore (may be a complete file) |
| `etag` changed on server after resume | Server returns 200 → restart download |

---

## 16. Performance Rules

| Rule | Value |
|---|---|
| I/O buffer size | 32 KB (sweet spot for throughput + memory) |
| Progress emit interval | 250 ms |
| Metadata checkpoint interval | 512 KB or 1s |
| Max concurrent downloads | 4 (configurable) |
| Connect timeout | 15 s |
| Read timeout | 30 s |
| Memory per download | < 50 KB |

### Pre-allocation (optional, improves large-file write speed)

Allocate the full file size before writing begins. Reduces fragmentation on Android.

```kotlin
// Android
RandomAccessFile(destFile, "rw").use { it.setLength(task.totalBytes) }
```

```objc
// iOS
int fd = open([path UTF8String], O_RDWR | O_CREAT, 0644);
ftruncate(fd, totalBytes);
close(fd);
```

Only do this when `totalBytes` is known from `Content-Length`.

### Never load full file into memory

```
Stream only. Buffer size = 32 KB. Never accumulate bytes in RAM.
```

---

## 17. Security & Safety Checks

### Path traversal prevention

```
destinationPath must:
  - be an absolute path
  - not contain ".."
  - be within an allowed base directory
```

```kotlin
// Android
fun validatePath(path: String, allowedBase: String): Boolean {
    val canonical = File(path).canonicalPath
    return canonical.startsWith(allowedBase)
}
```

### HTTPS enforcement (optional flag)

```ts
options?: {
  allowInsecure?: boolean  // default false; set true for local dev only
}
```

If `allowInsecure` is false and URL scheme is `http://`, reject with `INSECURE_URL`.

### Directory creation

Always call before opening output file:

```kotlin
File(destinationPath).parentFile?.mkdirs()
```

---

## 18. File Layout

### Repository structure

```
rn-fileinfo/
  ├── src/
  │   ├── download/
  │   │   ├── DownloadResumable.ts        ← public API class
  │   │   ├── DownloadManager.ts          ← restoreDownloads, helpers
  │   │   └── NativeDownloadManager.ts    ← TurboModule codegen spec
  │   └── index.ts
  │
  ├── ios/
  │   └── RNFileInfoDownloadManager/
  │       ├── RNFileInfoDownloadManager.h
  │       ├── RNFileInfoDownloadManager.mm  ← TurboModule impl
  │       ├── RNFIDownloadTask.h
  │       └── RNFIDownloadTask.m
  │
  ├── android/
  │   └── src/main/java/com/novastera/rnfileinfo/download/
  │       ├── DownloadManagerModule.kt     ← TurboModule impl
  │       ├── DownloadTask.kt
  │       ├── DownloadWorker.kt
  │       ├── DownloadRegistry.kt
  │       └── DownloadQueue.kt
  │
  └── android/src/main/java/.../RNFileInfoPackage.kt
```

### Disk layout at runtime

```
<destinationDir>/
  video.mp4               ← partial or complete data file
  video.mp4.download      ← JSON metadata (deleted on completion)
  video.mp4.download.tmp  ← atomic write temp (exists only during flush)
  archive.zip
  archive.zip.download
```

---

## 19. Testing Plan

### Unit tests

- State machine: verify all valid and invalid transitions
- Metadata: atomic write, corrupt file recovery, size mismatch handling
- Retry logic: backoff timing, max retries

### Integration tests

| Test | Expected |
|---|---|
| Full download, no interruption | `downloadComplete` fires, file intact |
| Pause mid-download | `downloadPaused` fires, `.download` file written |
| Resume after pause | Resumes from correct byte offset |
| App kill during download | After restart, `restoreDownloads()` returns task |
| Network dropout + reconnect | Auto-retry resumes correctly |
| Server file changed (ETag mismatch) | Download restarts from 0, file correct |
| Server ignores Range header (200 on resume) | Detects fake resume, restarts cleanly |
| 2 GB file download | Completes without crash; 64-bit counters correct |
| 10 simultaneous downloads | 4 active, 6 queued; all complete |
| Disk full mid-download | `INSUFFICIENT_STORAGE` error emitted |
| Bad destination path | `FILE_WRITE_ERROR` error emitted |
| HTTP 404 | `HTTP_ERROR` emitted, no retry |
| HTTP 503 | Retried up to 5 times with backoff |

### Performance benchmarks

```
Local network (WiFi):   target > 40 MB/s
Internet download:      target  5–20 MB/s
RAM per active download: < 50 KB
```

---

## 20. Future Enhancements

Listed in priority order. **None required for v1.**

| Feature | Notes |
|---|---|
| Background URLSession (iOS) | Allows downloads while app is killed on iOS |
| Android ForegroundService | Keeps downloads alive when app is backgrounded |
| SHA256 / MD5 verification | Post-download integrity check; hash passed in options |
| Segmented (chunked) downloads | Parallel chunks per file for very large files |
| Download priority (HIGH/NORMAL/LOW) | Queue ordering |
| Speed throttling | Cap bandwidth per download |
| Download groups | Pause/resume/cancel a named group |
| Retry strategy per download | Custom backoff per task |
| Download index file (`downloads.json`) | Alternative to directory scanning for recovery |

---

## 21. Best Practices — React Native, Objective-C++ & Kotlin

These rules ensure **ultra-efficient memory usage** and **zero blocking** across all layers of the download manager. Every contributor must follow them.

---

### 21.1 React Native (JS Layer)

#### Non-blocking event pipeline

| Rule | Why |
|---|---|
| Never `await` inside a `NativeEventEmitter` listener | Blocks the JS event loop and stalls **all** event processing |
| Batch state updates inside `requestAnimationFrame` or `InteractionManager.runAfterInteractions` | Prevents jank when multiple downloads fire progress simultaneously |
| Use `useRef` for mutable download state that doesn't need re-renders | Avoids re-render storms from high-frequency progress updates |

```ts
// ✅ Non-blocking progress handler
emitter.addListener('downloadProgress', (e) => {
  // Store in ref — no render
  progressRef.current[e.downloadId] = e.progress;

  // Debounced UI update on next frame
  if (!frameScheduled.current) {
    frameScheduled.current = true;
    requestAnimationFrame(() => {
      setProgressMap({ ...progressRef.current });
      frameScheduled.current = false;
    });
  }
});
```

```ts
// ❌ NEVER do this — blocks the bridge callback queue
emitter.addListener('downloadProgress', async (e) => {
  await AsyncStorage.setItem(`progress_${e.downloadId}`, JSON.stringify(e));
  setProgress(e);  // state update after await
});
```

#### Subscription lifecycle & leak prevention

```ts
// Always remove listeners in cleanup
useEffect(() => {
  const sub = emitter.addListener('downloadProgress', handler);
  return () => sub.remove();  // ← critical
}, []);
```

- **Never** create listeners without storing the subscription handle
- **Never** rely on component unmount to clean up — explicitly call `remove()`
- For class-based `DownloadResumable`, always call `_unsubscribeProgress()` before registering new listeners

#### Zero-copy bridge patterns

| Pattern | Memory impact |
|---|---|
| Pass `resumeData` as base64 string through JSI | String is copied once at the bridge; avoid buffering on both sides |
| Use `number` for byte counts (safe up to 2^53) | No BigInt overhead; sufficient for 10 GB+ |
| Return minimal payloads from native | Only send fields the JS side actually reads |

> ⚠️ **Never** serialize entire file contents or large blobs through the bridge. The download manager streams to disk natively — JS should only receive metadata.

#### Memory-efficient list rendering

When displaying active downloads in a `FlatList` / `FlashList`:

```ts
// ✅ Use getItemLayout to avoid measurement overhead
getItemLayout={(_, index) => ({ length: 72, offset: 72 * index, index })}

// ✅ Limit re-renders to visible items
windowSize={5}
maxToRenderPerBatch={4}
updateCellsBatchingPeriod={100}
```

- Never store download data in a flat array that triggers full-list re-renders
- Use a `Map<downloadId, DownloadState>` and derive the render list lazily

---

### 21.2 Objective-C++ (iOS Native Layer)

#### ARC memory management

| Rule | Rationale |
|---|---|
| Use `__weak` references for delegate / callback captures | Prevents retain cycles between `URLSession` delegate and the module |
| Wrap tight loops in `@autoreleasepool {}` | Drains transient objects during long-running operations |
| Never hold strong references to `NSData` beyond the current callback | Resume data can be 1–100 MB; retain only the base64 string |

```objc
// ✅ Weak self in blocks to avoid retain cycle
__weak typeof(self) weakSelf = self;
[task.nativeTask cancelByProducingResumeData:^(NSData *resumeData) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;
    // ... use strongSelf ...
}];
```

```objc
// ✅ Autorelease pool in metadata serialisation
- (void)persistMetadata:(RNFIDownloadTask *)task {
    @autoreleasepool {
        NSDictionary *dict = [self metadataDictForTask:task];
        NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
        [json writeToFile:task.tmpMetadataPath atomically:NO];
        // fsync + rename (atomic write)
    }
    // All transient NSData/NSDictionary freed here
}
```

#### Non-blocking delegate queues

```objc
// The session MUST use a nil delegateQueue (= private background serial queue)
_session = [NSURLSession sessionWithConfiguration:config
                                         delegate:self
                                    delegateQueue:nil];
```

- **Never** pass `[NSOperationQueue mainQueue]` — this blocks the main thread during progress callbacks
- All UI-facing event emission dispatches to the main queue internally via `RCTEventEmitter`; no manual `dispatch_async(dispatch_get_main_queue(), ...)` needed for events

#### Lock-free state access

```objc
// Use os_unfair_lock for registry access (faster than @synchronized, no priority inversion)
os_unfair_lock_lock(&_registryLock);
RNFIDownloadTask *task = _activeTasks[downloadId];
os_unfair_lock_unlock(&_registryLock);
```

| Lock type | When to use |
|---|---|
| `os_unfair_lock` | Short critical sections (registry lookup/insert) |
| `dispatch_queue` (serial) | Metadata I/O serialisation |
| **Never** `@synchronized` in hot paths | It is re-entrant and heavy; use only for one-time init |

#### Zero-allocation progress path

The progress delegate fires hundreds of times per second for fast downloads. Minimise allocations:

```objc
// ✅ Re-use a single mutable dictionary for progress events
- (void)emitProgressForTask:(RNFIDownloadTask *)task {
    // _progressEventBody is an ivar NSMutableDictionary allocated once
    _progressEventBody[@"downloadId"]   = task.taskId;
    _progressEventBody[@"bytesWritten"] = @(task.downloadedBytes);
    _progressEventBody[@"totalBytes"]   = @(task.totalBytes);
    _progressEventBody[@"progress"]     = @(task.progress);
    [self sendEventWithName:@"downloadProgress" body:_progressEventBody];
}
```

> ⚠️ **Never** allocate a new `NSDictionary` per progress callback. A single download can trigger thousands of delegate calls — each allocation pressures the autorelease pool.

#### Objective-C++ specific guidance

When mixing C++ with Objective-C (`.mm` files):

| Rule | Detail |
|---|---|
| Use `std::shared_ptr` / `std::unique_ptr` for C++ objects | ARC does not manage C++ types — you must handle their lifetime |
| Never throw C++ exceptions across Objective-C boundaries | Wrap in `try/catch` and convert to `NSError` |
| Prefer C++ containers (`std::unordered_map`) for hot-path lookups | Faster than `NSDictionary` when keys are known types |
| Use `std::string_view` / `std::span` for borrowed data | Avoids copies when passing buffers between C++ utility functions |

```cpp
// ✅ Use C++ unordered_map for O(1) task lookup (inside .mm file)
#include <unordered_map>
#include <string>

std::unordered_map<std::string, RNFIDownloadTask *> _taskMap;
// Access under os_unfair_lock
```

---

### 21.3 Kotlin (Android Native Layer)

#### Structured concurrency & thread safety

| Rule | Rationale |
|---|---|
| Use `Executors.newFixedThreadPool(4)` (already done) | Bounded thread count prevents OOM from unbounded thread creation |
| Mark shared mutable state `@Volatile` | Ensures visibility across executor threads without full synchronisation |
| Use `ConcurrentHashMap` for the registry | Lock-free reads; segmented writes |
| **Never** create a new `Thread()` per download | Thread creation is expensive (~1 MB stack); always use the pool |

```kotlin
// ✅ Volatile flag for cancellation — no lock needed
@Volatile private var cancelled = false

// ✅ ConcurrentHashMap — lock-free reads
private val workers = ConcurrentHashMap<String, DownloadWorker>()
```

#### Zero-allocation hot path

The inner read loop is the most performance-critical code:

```kotlin
// ✅ Allocate buffer ONCE, outside the loop
val buffer = ByteArray(BUFFER_SIZE)   // 32 KB, allocated once
var bytesRead: Int

while (input.read(buffer).also { bytesRead = it } != -1) {
    output.write(buffer, 0, bytesRead)
    task.downloadedBytes += bytesRead
    // ... throttled progress & checkpoint only ...
}
```

| Anti-pattern | Fix |
|---|---|
| `ByteArray(BUFFER_SIZE)` inside the loop | Move outside — zero per-iteration alloc |
| `String.format()` in progress logging | Use `StringBuilder` or template literals |
| Creating `Map<>` per progress event | Re-use a single `HashMap` instance |
| Boxing `Long` via `mapOf("key" to longVal)` | Unavoidable for bridge; but avoid in internal loops |

#### Back-pressure & flow control

```kotlin
// ✅ Throttle both progress events AND metadata checkpoints
if (task.downloadedBytes - lastCheckpointBytes >= CHECKPOINT_BYTES ||
    now - lastCheckpointMs >= 1000L) {
    // ... persist metadata (I/O) ...
}

if (now - lastProgressMs >= PROGRESS_INTERVAL_MS) {
    // ... emit progress event ...
}
```

- Without throttling, a 100 Mbps download fires the read loop ~380 times/second (32 KB × 380 ≈ 12 MB/s). Emitting events at this rate saturates the JSI bridge.
- The 250 ms progress interval reduces bridge crossings to **4/second** per download.

#### Memory-safe resource cleanup

```kotlin
// ✅ Always close streams in finally — even on exception
try {
    output.seek(task.downloadedBytes)
    // ... read/write loop ...
} finally {
    output.close()   // RandomAccessFile
    input.close()    // BufferedInputStream
}
```

| Resource | Risk if leaked |
|---|---|
| `HttpURLConnection` | Socket leak → eventual `SocketException` |
| `RandomAccessFile` | File descriptor leak → `EMFILE` (too many open files) |
| `InputStream` | Tied to socket; holds native memory |

> ⚠️ **Never** use `use {}` (Kotlin auto-close) on the `HttpURLConnection` — call `disconnect()` explicitly in `finally`. The `use` extension does not call `disconnect()`.

#### WeakReference for event emitters

```kotlin
// ✅ Hold a WeakReference to the React context / event emitter
class DownloadWorker(
    private val task: DownloadTask,
    private val registry: DownloadRegistry,
    private val emitterRef: WeakReference<RNEventEmitter>,
) : Runnable {

    private fun emitProgress() {
        val emitter = emitterRef.get() ?: return  // module deallocated
        emitter.emit("downloadProgress", ...)
    }
}
```

- If the React module is deallocated (e.g. during hot reload), a strong reference keeps the entire React bridge alive
- Using `WeakReference` lets the worker silently stop emitting instead of crashing

#### Kotlin-specific memory rules

| Rule | Detail |
|---|---|
| Avoid `data class` for `DownloadTask` | `copy()` duplicates all fields including large maps — mutate in place |
| Use `IntArray` / `LongArray` over `Array<Int>` / `Array<Long>` | Primitive arrays avoid boxing overhead |
| Use `inline fun` for small utility lambdas | Eliminates anonymous class allocation |
| Prefer `StringBuilder` over string concatenation in loops | Concatenation creates intermediate `String` objects |

---

### 21.4 Cross-Layer Rules (All Platforms)

| # | Rule | Detail |
|---|---|---|
| 1 | **Never buffer the download in memory** | Stream directly to disk. The only in-memory buffer is the 32 KB read buffer. |
| 2 | **64-bit byte counters everywhere** | `Long` (Kotlin), `int64_t` (Obj-C++), `number` (JS). Never `Int` / `int`. |
| 3 | **Throttle all bridge crossings** | Progress: 250 ms. Metadata checkpoint: 512 KB or 1 s. |
| 4 | **Close/release resources in finally** | Streams, connections, file descriptors — no exceptions. |
| 5 | **No main-thread I/O** | All disk and network I/O runs on background threads/queues. |
| 6 | **Bounded concurrency** | Max 4 active downloads. No unbounded thread/task creation. |
| 7 | **Weak references for cross-boundary holders** | Native → JS emitter: weak. Block captures: `__weak self`. |
| 8 | **Atomic metadata writes** | write-tmp → fsync → rename. No partial `.download` files. |
| 9 | **Pre-allocate large files when size is known** | Reduces filesystem fragmentation and prevents mid-write ENOSPC. |
| 10 | **Profile with Instruments / Android Profiler** | Verify < 50 KB RSS per active download before release. |

---

### 21.5 TurboModule / JSI Layer

TurboModules replace the old async bridge with **synchronous JSI bindings** backed by C++ host objects. This introduces new memory and threading constraints specific to this module.

#### JSI thread safety

| Rule | Detail |
|---|---|
| TurboModule methods are called on the **JS thread** | Never perform blocking I/O inside a synchronous TurboModule method |
| Dispatch all network/disk work to a background thread/queue | Return a `Promise` and resolve/reject from the background thread |
| Never hold the JS thread while waiting for native work | The JS thread is single-threaded — blocking it freezes the entire app |

```ts
// ✅ All methods in the codegen spec return Promise<void> or Promise<T>
// This means the JS thread dispatches and immediately returns
startDownload(...): Promise<void>;
pauseDownload(...): Promise<string>;
```

```objc
// ✅ iOS TurboModule: dispatch to background immediately
RCT_EXPORT_METHOD(startDownload:(NSString *)downloadId
                            url:(NSString *)url
                destinationPath:(NSString *)dest
                        headers:(NSDictionary *)headers
                     resumeData:(NSString *)resumeData
                       resolver:(RCTPromiseResolveBlock)resolve
                       rejecter:(RCTPromiseRejectBlock)reject) {
    // Do NOT do any I/O here — we're on the JS thread
    dispatch_async(_workerQueue, ^{
        // All heavy work happens here
        [self _startDownloadInternal:downloadId url:url dest:dest
                             headers:headers resumeData:resumeData
                            resolver:resolve rejecter:reject];
    });
}
```

```kotlin
// ✅ Kotlin TurboModule: submit to executor, resolve promise from worker thread
@ReactMethod
fun startDownload(downloadId: String, url: String, dest: String,
                  headers: ReadableMap, resumeData: String?,
                  promise: Promise) {
    // Returns immediately — JS thread is free
    executor.submit {
        try {
            doStartDownload(downloadId, url, dest, headers, resumeData)
            promise.resolve(null)
        } catch (e: Exception) {
            promise.reject("START_ERROR", e.message, e)
        }
    }
}
```

#### C++ Host Object lifecycle (Codegen)

When React Native codegen generates the C++ binding layer for TurboModules:

| Rule | Rationale |
|---|---|
| The generated `NativeDownloadManagerCxxSpecJSI` inherits from `TurboModule` | Its lifecycle is tied to the JS runtime — don't store raw pointers to it |
| Never capture `jsi::Runtime&` beyond the current call | The runtime can be destroyed on reload; dangling reference = crash |
| Use `jsi::Value` carefully — it's move-only in newer JSI | Copying `jsi::Value` is undefined behaviour; always `std::move()` |
| Never create `jsi::String` / `jsi::Object` from a background thread | JSI objects must be created on the JS thread that owns the runtime |

```cpp
// ❌ NEVER — captures runtime reference for later use
void startDownload(jsi::Runtime &rt, ...) {
    cachedRuntime_ = &rt;  // dangling after hot reload!
}

// ✅ Use CallInvoker to marshal results back to JS thread
callInvoker_->invokeAsync([resolve = std::move(resolve)]() {
    resolve->asObject(rt).asFunction(rt).call(rt);
});
```

#### Event emission from native threads

TurboModules emit events through `RCTEventEmitter` (iOS) or `RCTDeviceEventEmitter` (Android). These internally marshal to the JS thread, but there are pitfalls:

```objc
// ✅ iOS: sendEventWithName is thread-safe in RCTEventEmitter
// BUT — avoid calling it at >250ms frequency (already throttled in §13)
[self sendEventWithName:@"downloadProgress" body:eventBody];
```

```kotlin
// ✅ Android: emit via DeviceEventManagerModule
// This internally posts to the JS message queue
reactContext
    .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
    .emit("downloadProgress", params)
```

| Rule | Detail |
|---|---|
| Never call `emit` in a tight loop without throttling | Each call enqueues a message on the JS thread — 1000 calls/sec = OOM |
| Serialise event payloads to `WritableMap` (Android) / `NSDictionary` (iOS) | These are the only types the bridge can marshal efficiently |
| Avoid `ReadableArray` / `NSArray` for progress events | Arrays have higher serialisation cost than flat maps |

#### TurboModule initialisation & teardown

```objc
// ✅ iOS: lazy-init expensive resources
- (instancetype)init {
    if (self = [super init]) {
        // Only allocate lightweight state here
        _registryLock = OS_UNFAIR_LOCK_INIT;
        _activeTasks = [NSMutableDictionary new];
    }
    return self;
}

// Lazy — URLSession is only created when first download starts
- (NSURLSession *)session {
    if (!_session) { /* create session */ }
    return _session;
}

// ✅ Invalidate session on module dealloc to prevent delegate leak
- (void)invalidate {
    [_session invalidateAndCancel];
    _session = nil;
}
```

```kotlin
// ✅ Android: clean up in onCatalystInstanceDestroy
override fun onCatalystInstanceDestroy() {
    executor.shutdownNow()          // cancel all running downloads
    workers.clear()
    DownloadRegistry.clear()
}
```

| Rule | Detail |
|---|---|
| Lazy-init `URLSession` / `ExecutorService` | Saves memory when the module is loaded but no downloads are active |
| Always implement `invalidate` (iOS) / `onCatalystInstanceDestroy` (Android) | Prevents leaked threads, sockets, and file descriptors after hot reload |
| Never retain the `ReactApplicationContext` strongly in workers | Use `WeakReference` — the context can be destroyed on reload |

#### Codegen spec memory rules

| Spec type | Bridge cost | Guidance |
|---|---|---|
| `string` | Copied across bridge | Keep short — don't pass multi-MB base64 unless necessary (e.g. `resumeData`) |
| `{ [key: string]: string }` (object map) | Each key-value pair is serialised individually | Limit to essential headers; don't pass entire response headers back |
| `number` | 8 bytes (IEEE 754 double) | Preferred for all counters — zero overhead |
| `Promise<T>` | Single bridge crossing on resolve/reject | Always use for I/O methods; never return synchronously |
| `boolean` | 1 byte | Negligible cost |

> ⚠️ **Codegen golden rule:** Every field in a codegen `interface` becomes a bridge crossing. Remove any field that JS doesn't actively consume.

---

## Appendix: Quick Reference

### Must-use 64-bit types

```kotlin
// Android — ALWAYS Long, never Int
var downloadedBytes: Long = 0L
var totalBytes: Long = -1L
```

```objc
// iOS — Apple already uses int64_t in URLSession delegates
int64_t totalBytesWritten
int64_t totalBytesExpectedToWrite
```

### Atomic metadata write (pseudocode)

```
write(content, path + ".tmp")
fsync(path + ".tmp")
rename(path + ".tmp", path)
```

### Resume request headers

```
Range: bytes=<downloadedBytes>-
If-Range: <etag>
```

### Response → action table

| HTTP Status | Action |
|---|---|
| 206 | Append to partial file, continue |
| 200 | Delete partial file, restart from byte 0 |
| 416 | Verify file size; if complete emit success, else restart |
| 404, 403, 410 | Fail immediately (`HTTP_ERROR`), no retry |
| 500, 503 | Retry with exponential backoff |
| Other 4xx | Fail immediately |

---

*End of Specification — rn-fileinfo Native Download Manager v1*