#import "RnFileinfo.h"
#import <React/RCTLog.h>
#import <Foundation/Foundation.h>

// ─── RNFIDownloadTask ──────────────────────────────────────────────

@implementation RNFIDownloadTask

- (instancetype)init {
  if (self = [super init]) {
    _totalBytes = -1;
    _downloadedBytes = 0;
    _retryCount = 0;
    _lastProgressAt = 0;
    _lastCheckpointAt = 0;
    _lastCheckpointBytes = 0;
  }
  return self;
}

- (NSString *)metadataPath {
  return [_destinationPath stringByAppendingString:@".download"];
}

- (NSString *)tmpMetadataPath {
  return [_destinationPath stringByAppendingString:@".download.tmp"];
}

- (NSString *)statusString {
  switch (_status) {
    case RNFIStatusIdle:        return @"idle";
    case RNFIStatusStarting:    return @"starting";
    case RNFIStatusDownloading: return @"downloading";
    case RNFIStatusPaused:      return @"paused";
    case RNFIStatusRetrying:    return @"retrying";
    case RNFIStatusCompleted:   return @"completed";
    case RNFIStatusFailed:      return @"failed";
    case RNFIStatusCancelled:   return @"cancelled";
  }
}

- (double)progress {
  if (_totalBytes <= 0) return -1.0;
  return (double)_downloadedBytes / (double)_totalBytes;
}

@end

// ─── RnFileinfo ────────────────────────────────────────────────────

@implementation RnFileinfo

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (instancetype)init {
  if (self = [super init]) {
    _registryLock = OS_UNFAIR_LOCK_INIT;
    _activeTasks = [NSMutableDictionary new];
    _ioQueue = dispatch_queue_create("com.novastera.rnfileinfo.io", DISPATCH_QUEUE_SERIAL);
    _progressEventBody = [NSMutableDictionary dictionaryWithCapacity:4];
    _hasListeners = NO;
  }
  return self;
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeRnFileinfoSpecJSI>(params);
}

// ─── Event Emitter ─────────────────────────────────────────────────

- (NSArray<NSString *> *)supportedEvents {
  return @[@"downloadProgress", @"downloadComplete", @"downloadError", @"downloadPaused"];
}

- (void)startObserving {
  _hasListeners = YES;
}

- (void)stopObserving {
  _hasListeners = NO;
}

- (void)addListener:(NSString *)eventName {
  [super addListener:eventName];
}

- (void)removeListeners:(double)count {
  [super removeListeners:count];
}

// ─── URLSession (Lazy) ─────────────────────────────────────────────

- (NSURLSession *)session {
  if (!_session) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30;
    config.timeoutIntervalForResource = 0; // no resource timeout for large files
    config.HTTPMaximumConnectionsPerHost = 4;
    _session = [NSURLSession sessionWithConfiguration:config
                                             delegate:self
                                        delegateQueue:nil]; // background queue
  }
  return _session;
}

// ─── Registry Helpers ──────────────────────────────────────────────

- (void)registerTask:(RNFIDownloadTask *)task {
  os_unfair_lock_lock(&_registryLock);
  _activeTasks[task.taskId] = task;
  os_unfair_lock_unlock(&_registryLock);
}

- (RNFIDownloadTask *)taskForId:(NSString *)taskId {
  os_unfair_lock_lock(&_registryLock);
  RNFIDownloadTask *task = _activeTasks[taskId];
  os_unfair_lock_unlock(&_registryLock);
  return task;
}

- (RNFIDownloadTask *)taskForNativeTask:(NSURLSessionDownloadTask *)nativeTask {
  os_unfair_lock_lock(&_registryLock);
  RNFIDownloadTask *found = nil;
  for (RNFIDownloadTask *task in _activeTasks.allValues) {
    if (task.nativeTask == nativeTask) {
      found = task;
      break;
    }
  }
  os_unfair_lock_unlock(&_registryLock);
  return found;
}

- (void)removeTaskForId:(NSString *)taskId {
  os_unfair_lock_lock(&_registryLock);
  [_activeTasks removeObjectForKey:taskId];
  os_unfair_lock_unlock(&_registryLock);
}

// ─── Metadata Persistence ──────────────────────────────────────────

