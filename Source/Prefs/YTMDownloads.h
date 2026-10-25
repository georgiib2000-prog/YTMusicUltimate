#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "../Headers/YTAlertView.h"
#import "../Headers/YTMToastController.h"
#import "../Headers/YTMActionSheetController.h"
#import "../Headers/Localization.h"

// "My Music" tab: every downloaded song or video, searchable, with a full player
@interface YTMDownloads : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@end
