import NativeModule from '../NativeRnFileinfo';
import { NativeEventEmitter, NativeModules } from 'react-native';

// ─── Event Emitter ─────────────────────────────────────────────────

const emitter = new NativeEventEmitter(NativeModules.RnFileinfo);

// ─── Types ─────────────────────────────────────────────────────────

export interface DownloadOptions {
  headers?: Record<string, string>;
  md5?: boolean; // optional post-download integrity check
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

export interface DownloadSnapshot {
  url: string;
  fileUri: string;
  headers: Record<string, string>;
  resumeData: string;
}

// ─── DownloadResumable Class ───────────────────────────────────────

export class DownloadResumable {
  private _id: string;
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

  /** Start the download from scratch. Resolves when the file is fully written. */
  async downloadAsync(): Promise<DownloadResult> {
    this._subscribeProgress();
    await NativeModule.startDownload(
      this._id,
      this._url,
      this._fileUri,
      this._options.headers ?? {},
      null
    );
    return this._waitForCompletion();
  }

  /** Pause the download and return a savable snapshot. */
  async pauseAsync(): Promise<DownloadSnapshot> {
    const resumeData = await NativeModule.pauseDownload(this._id);
    this._resumeData = resumeData;
    this._unsubscribeProgress();
    return this.savable();
  }

  /** Resume a previously paused download. Resolves when the file is fully written. */
  async resumeAsync(): Promise<DownloadResult> {
    this._subscribeProgress();
    await NativeModule.resumeDownload(this._id, this._resumeData);
    return this._waitForCompletion();
  }

  /** Cancel and clean up the download. */
  async cancelAsync(): Promise<void> {
    this._unsubscribeProgress();
    await NativeModule.cancelDownload(this._id);
  }

  /** Return a snapshot that can be persisted and used to reconstruct this download. */
  savable(): DownloadSnapshot {
    return {
      url: this._url,
      fileUri: this._fileUri,
      headers: this._options.headers ?? {},
      resumeData: this._resumeData ?? '',
    };
  }

  // ── Internal Helpers ────────────────────────────────────────────

  /** @internal Used by restoreDownloads to set the id from a recovered snapshot */
  _setId(id: string): void {
    this._id = id;
  }

  /** @internal Used by restoreDownloads to set resume data from a recovered snapshot */
  _setResumeData(data: string | null): void {
    this._resumeData = data;
  }

  private _subscribeProgress(): void {
    this._unsubscribeProgress(); // prevent duplicate listeners
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

  private _unsubscribeProgress(): void {
    this._progressSub?.remove();
    this._progressSub = null;
  }

  private _waitForCompletion(): Promise<DownloadResult> {
    return new Promise((resolve, reject) => {
      const completeSub = emitter.addListener('downloadComplete', (e) => {
        if (e.downloadId === this._id) {
          completeSub.remove();
          errorSub.remove();
          this._unsubscribeProgress();
          resolve({ uri: e.uri, status: 'completed', bytesWritten: 0 });
        }
      });
      const errorSub = emitter.addListener('downloadError', (e) => {
        if (e.downloadId === this._id) {
          completeSub.remove();
          errorSub.remove();
          this._unsubscribeProgress();
          reject(new Error(`[${e.errorCode}] ${e.message}`));
        }
      });
    });
  }
}

// ─── ID Generator ──────────────────────────────────────────────────

function _generateId(): string {
  return `dl_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`;
}