- (void)persistMetadata:(RNFIDownloadTask *)task {
  dispatch_async(_ioQueue, ^{
    @autoreleasepool {
      NSDictionary *dict = @{
        @"id":              task.taskId,
        @"url":             task.url,
        @"fileUri":         task.destinationPath,
        @"downloadedBytes": @(task.downloadedBytes),
        @"totalBytes":      @(task.totalBytes),
        @"etag":            task.etag ?: @"",
        @"lastModified":    task.lastModified ?: @"",
        @"status":          [task statusString],
        @"headers":         task.headers ?: @{},
        @"createdAt":       @((int64_t)([[NSDate date] timeIntervalSince1970] * 1000)),
        @"updatedAt":       @((int64_t)([[NSDate date] timeIntervalSince1970] * 1000)),
      };

      NSError *error;
      NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
      if (!json) return;

      // Atomic write: tmp → fsync → rename
      NSString *tmpPath = [task tmpMetadataPath];
      NSString *finalPath = [task metadataPath];
      [json writeToFile:tmpPath atomically:NO];

      int fd = open([tmpPath UTF8String], O_RDONLY);
      if (fd >= 0) {
        fsync(fd);
        close(fd);
      }

      [[NSFileManager defaultManager] moveItemAtPath:tmpPath toPath:finalPath error:nil];
    }
  });
}

- (void)deleteMetadata:(RNFIDownloadTask *)task {
  dispatch_async(_ioQueue, ^{
    [[NSFileManager defaultManager] removeItemAtPath:[task metadataPath] error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:[task tmpMetadataPath] error:nil];
  });
}

// ─── Progress Event Emission ───────────────────────────────────────

- (void)emitProgressForTask:(RNFIDownloadTask *)task {
  if (!_hasListeners) return;

  _progressEventBody[@"downloadId"]   = task.taskId;
  _progressEventBody[@"bytesWritten"] = @(task.downloadedBytes);
  _progressEventBody[@"totalBytes"]   = @(task.totalBytes);
  _progressEventBody[@"progress"]     = @([task progress]);
  [self sendEventWithName:@"downloadProgress" body:[_progressEventBody copy]];
}

- (void)emitComplete:(RNFIDownloadTask *)task {
  if (!_hasListeners) return;
  [self sendEventWithName:@"downloadComplete" body:@{
    @"downloadId": task.taskId,
    @"uri": task.destinationPath,
  }];
}

- (void)emitError:(RNFIDownloadTask *)task errorCode:(NSString *)errorCode message:(NSString *)message {
  if (!_hasListeners) return;
  [self sendEventWithName:@"downloadError" body:@{
    @"downloadId": task.taskId,
    @"errorCode": errorCode,
    @"message": message ?: @"Unknown error",
  }];
}

- (void)emitPaused:(RNFIDownloadTask *)task resumeDataBase64:(NSString *)base64 {
  if (!_hasListeners) return;
  [self sendEventWithName:@"downloadPaused" body:@{
    @"downloadId": task.taskId,
    @"downloadedBytes": @(task.downloadedBytes),
    @"resumeData": base64 ?: @"",
  }];
}

// ─── Path Helper ───────────────────────────────────────────────────

- (NSString *)cleanPath:(NSString *)path {
  if ([path hasPrefix:@"file://"]) {
    return [path substringFromIndex:7];
  }
  return path;
}

// ════════════════════════════════════════════════════════════════════
// FILE INFO METHODS (existing)
// ════════════════════════════════════════════════════════════════════

- (void)getFileInfo:(NSString *)path
            resolve:(RCTPromiseResolveBlock)resolve
             reject:(RCTPromiseRejectBlock)reject
{
  @try {
    NSString *cleanedPath = [self cleanPath:path];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;

    BOOL isDirectory;
    if (![fileManager fileExistsAtPath:cleanedPath isDirectory:&isDirectory]) {
      reject(@"FILE_NOT_FOUND", [NSString stringWithFormat:@"File not found: %@", path], nil);
      return;
    }

    NSDictionary *attributes = [fileManager attributesOfItemAtPath:cleanedPath error:&error];
    if (error) {
      reject(@"FILE_ACCESS_ERROR", [NSString stringWithFormat:@"Cannot access file: %@", error.localizedDescription], error);
      return;
    }

    NSString *fileName = [cleanedPath lastPathComponent];
    NSNumber *fileSize = attributes[NSFileSize];
    NSDate *creationDate = attributes[NSFileCreationDate];
    NSDate *modificationDate = attributes[NSFileModificationDate];

    NSTimeInterval creationTime = [creationDate timeIntervalSince1970] * 1000;
    NSTimeInterval modificationTime = [modificationDate timeIntervalSince1970] * 1000;

    NSDictionary *fileInfo = @{
      @"path": cleanedPath,
      @"name": fileName,
      @"size": fileSize ?: @0,
      @"isFile": @(!isDirectory),
      @"isDirectory": @(isDirectory),
      @"createdAt": @((long long)creationTime),
      @"modifiedAt": @((long long)modificationTime)
    };

    resolve(fileInfo);
  } @catch (NSException *exception) {
    reject(@"UNKNOWN_ERROR", [NSString stringWithFormat:@"Unexpected error: %@", exception.reason], nil);
  }
}

