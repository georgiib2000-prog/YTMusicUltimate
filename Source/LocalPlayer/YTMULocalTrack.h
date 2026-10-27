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

// The part of the file that actually plays. trimEnd is 0 when it plays to the end of the file.
@property (nonatomic, readonly) NSTimeInterval trimStart;
@property (nonatomic, readonly) NSTimeInterval trimEnd;
@property (nonatomic, readonly, getter=isTrimmed) BOOL trimmed;
// Length of the part that plays, or 0 if the file's duration isn't known yet
@property (nonatomic, readonly) NSTimeInterval playbackDuration;

- (void)setTrimStart:(NSTimeInterval)start end:(NSTimeInterval)end;
- (void)clearTrim;
+ (void)moveTrimFromURL:(NSURL *)oldURL toURL:(NSURL *)newURL;
+ (void)removeTrimForURL:(NSURL *)fileURL;
+ (void)removeAllTrims;
@end
