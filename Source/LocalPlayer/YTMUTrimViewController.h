#import <UIKit/UIKit.h>
#import "YTMULocalTrack.h"

// Lets the user pick the start and end of the part of a song that plays
@interface YTMUTrimViewController : UIViewController
- (instancetype)initWithTrack:(YTMULocalTrack *)track;
@end