- (void)getDirectoryInfo:(NSString *)path
                 options:(JS::NativeRnFileinfo::SpecGetDirectoryInfoOptions &)options
                 resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject
{
  @try {
    NSString *cleanedPath = [self cleanPath:path];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;

    if (![fileManager fileExistsAtPath:cleanedPath]) {
      reject(@"DIRECTORY_NOT_FOUND", [NSString stringWithFormat:@"Directory not found: %@", path], nil);
      return;
    }

    BOOL isDirectory;
    if (![fileManager fileExistsAtPath:cleanedPath isDirectory:&isDirectory] || !isDirectory) {
      reject(@"NOT_A_DIRECTORY", [NSString stringWithFormat:@"Path is not a directory: %@", path], nil);
      return;
    }

    BOOL recursive = options.recursive().has_value() ? options.recursive().value() : NO;
    BOOL includeHidden = options.includeHidden().has_value() ? options.includeHidden().value() : NO;
    NSInteger maxDepth = options.maxDepth().has_value() ? (NSInteger)options.maxDepth().value() : NSIntegerMax;

    NSMutableArray *fileInfos = [NSMutableArray array];
    [self scanDirectory:cleanedPath
            fileManager:fileManager
               recursive:recursive
           includeHidden:includeHidden
                maxDepth:maxDepth
              currentDepth:0
              fileInfos:fileInfos
                   error:&error];

    if (error) {
      reject(@"DIRECTORY_ACCESS_ERROR", [NSString stringWithFormat:@"Cannot access directory: %@", error.localizedDescription], error);
      return;
    }

    resolve(fileInfos);
  } @catch (NSException *exception) {
    reject(@"UNKNOWN_ERROR", [NSString stringWithFormat:@"Unexpected error: %@", exception.reason], nil);
  }
}

- (void)scanDirectory:(NSString *)directoryPath
          fileManager:(NSFileManager *)fileManager
             recursive:(BOOL)recursive
         includeHidden:(BOOL)includeHidden
              maxDepth:(NSInteger)maxDepth
          currentDepth:(NSInteger)currentDepth
            fileInfos:(NSMutableArray *)fileInfos
                 error:(NSError **)error
{
  if (currentDepth >= maxDepth) {
    return;
  }

  NSArray *contents = [fileManager contentsOfDirectoryAtPath:directoryPath error:error];
  if (*error) {
    return;
  }

  const NSInteger MAX_FILES_PER_BATCH = 1000;
  if (contents.count > MAX_FILES_PER_BATCH) {
    for (NSInteger i = 0; i < contents.count; i += MAX_FILES_PER_BATCH) {
      NSInteger endIndex = MIN(i + MAX_FILES_PER_BATCH, contents.count);
      NSArray *batch = [contents subarrayWithRange:NSMakeRange(i, endIndex - i)];
      [self processFileBatch:batch
                 directoryPath:directoryPath
                    fileManager:fileManager
                      recursive:recursive
                  includeHidden:includeHidden
                       maxDepth:maxDepth
                   currentDepth:currentDepth
                     fileInfos:fileInfos
                          error:error];
      if (*error) {
        return;
      }
    }
    return;
  }

  for (NSString *item in contents) {
    if (!includeHidden && [item hasPrefix:@"."]) {
      continue;
    }

    NSString *fullPath = [directoryPath stringByAppendingPathComponent:item];

    NSDictionary *attributes = [fileManager attributesOfItemAtPath:fullPath error:error];
    if (*error) {
      return;
    }

    NSNumber *fileSize = attributes[NSFileSize];
    NSDate *creationDate = attributes[NSFileCreationDate];
    NSDate *modificationDate = attributes[NSFileModificationDate];
    BOOL isDirectory = [attributes[NSFileType] isEqualToString:NSFileTypeDirectory];

    NSTimeInterval creationTime = [creationDate timeIntervalSince1970] * 1000;
    NSTimeInterval modificationTime = [modificationDate timeIntervalSince1970] * 1000;

    NSDictionary *fileInfo = @{
      @"path": fullPath,
      @"name": item,
      @"size": fileSize ?: @0,
      @"isFile": @(!isDirectory),
      @"isDirectory": @(isDirectory),
      @"createdAt": @((long long)creationTime),
      @"modifiedAt": @((long long)modificationTime),
    };

    [fileInfos addObject:fileInfo];

    if (recursive && isDirectory) {
      [self scanDirectory:fullPath
              fileManager:fileManager
                 recursive:recursive
             includeHidden:includeHidden
                  maxDepth:maxDepth
              currentDepth:currentDepth + 1
                fileInfos:fileInfos
                     error:error];
      if (*error) {
        return;
      }
    }
  }
}

