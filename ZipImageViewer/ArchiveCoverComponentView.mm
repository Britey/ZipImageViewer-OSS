#import <React/RCTViewComponentView.h>
#import <react/renderer/components/ZipImageViewerSpec/ComponentDescriptors.h>
#import <react/renderer/components/ZipImageViewerSpec/Props.h>
#import "ZipImageViewer-Swift.h"

using namespace facebook::react;

@interface ArchiveCoverComponentView : RCTViewComponentView
@end

@implementation ArchiveCoverComponentView {
  ArchiveCoverView *_cover;
}
+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<ZIVArchiveCoverComponentDescriptor>();
}
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _props = std::make_shared<const ZIVArchiveCoverProps>();
    _cover = [[ArchiveCoverView alloc] initWithFrame:self.bounds];
    self.contentView = _cover;
  }
  return self;
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &previous = *std::static_pointer_cast<const ZIVArchiveCoverProps>(_props);
  const auto &next = *std::static_pointer_cast<const ZIVArchiveCoverProps>(props);
  if (previous.archiveId != next.archiveId || previous.readerId != next.readerId || previous.pageIndex != next.pageIndex) {
    [_cover setSource:[NSString stringWithUTF8String:next.archiveId.c_str()]
        readerID:[NSString stringWithUTF8String:next.readerId.c_str()] pageIndex:next.pageIndex];
  }
  [super updateProps:props oldProps:oldProps];
}
- (void)prepareForRecycle {
  [_cover reset];
  [super prepareForRecycle];
  _props = std::make_shared<const ZIVArchiveCoverProps>();
}
@end
