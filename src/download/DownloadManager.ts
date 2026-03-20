import NativeModule from '../NativeRnFileinfo';
import {
  DownloadResumable,
  type DownloadOptions,
  type DownloadProgressData,
} from './DownloadResumable';

// ─── Factory (Expo API compatible) ─────────────────────────────────

/**
 * Create a new `DownloadResumable` instance.
 * Drop-in replacement for Expo's `FileSystem.createDownloadResumable`.
 */
export function createDownloadResumable(
  url: string,
  fileUri: string,
  options?: DownloadOptions,
  progressCallback?: (data: DownloadProgressData) => void
): DownloadResumable {
  return new DownloadResumable(url, fileUri, options, progressCallback);
}

// ─── Crash Recovery ────────────────────────────────────────────────

/**
 * Scan for interrupted downloads and return resumable handles.
 * Call once on app startup, e.g. in App.tsx useEffect.
 *
 * ```ts
 * const pending = await restoreDownloads();
 * for (const dl of pending) {
 *   dl.resumeAsync();
 * }
 * ```
 */
export async function restoreDownloads(): Promise<DownloadResumable[]> {
  const snapshots = await NativeModule.restoreDownloads();
  return snapshots.map((snap) => {
    const dl = new DownloadResumable(snap.url, snap.fileUri, {
      headers: snap.headers,
    });
    dl._setId(snap.downloadId);
    dl._setResumeData(snap.etag || null); // resumeData stored in etag field for recovery
    return dl;
  });
}