- (void)processFileBatch:(NSArray *)batch
            directoryPath:(NSString *)directoryPath
               fileManager:(NSFileManager *)fileManager
                 recursive:(BOOL)recursive
             includeHidden:(BOOL)includeHidden
                  maxDepth:(NSInteger)maxDepth
              currentDepth:(NSInteger)currentDepth
                fileInfos:(NSMutableArray *)fileInfos
                     error:(NSError **)error
{
  for (NSString *item in batch) {
    if (!includeHidden && [item hasPrefix:@"."]) {
      continue;
    }

    NSString *fullPath = [directoryPath stringByAppendingPathComponent:item];

    NSDictionary *attributes = [fileManager attributesOfItemAtPath:fullPath error:error];
    if (*error) {
      return;
    }

    NSNumber *fileSize = attributes[NSFileSize];
    NSDate *creationDate = attributes[NSFileCreationDate];
    NSDate *modificationDate = attributes[NSFileModificationDate];
    BOOL isDirectory = [attributes[NSFileType] isEqualToString:NSFileTypeDirectory];

    NSTimeInterval creationTime = [creationDate timeIntervalSince1970] * 1000;
    NSTimeInterval modificationTime = [modificationDate timeIntervalSince1970] * 1000;

    NSDictionary *fileInfo = @{
      @"path": fullPath,
      @"name": item,
      @"size": fileSize ?: @0,
      @"isFile": @(!isDirectory),
      @"isDirectory": @(isDirectory),
      @"createdAt": @((long long)creationTime),
      @"modifiedAt": @((long long)modificationTime),
    };

    [fileInfos addObject:fileInfo];

    if (recursive && isDirectory) {
      [self scanDirectory:fullPath
              fileManager:fileManager
                 recursive:recursive
             includeHidden:includeHidden
                  maxDepth:maxDepth
              currentDepth:currentDepth + 1
                fileInfos:fileInfos
                     error:error];
      if (*error) {
        return;
      }
    }
  }
}

- (void)exists:(NSString *)path
       resolve:(RCTPromiseResolveBlock)resolve
        reject:(RCTPromiseRejectBlock)reject
{
  @try {
    NSString *cleanedPath = [self cleanPath:path];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL exists = [fileManager fileExistsAtPath:cleanedPath];
    resolve(@(exists));
  } @catch (NSException *exception) {
    reject(@"UNKNOWN_ERROR", [NSString stringWithFormat:@"Unexpected error: %@", exception.reason], nil);
  }
}

- (void)isFile:(NSString *)path
        resolve:(RCTPromiseResolveBlock)resolve
         reject:(RCTPromiseRejectBlock)reject
{
  @try {
    NSString *cleanedPath = [self cleanPath:path];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory;
    BOOL exists = [fileManager fileExistsAtPath:cleanedPath isDirectory:&isDirectory];
    resolve(@(exists && !isDirectory));
  } @catch (NSException *exception) {
    reject(@"UNKNOWN_ERROR", [NSString stringWithFormat:@"Unexpected error: %@", exception.reason], nil);
  }
}

- (void)isDirectory:(NSString *)path
             resolve:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  @try {
    NSString *cleanedPath = [self cleanPath:path];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory;
    BOOL exists = [fileManager fileExistsAtPath:cleanedPath isDirectory:&isDirectory];
    resolve(@(exists && isDirectory));
  } @catch (NSException *exception) {
    reject(@"UNKNOWN_ERROR", [NSString stringWithFormat:@"Unexpected error: %@", exception.reason], nil);
  }
}

