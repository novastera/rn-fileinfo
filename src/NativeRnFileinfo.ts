import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

// ─── Download Types ────────────────────────────────────────────────

export interface DownloadSnapshotSpec {
  downloadId: string;
  url: string;
  fileUri: string;
  downloadedBytes: number; // JS number safe up to 2^53, sufficient for 10 GB
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
  progress: number; // 0.0 – 1.0
}

// ─── Module Spec ───────────────────────────────────────────────────

export interface Spec extends TurboModule {
  // ── File Info ──────────────────────────────────────────────────

  /**
   * Get file information for a single file
   * @param path The file path to get information for
   * @returns Promise that resolves to FileInfo object
   */
  getFileInfo(path: string): Promise<{
    path: string;
    name: string;
    size: number;
    isFile: boolean;
    isDirectory: boolean;
    createdAt: number;
    modifiedAt: number;
  }>;

  /**
   * Get file information for all files in a directory
   * @param path The directory path to scan
   * @param options Optional configuration for directory scanning
   * @returns Promise that resolves to array of FileInfo objects
   */
  getDirectoryInfo(path: string, options: {
    recursive?: boolean;
    includeHidden?: boolean;
    maxDepth?: number;
  }): Promise<Array<{
    path: string;
    name: string;
    size: number;
    isFile: boolean;
    isDirectory: boolean;
    createdAt: number;
    modifiedAt: number;
  }>>;

  /**
   * Check if a path exists
   * @param path The path to check
   * @returns Promise that resolves to boolean indicating if path exists
   */
  exists(path: string): Promise<boolean>;

  /**
   * Check if a path is a file
   * @param path The path to check
   * @returns Promise that resolves to boolean indicating if path is a file
   */
  isFile(path: string): Promise<boolean>;

  /**
   * Check if a path is a directory
   * @param path The path to check
   * @returns Promise that resolves to boolean indicating if path is a directory
   */
  isDirectory(path: string): Promise<boolean>;

  // ── Download Manager ──────────────────────────────────────────

  /**
   * Start a new download
   * @param downloadId Unique identifier for this download
   * @param url The URL to download from
   * @param destinationPath Absolute path to save the file to
   * @param headers HTTP headers to include in the request
   * @param resumeData iOS resume blob (base64) or null
   */
  startDownload(
    downloadId: string,
    url: string,
    destinationPath: string,
    headers: { [key: string]: string },
    resumeData: string | null
  ): Promise<void>;

  /**
   * Pause an active download
   * @param downloadId The download to pause
   * @returns Resume data (iOS base64 blob) or empty string
   */
  pauseDownload(downloadId: string): Promise<string>;

  /**
   * Resume a paused download
   * @param downloadId The download to resume
   * @param resumeData iOS resume blob (base64) or null
   */
  resumeDownload(
    downloadId: string,
    resumeData: string | null
  ): Promise<void>;

  /**
   * Cancel and clean up a download
   * @param downloadId The download to cancel
   */
  cancelDownload(downloadId: string): Promise<void>;

  /**
   * Restore downloads from crash recovery metadata files
   * @returns Array of download snapshots that can be resumed
   */
  restoreDownloads(): Promise<DownloadSnapshotSpec[]>;

  /**
   * Get current status of a download
   * @param downloadId The download to query
   */
  getDownloadStatus(downloadId: string): Promise<DownloadStatusSpec>;

  // ── Event Emitter ─────────────────────────────────────────────

  /**
   * Register for native events (required for NativeEventEmitter)
   */
  addListener(eventName: string): void;

  /**
   * Remove event listener registrations (required for NativeEventEmitter)
   */
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('RnFileinfo');