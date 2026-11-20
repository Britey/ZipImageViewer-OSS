#import "ZipImageViewerModule.h"
#import "ZipImageViewer-Swift.h"
#import <React/RCTInvalidating.h>

@interface ZipImageViewerModule () <RCTInvalidating>
@end

@implementation ZipImageViewerModule {
  id _observer;
  BOOL _invalidated;
}
RCT_EXPORT_MODULE(ZipImageViewer)

+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }

- (instancetype)init {
  if ((self = [super init])) {
    __weak ZipImageViewerModule *weakSelf = self;
    _observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"ZipImageViewerNativeStateChanged"
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
          ZipImageViewerModule *owner = weakSelf;
          if (owner && !owner->_invalidated && owner->_eventEmitterCallback) {
            [owner emitOnStateChanged:note.object];
          }
        }];
  }
  return self;
}

- (void)setEventEmitterCallback:(EventEmitterCallbackWrapper *)wrapper {
  // Codegen installs this from its runtime queue; notifications arrive on main.
  // Serialize installation, emission and invalidation without retaining JS as an
  // owner of native operations. Bootstrap snapshots cover pre-install events.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self->_invalidated) { [super setEventEmitterCallback:wrapper]; }
  });
}

- (void)getSnapshot:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    [NativeAppService.shared getSnapshot:^(NSString *value, NSError *error) {
      if (error) { reject(@"native_snapshot", error.localizedDescription, error); }
      else { resolve(value); }
    }];
  });
}

- (void)dispatch:(NSString *)command resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    [NativeAppService.shared dispatch:command completion:^(NSString *value, NSError *error) {
      if (error) { reject(@"native_command", error.localizedDescription, error); }
      else { resolve(value); }
    }];
  });
}

- (void)invalidate {
  // The RN manager invokes this on methodQueue and destroys the generated
  // TurboModule after it returns. Detach synchronously before its C++ callback
  // target can disappear; merely enqueueing this work would race JS reload.
  _invalidated = YES;
  [NativeAppService.shared reactDidDetach];
  if (_observer) {
    [[NSNotificationCenter defaultCenter] removeObserver:_observer];
    _observer = nil;
  }
  _eventEmitterCallback = nullptr;
  // Imports, reader leases and progress belong to NativeAppService, not JS.
}

- (void)dealloc {
  if (_observer) { [[NSNotificationCenter defaultCenter] removeObserver:_observer]; }
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeZipImageViewerSpecJSI>(params);
}
@end