// ════════════════════════════════════════════════════════════════════
// DOWNLOAD MANAGER METHODS
// ════════════════════════════════════════════════════════════════════

- (void)startDownload:(NSString *)downloadId
                  url:(NSString *)url
      destinationPath:(NSString *)destinationPath
              headers:(NSDictionary *)headers
           resumeData:(NSString *)resumeDataBase64
              resolve:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(_ioQueue, ^{
    @try {
      NSString *cleanedDest = [self cleanPath:destinationPath];

      // Path traversal prevention
      if ([cleanedDest rangeOfString:@".."].location != NSNotFound) {
        reject(@"FILE_WRITE_ERROR", @"Invalid destination path: contains '..'", nil);
        return;
      }

      RNFIDownloadTask *task = [RNFIDownloadTask new];
      task.taskId = downloadId;
      task.url = url;
      task.destinationPath = cleanedDest;
      task.headers = headers ?: @{};
      task.status = RNFIStatusStarting;

      // Decode resume data if provided
      if (resumeDataBase64 && resumeDataBase64.length > 0) {
        task.resumeData = [[NSData alloc] initWithBase64EncodedString:resumeDataBase64 options:0];
      }

      [self registerTask:task];
      [self persistMetadata:task];
      [self startDownloadWithTask:task];

      resolve(nil);
    } @catch (NSException *exception) {
      reject(@"START_ERROR", [NSString stringWithFormat:@"Failed to start download: %@", exception.reason], nil);
    }
  });
}

- (void)startDownloadWithTask:(RNFIDownloadTask *)task {
  NSURLSessionDownloadTask *nativeTask;

  if (task.resumeData.length > 0) {
    nativeTask = [self.session downloadTaskWithResumeData:task.resumeData];
  } else {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:task.url]];
    [task.headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *_) {
      [request setValue:v forHTTPHeaderField:k];
    }];

    // Resume headers for range request
    if (task.downloadedBytes > 0) {
      [request setValue:[NSString stringWithFormat:@"bytes=%lld-", task.downloadedBytes]
            forHTTPHeaderField:@"Range"];
      if (task.etag) {
        [request setValue:task.etag forHTTPHeaderField:@"If-Range"];
      }
    }

    nativeTask = [self.session downloadTaskWithRequest:request];
  }

  task.nativeTask = nativeTask;
  task.status = RNFIStatusDownloading;
  [self persistMetadata:task];
  [nativeTask resume];
}

- (void)pauseDownload:(NSString *)downloadId
              resolve:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject
{
  RNFIDownloadTask *task = [self taskForId:downloadId];
  if (!task || task.status != RNFIStatusDownloading) {
    resolve(@"");
    return;
  }

  __weak __typeof(self) weakSelf = self;
  [task.nativeTask cancelByProducingResumeData:^(NSData *resumeData) {
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;

    NSString *encoded = [resumeData base64EncodedStringWithOptions:0] ?: @"";
    task.resumeData = resumeData;
    task.status = RNFIStatusPaused;
    [strongSelf persistMetadata:task];
    [strongSelf emitPaused:task resumeDataBase64:encoded];
    resolve(encoded);
  }];
}

- (void)resumeDownload:(NSString *)downloadId
            resumeData:(NSString *)resumeDataBase64
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(_ioQueue, ^{
    RNFIDownloadTask *task = [self taskForId:downloadId];
    if (!task) {
      reject(@"NOT_FOUND", [NSString stringWithFormat:@"Download not found: %@", downloadId], nil);
      return;
    }

    // Update resume data if provided
    if (resumeDataBase64 && resumeDataBase64.length > 0) {
      task.resumeData = [[NSData alloc] initWithBase64EncodedString:resumeDataBase64 options:0];
    }

    // File size consistency check
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:task.destinationPath]) {
      NSDictionary *attrs = [fm attributesOfItemAtPath:task.destinationPath error:nil];
      int64_t actualSize = [attrs[NSFileSize] longLongValue];
      if (actualSize != task.downloadedBytes) {
        if (actualSize < task.downloadedBytes) {
          task.downloadedBytes = actualSize;
        } else {
          [fm removeItemAtPath:task.destinationPath error:nil];
          task.downloadedBytes = 0;
        }
      }
    }

    task.status = RNFIStatusStarting;
    [self startDownloadWithTask:task];
    resolve(nil);
  });
}

