#import <UIKit/UIKit.h>

// A downloaded audio file in Documents/YTMusicUltimate, named "Author - Title.m4a" with an optional "Author - Title.png" cover
@interface YTMULocalTrack : NSObject
@property (nonatomic, strong, readonly) NSURL *fileURL;
@property (nonatomic, copy, readonly) NSString *fileName;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *artist;
@property (nonatomic, strong, readonly) NSDate *dateAdded;
@property (nonatomic, assign) NSTimeInterval duration;

+ (NSURL *)libraryURL;
+ (NSArray<YTMULocalTrack *> *)allTracks;
+ (instancetype)trackWithFileURL:(NSURL *)fileURL;

- (NSURL *)artworkURL;
- (UIImage *)artworkImage;
- (UIImage *)cachedThumbnailWithSize:(CGFloat)size;
- (void)loadThumbnailWithSize:(CGFloat)size completion:(void (^)(UIImage *image))completion;
- (void)loadDurationWithCompletion:(void (^)(NSTimeInterval duration))completion;
- (BOOL)matchesSearchText:(NSString *)text;
- (BOOL)isSameFileAsURL:(NSURL *)url;
@end
