#import <React/RCTEventEmitter.h>
#import <RnFileinfoSpec/RnFileinfoSpec.h>
#import <os/lock.h>

NS_ASSUME_NONNULL_BEGIN

// ─── Download Status ───────────────────────────────────────────────

typedef NS_ENUM(NSInteger, RNFIDownloadStatus) {
  RNFIStatusIdle,
  RNFIStatusStarting,
  RNFIStatusDownloading,
  RNFIStatusPaused,
  RNFIStatusRetrying,
  RNFIStatusCompleted,
  RNFIStatusFailed,
  RNFIStatusCancelled,
};

// ─── Download Task Model ───────────────────────────────────────────

@interface RNFIDownloadTask : NSObject

@property (nonatomic, strong) NSString *taskId;
@property (nonatomic, strong) NSString *url;
@property (nonatomic, strong) NSString *destinationPath;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, assign) RNFIDownloadStatus status;
@property (nonatomic, assign) int64_t downloadedBytes;
@property (nonatomic, assign) int64_t totalBytes;
@property (nonatomic, strong, nullable) NSString *etag;
@property (nonatomic, strong, nullable) NSString *lastModified;
@property (nonatomic, strong, nullable) NSData *resumeData;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *nativeTask;
@property (nonatomic, assign) int64_t lastProgressAt;
@property (nonatomic, assign) int64_t lastCheckpointAt;
@property (nonatomic, assign) int64_t lastCheckpointBytes;
@property (nonatomic, assign) int retryCount;

- (NSString *)metadataPath;
- (NSString *)tmpMetadataPath;
- (NSString *)statusString;
- (double)progress;

@end

// ─── Module ────────────────────────────────────────────────────────

@interface RnFileinfo : RCTEventEmitter <NativeRnFileinfoSpec, NSURLSessionDownloadDelegate, NSURLSessionTaskDelegate>
{
  NSURLSession *_session;
  NSMutableDictionary<NSString *, RNFIDownloadTask *> *_activeTasks;
  os_unfair_lock _registryLock;
  dispatch_queue_t _ioQueue;
  NSMutableDictionary *_progressEventBody;
  BOOL _hasListeners;
}

@end

NS_ASSUME_NONNULL_END