- (void)cancelDownload:(NSString *)downloadId
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject
{
  RNFIDownloadTask *task = [self taskForId:downloadId];
  if (!task) {
    resolve(nil);
    return;
  }

  [task.nativeTask cancel];
  task.status = RNFIStatusCancelled;

  // Clean up files
  dispatch_async(_ioQueue, ^{
    [[NSFileManager defaultManager] removeItemAtPath:task.destinationPath error:nil];
    [self deleteMetadata:task];
    [self removeTaskForId:downloadId];
    resolve(nil);
  });
}

- (void)restoreDownloads:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject
{
  dispatch_async(_ioQueue, ^{
    @try {
      NSFileManager *fm = [NSFileManager defaultManager];
      NSMutableArray *snapshots = [NSMutableArray array];

      // Scan common download directories for .download files
      NSArray *searchPaths = @[
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: @"",
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @"",
        NSTemporaryDirectory(),
      ];

      for (NSString *basePath in searchPaths) {
        if (basePath.length == 0) continue;
        [self scanDirectoryForMetadata:basePath fileManager:fm snapshots:snapshots];
      }

      resolve(snapshots);
    } @catch (NSException *exception) {
      reject(@"RESTORE_ERROR", [NSString stringWithFormat:@"Failed to restore downloads: %@", exception.reason], nil);
    }
  });
}

- (void)scanDirectoryForMetadata:(NSString *)directory
                     fileManager:(NSFileManager *)fm
                       snapshots:(NSMutableArray *)snapshots
{
  NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:directory];
  NSString *fileName;
  while ((fileName = [enumerator nextObject])) {
    if (![fileName hasSuffix:@".download"]) continue;
    if ([fileName hasSuffix:@".download.tmp"]) continue;

    NSString *metadataPath = [directory stringByAppendingPathComponent:fileName];
    NSData *data = [NSData dataWithContentsOfFile:metadataPath];
    if (!data) {
      [fm removeItemAtPath:metadataPath error:nil];
      continue;
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!json || ![json isKindOfClass:[NSDictionary class]]) {
      [fm removeItemAtPath:metadataPath error:nil];
      continue;
    }

    NSString *fileUri = json[@"fileUri"];
    if (!fileUri || ![fm fileExistsAtPath:fileUri]) {
      [fm removeItemAtPath:metadataPath error:nil];
      continue;
    }

    // File size consistency check
    NSDictionary *attrs = [fm attributesOfItemAtPath:fileUri error:nil];
    int64_t actualSize = [attrs[NSFileSize] longLongValue];
    int64_t recordedBytes = [json[@"downloadedBytes"] longLongValue];

    if (actualSize != recordedBytes) {
      if (actualSize < recordedBytes) {
        recordedBytes = actualSize;
      } else {
        [fm removeItemAtPath:fileUri error:nil];
        recordedBytes = 0;
      }
    }

    // Register in memory
    RNFIDownloadTask *task = [RNFIDownloadTask new];
    task.taskId = json[@"id"];
    task.url = json[@"url"];
    task.destinationPath = fileUri;
    task.headers = json[@"headers"] ?: @{};
    task.status = RNFIStatusPaused;
    task.downloadedBytes = recordedBytes;
    task.totalBytes = [json[@"totalBytes"] longLongValue];
    task.etag = json[@"etag"];
    task.lastModified = json[@"lastModified"];
    [self registerTask:task];

    NSDictionary *snapshot = @{
      @"downloadId":     task.taskId ?: @"",
      @"url":            task.url ?: @"",
      @"fileUri":        task.destinationPath ?: @"",
      @"downloadedBytes": @(task.downloadedBytes),
      @"totalBytes":     @(task.totalBytes),
      @"etag":           task.etag ?: @"",
      @"lastModified":   task.lastModified ?: @"",
      @"headers":        task.headers ?: @{},
      @"status":         [task statusString],
    };
    [snapshots addObject:snapshot];
  }
}

