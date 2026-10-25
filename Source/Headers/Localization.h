#import <Foundation/Foundation.h>
#import <rootless.h>
#import "../Utils/NSBundle+YTMU.h"
#import "ABCSwitch.h"

#define LOC(key) [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:nil table:nil]

// Falls back to the English text when a translation doesn't have the key yet
#define LOC_DEFAULT(key, fallback) [NSBundle.ytmu_defaultBundle localizedStringForKey:key value:fallback table:nil]
