#import "YTMULocalTrack.h"
#import <AVFoundation/AVFoundation.h>

static NSCache *YTMUThumbnailCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 400;
    });
    return cache;
}

// Aspect-fill crop into a square, so 16:9 video thumbnails look like album covers
static UIImage *YTMUSquareImage(UIImage *image, CGFloat side, CGFloat scale) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    format.opaque = YES;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat ratio = MAX(side / image.size.width, side / image.size.height);
        CGSize drawSize = CGSizeMake(image.size.width * ratio, image.size.height * ratio);
        [image drawInRect:CGRectMake((side - drawSize.width) / 2.0, (side - drawSize.height) / 2.0, drawSize.width, drawSize.height)];
    }];
}

@implementation YTMULocalTrack

+ (NSURL *)libraryURL {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
}

+ (NSArray<YTMULocalTrack *> *)allTracks {
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[self libraryURL]
                                                            includingPropertiesForKeys:@[NSURLCreationDateKey]
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:nil];

    NSMutableArray<YTMULocalTrack *> *tracks = [NSMutableArray array];
    for (NSURL *fileURL in files) {
        NSString *extension = fileURL.pathExtension.lowercaseString;
        if ([extension isEqualToString:@"m4a"] || [extension isEqualToString:@"mp3"]) {
            [tracks addObject:[self trackWithFileURL:fileURL]];
        }
    }

    return tracks;
}

+ (instancetype)trackWithFileURL:(NSURL *)fileURL {
    return [[self alloc] initWithFileURL:fileURL];
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super init];
    if (self) {
        _fileURL = fileURL;
        _fileName = fileURL.lastPathComponent.stringByDeletingPathExtension;

        NSRange separator = [_fileName rangeOfString:@" - "];
        if (separator.location != NSNotFound && separator.location > 0 && NSMaxRange(separator) < _fileName.length) {
            _artist = [_fileName substringToIndex:separator.location];
            _title = [_fileName substringFromIndex:NSMaxRange(separator)];
        } else {
            _title = _fileName;
        }

        NSDate *creationDate = nil;
        [fileURL getResourceValue:&creationDate forKey:NSURLCreationDateKey error:nil];
        _dateAdded = creationDate ?: [NSDate distantPast];
    }

    return self;
}

- (BOOL)isSameFileAsURL:(NSURL *)url {
    return [self.fileURL.path.stringByStandardizingPath isEqualToString:url.path.stringByStandardizingPath];
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[YTMULocalTrack class]]) return NO;
    return [self isSameFileAsURL:((YTMULocalTrack *)object).fileURL];
}

- (NSUInteger)hash {
    return self.fileURL.path.stringByStandardizingPath.hash;
}

- (NSURL *)artworkURL {
    return [[self.fileURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:[self.fileName stringByAppendingPathExtension:@"png"]];
}

- (UIImage *)artworkImage {
    return [UIImage imageWithContentsOfFile:[self artworkURL].path];
}

- (NSString *)thumbnailKeyForSize:(CGFloat)size {
    return [NSString stringWithFormat:@"%@#%.0f", self.fileURL.path, size];
}

- (UIImage *)cachedThumbnailWithSize:(CGFloat)size {
    return [YTMUThumbnailCache() objectForKey:[self thumbnailKeyForSize:size]];
}

- (void)loadThumbnailWithSize:(CGFloat)size completion:(void (^)(UIImage *image))completion {
    UIImage *cached = [self cachedThumbnailWithSize:size];
    if (cached) {
        completion(cached);
        return;
    }

    NSString *key = [self thumbnailKeyForSize:size];
    NSString *artworkPath = [self artworkURL].path;
    CGFloat scale = [UIScreen mainScreen].scale;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *image = [UIImage imageWithContentsOfFile:artworkPath];
        UIImage *thumbnail = image ? YTMUSquareImage(image, size, scale) : nil;
        if (thumbnail) [YTMUThumbnailCache() setObject:thumbnail forKey:key];

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(thumbnail);
        });
    });
}

- (void)loadDurationWithCompletion:(void (^)(NSTimeInterval duration))completion {
    if (self.duration > 0) {
        completion(self.duration);
        return;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:self.fileURL options:nil];
    __weak typeof(self) weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^{
        NSTimeInterval seconds = CMTimeGetSeconds(asset.duration);
        if (!isfinite(seconds) || seconds < 0) seconds = 0;

        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.duration = seconds;
            completion(seconds);
        });
    }];
}

// Every word must appear somewhere in "Author - Title"
- (BOOL)matchesSearchText:(NSString *)text {
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    for (NSString *word in [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
        if (word.length == 0) continue;
        if ([self.fileName rangeOfString:word options:options].location == NSNotFound) return NO;
    }

    return YES;
}

@end