- (void)getDownloadStatus:(NSString *)downloadId
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject
{
  RNFIDownloadTask *task = [self taskForId:downloadId];
  if (!task) {
    reject(@"NOT_FOUND", [NSString stringWithFormat:@"Download not found: %@", downloadId], nil);
    return;
  }

  resolve(@{
    @"downloadId":     task.taskId,
    @"status":         [task statusString],
    @"downloadedBytes": @(task.downloadedBytes),
    @"totalBytes":     @(task.totalBytes),
    @"progress":       @([task progress]),
  });
}

// ════════════════════════════════════════════════════════════════════
// NSURLSessionDownloadDelegate
// ════════════════════════════════════════════════════════════════════

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
  RNFIDownloadTask *task = [self taskForNativeTask:downloadTask];
  if (!task) return;

  task.downloadedBytes = totalBytesWritten;
  if (totalBytesExpectedToWrite > 0) {
    task.totalBytes = totalBytesExpectedToWrite;
  }

  int64_t now = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000);

  // Checkpoint metadata
  if ((totalBytesWritten - task.lastCheckpointBytes >= 524288) ||
      (now - task.lastCheckpointAt >= 1000)) {
    task.lastCheckpointBytes = totalBytesWritten;
    task.lastCheckpointAt = now;
    [self persistMetadata:task];
  }

  // Throttled progress event (250ms)
  if (now - task.lastProgressAt >= 250) {
    task.lastProgressAt = now;
    [self emitProgressForTask:task];
  }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
  RNFIDownloadTask *task = [self taskForNativeTask:downloadTask];
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
    task.status = RNFIStatusFailed;
    [self persistMetadata:task];
    [self emitError:task errorCode:@"FILE_WRITE_ERROR" message:error.localizedDescription];
    return;
  }

  // Verify file size if total was known
  if (task.totalBytes > 0) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:task.destinationPath error:nil];
    int64_t actualSize = [attrs[NSFileSize] longLongValue];
    if (actualSize != task.totalBytes) {
      task.status = RNFIStatusFailed;
      [self persistMetadata:task];
      [self emitError:task errorCode:@"SIZE_MISMATCH"
              message:[NSString stringWithFormat:@"Size mismatch: got %lld expected %lld", actualSize, task.totalBytes]];
      return;
    }
  }

  task.status = RNFIStatusCompleted;
  [self deleteMetadata:task];
  [self removeTaskForId:task.taskId];
  [self emitComplete:task];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)sessionTask
didCompleteWithError:(NSError *)error
{
  if (!error) return; // Success handled in didFinishDownloadingToURL

  // Check if this is a cancellation (pause)
  if (error.code == NSURLErrorCancelled) return;

  RNFIDownloadTask *task = [self taskForNativeTask:(NSURLSessionDownloadTask *)sessionTask];
  if (!task) return;

  // Extract resume data from error if available
  NSData *resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
  if (resumeData) {
    task.resumeData = resumeData;
  }

  // Retry logic for retryable errors
  BOOL isRetryable = (error.code == NSURLErrorTimedOut ||
                      error.code == NSURLErrorNetworkConnectionLost ||
                      error.code == NSURLErrorNotConnectedToInternet ||
                      error.code == NSURLErrorCannotConnectToHost);

  if (isRetryable && task.retryCount < 5) {
    task.retryCount++;
    task.status = RNFIStatusRetrying;
    [self persistMetadata:task];

    // Exponential backoff: 1s, 2s, 4s, 8s, 16s
    int64_t delayMs = (int64_t)(pow(2.0, task.retryCount - 1) * 1000);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayMs * NSEC_PER_MSEC), _ioQueue, ^{
      if (task.status == RNFIStatusRetrying) {
        [self startDownloadWithTask:task];
      }
    });
    return;
  }

  // Failed — no more retries
  task.status = RNFIStatusFailed;
  [self persistMetadata:task];

  NSString *errorCode = @"NETWORK_ERROR";
  if (error.code == NSURLErrorTimedOut) {
    errorCode = @"TIMEOUT";
  }

  [self emitError:task errorCode:errorCode message:error.localizedDescription];
}

// Response header inspection for ETag / Content-Range
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
  RNFIDownloadTask *task = [self taskForNativeTask:downloadTask];
  if (!task) return;

  task.downloadedBytes = fileOffset;
  if (expectedTotalBytes > 0) {
    task.totalBytes = expectedTotalBytes;
  }
}

// ─── Cleanup ───────────────────────────────────────────────────────

- (void)invalidate {
  [_session invalidateAndCancel];
  _session = nil;
}

@end
