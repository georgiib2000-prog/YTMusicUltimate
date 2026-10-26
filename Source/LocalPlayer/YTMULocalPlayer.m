#import "YTMULocalPlayer.h"

NSString *const YTMULocalPlayerStateDidChangeNotification = @"YTMULocalPlayerStateDidChangeNotification";
NSString *const YTMULocalPlayerTimeDidChangeNotification = @"YTMULocalPlayerTimeDidChangeNotification";

static void *YTMUPlayerKVOContext = &YTMUPlayerKVOContext;

// Ignore YouTube Music's "I'm playing" reports this long after we take over, while its pause is still landing
static const NSTimeInterval YTMUHostGracePeriod = 2.0;

// MediaRemote command numbers (MRMediaRemoteCommand)
static const unsigned int YTMUMediaRemoteCommandPause = 1;
static const unsigned int YTMUMediaRemoteCommandTogglePlayPause = 2;

@interface MPRemoteCommandEvent (YTMUPrivate)
- (instancetype)initWithCommand:(MPRemoteCommand *)command mediaRemoteType:(unsigned int)mediaRemoteType options:(NSDictionary *)options;
@end

@interface YTMULocalPlayer ()
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) NSMutableArray<YTMULocalTrack *> *mutableQueue;
@property (nonatomic, strong) NSMutableArray<YTMULocalTrack *> *originalQueue;
@property (nonatomic, assign, readwrite) NSInteger currentIndex;
@property (nonatomic, assign, readwrite) YTMURepeatMode repeatMode;
@property (atomic, assign, readwrite, getter=isActive) BOOL active;
@property (atomic, assign, readwrite, getter=isUpdatingSystemState) BOOL updatingSystemState;
@property (nonatomic, assign) BOOL wantsToPlay;
@property (nonatomic, assign) BOOL commandsRegistered;
@property (atomic, strong) NSDate *activationDate;
@property (nonatomic, strong) MPMediaItemArtwork *currentArtwork;
@property (nonatomic, strong) id timeObserver;

// YouTube Music's own remote command handlers, keyed by command
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSMutableArray<YTMURemoteHandler> *> *hostHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSNumber *> *hostEnabledStates;
@property (atomic, copy) NSDictionary *hostNowPlayingInfo;
@end

@implementation YTMULocalPlayer
@synthesize shuffleEnabled = _shuffleEnabled;

+ (instancetype)sharedPlayer {
    static YTMULocalPlayer *sharedPlayer = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedPlayer = [[self alloc] init];
    });
    return sharedPlayer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableQueue = [NSMutableArray array];
        _originalQueue = [NSMutableArray array];
        _hostHandlers = [NSMutableDictionary dictionary];
        _hostEnabledStates = [NSMutableDictionary dictionary];

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(itemDidPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [center addObserver:self selector:@selector(audioSessionInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
        [center addObserver:self selector:@selector(audioRouteChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    }

    return self;
}

// Created on first playback rather than in init, because the system hooks touch sharedPlayer during app launch
- (AVPlayer *)player {
    if (!_player) {
        _player = [[AVPlayer alloc] init];
        [_player addObserver:self forKeyPath:@"timeControlStatus" options:NSKeyValueObservingOptionNew context:YTMUPlayerKVOContext];

        __weak typeof(self) weakSelf = self;
        _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, 600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
            [[NSNotificationCenter defaultCenter] postNotificationName:YTMULocalPlayerTimeDidChangeNotification object:weakSelf];
        }];
    }

    return _player;
}

#pragma mark - State

- (NSArray<YTMULocalTrack *> *)queue {
    return [self.mutableQueue copy];
}

- (YTMULocalTrack *)currentTrack {
    if (self.currentIndex < 0 || self.currentIndex >= (NSInteger)self.mutableQueue.count) return nil;
    return self.mutableQueue[self.currentIndex];
}

- (BOOL)isPlaying {
    AVPlayer *player = _player;
    return self.active && player.currentItem && player.timeControlStatus != AVPlayerTimeControlStatusPaused;
}

- (NSTimeInterval)currentTime {
    AVPlayer *player = _player;
    if (!player.currentItem) return 0;

    NSTimeInterval seconds = CMTimeGetSeconds(player.currentTime);
    return isfinite(seconds) && seconds > 0 ? seconds : 0;
}

- (NSTimeInterval)duration {
    AVPlayerItem *item = _player.currentItem;
    if (item) {
        NSTimeInterval seconds = CMTimeGetSeconds(item.duration);
        if (isfinite(seconds) && seconds > 0) return seconds;
    }
    return self.currentTrack.duration;
}

- (void)postStateChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMULocalPlayerStateDidChangeNotification object:self];
}

#pragma mark - Queue

- (NSMutableArray<YTMULocalTrack *> *)shuffledTracks:(NSArray<YTMULocalTrack *> *)tracks keepingFirst:(YTMULocalTrack *)first {
    NSMutableArray<YTMULocalTrack *> *shuffled = [tracks mutableCopy];
    NSUInteger firstIndex = first ? [shuffled indexOfObjectIdenticalTo:first] : NSNotFound;
    if (firstIndex != NSNotFound) [shuffled removeObjectAtIndex:firstIndex];

    for (NSUInteger i = shuffled.count; i > 1; i--) {
        [shuffled exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    }

    if (firstIndex != NSNotFound) [shuffled insertObject:first atIndex:0];
    return shuffled;
}

- (void)playTracks:(NSArray<YTMULocalTrack *> *)tracks startingAtIndex:(NSInteger)index {
    if (tracks.count == 0) return;

    index = MAX(0, MIN(index, (NSInteger)tracks.count - 1));
    self.originalQueue = [tracks mutableCopy];

    if (self.shuffleEnabled) {
        self.mutableQueue = [self shuffledTracks:tracks keepingFirst:tracks[index]];
        self.currentIndex = 0;
    } else {
        self.mutableQueue = [tracks mutableCopy];
        self.currentIndex = index;
    }

    [self loadCurrentTrackAndPlay:YES];
}

- (void)shuffleTracks:(NSArray<YTMULocalTrack *> *)tracks {
    if (tracks.count == 0) return;

    _shuffleEnabled = YES;
    [self playTracks:tracks startingAtIndex:arc4random_uniform((uint32_t)tracks.count)];
}

- (void)setShuffleEnabled:(BOOL)shuffleEnabled {
    if (_shuffleEnabled == shuffleEnabled) return;
    _shuffleEnabled = shuffleEnabled;

    YTMULocalTrack *current = self.currentTrack;
    if (current) {
        if (shuffleEnabled) {
            self.mutableQueue = [self shuffledTracks:self.originalQueue keepingFirst:current];
            self.currentIndex = 0;
        } else {
            self.mutableQueue = [self.originalQueue mutableCopy];
            NSUInteger index = [self.mutableQueue indexOfObjectIdenticalTo:current];
            self.currentIndex = index == NSNotFound ? 0 : index;
        }
    }

    [self updateNowPlayingInfo];
    [self postStateChange];
}

- (void)cycleRepeatMode {
    self.repeatMode = (self.repeatMode + 1) % 3;
    [self postStateChange];
}

- (void)playNext:(YTMULocalTrack *)track {
    YTMULocalTrack *current = self.currentTrack;
    if (!current) {
        [self playTracks:@[track] startingAtIndex:0];
        return;
    }

    [self.mutableQueue insertObject:track atIndex:self.currentIndex + 1];

    NSUInteger originalIndex = [self.originalQueue indexOfObjectIdenticalTo:current];
    [self.originalQueue insertObject:track atIndex:originalIndex == NSNotFound ? self.originalQueue.count : originalIndex + 1];

    [self updateNowPlayingInfo];
    [self postStateChange];
}

- (void)addToQueue:(YTMULocalTrack *)track {
    if (!self.currentTrack) {
        [self playTracks:@[track] startingAtIndex:0];
        return;
    }

    [self.mutableQueue addObject:track];
    [self.originalQueue addObject:track];

    [self updateNowPlayingInfo];
    [self postStateChange];
}

- (void)playQueueIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.mutableQueue.count) return;

    self.currentIndex = index;
    [self loadCurrentTrackAndPlay:YES];
}

// Drops every copy of the file from the queue, keeping currentIndex on the same song or on the one that moved into its place
- (BOOL)removeFromQueues:(NSURL *)fileURL {
    YTMULocalTrack *current = self.currentTrack;
    BOOL currentRemoved = [current isSameFileAsURL:fileURL];

    NSInteger removedBeforeCurrent = 0;
    for (NSInteger i = 0; i < self.currentIndex && i < (NSInteger)self.mutableQueue.count; i++) {
        if ([self.mutableQueue[i] isSameFileAsURL:fileURL]) removedBeforeCurrent++;
    }

    NSPredicate *keep = [NSPredicate predicateWithBlock:^BOOL(YTMULocalTrack *track, NSDictionary *bindings) {
        return ![track isSameFileAsURL:fileURL];
    }];
    [self.mutableQueue filterUsingPredicate:keep];
    [self.originalQueue filterUsingPredicate:keep];

    if (currentRemoved) {
        self.currentIndex = MAX(0, MIN(self.currentIndex - removedBeforeCurrent, (NSInteger)self.mutableQueue.count - 1));
    } else if (current) {
        NSUInteger index = [self.mutableQueue indexOfObjectIdenticalTo:current];
        self.currentIndex = index == NSNotFound ? 0 : index;
    }

    return currentRemoved;
}

- (void)trackWasRemoved:(NSURL *)fileURL {
    if (!self.currentTrack) return;

    BOOL wasPlaying = self.isPlaying;
    BOOL currentRemoved = [self removeFromQueues:fileURL];

    if (self.mutableQueue.count == 0) {
        [self stop];
        return;
    }

    if (currentRemoved) {
        [self loadCurrentTrackAndPlay:wasPlaying];
    } else {
        [self updateNowPlayingInfo];
        [self postStateChange];
    }
}

- (void)trackWasRenamedFrom:(NSURL *)oldURL to:(NSURL *)newURL {
    YTMULocalTrack *renamed = [YTMULocalTrack trackWithFileURL:newURL];
    BOOL currentRenamed = [self.currentTrack isSameFileAsURL:oldURL];

    for (NSMutableArray<YTMULocalTrack *> *queue in @[self.mutableQueue, self.originalQueue]) {
        for (NSUInteger i = 0; i < queue.count; i++) {
            if ([queue[i] isSameFileAsURL:oldURL]) {
                renamed.duration = queue[i].duration;
                queue[i] = renamed;
            }
        }
    }

    // The open file handle keeps playing after the move; only the metadata needs refreshing
    if (currentRenamed) {
        self.currentArtwork = [self artworkForTrack:renamed];
        [self updateNowPlayingInfo];
    }

    [self postStateChange];
}

#pragma mark - Playback

- (MPMediaItemArtwork *)artworkForTrack:(YTMULocalTrack *)track {
    UIImage *image = [track artworkImage];
    if (!image || image.size.width <= 0 || image.size.height <= 0) return nil;

    return [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage *(CGSize size) {
        return image;
    }];
}

- (void)loadCurrentTrackAndPlay:(BOOL)shouldPlay {
    // Skip songs whose files were deleted outside the app (each pass removes one, so this ends)
    NSFileManager *fileManager = [NSFileManager defaultManager];
    while (self.currentTrack && ![fileManager fileExistsAtPath:self.currentTrack.fileURL.path]) {
        [self removeFromQueues:self.currentTrack.fileURL];
    }

    YTMULocalTrack *track = self.currentTrack;
    if (!track) {
        [self stop];
        return;
    }

    if (shouldPlay) [self activateIfNeeded];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:track.fileURL options:nil];
    if (track.duration <= 0) {
        NSTimeInterval seconds = CMTimeGetSeconds(asset.duration);
        if (isfinite(seconds) && seconds > 0) track.duration = seconds;
    }

    [self.player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];
    self.currentArtwork = [self artworkForTrack:track];

    self.wantsToPlay = shouldPlay;
    if (shouldPlay) [self.player play];

    [self updateNowPlayingInfo];
    [self postStateChange];
}

- (void)play {
    if (!self.currentTrack) return;
    if (!self.player.currentItem) {
        [self loadCurrentTrackAndPlay:YES];
        return;
    }

    [self activateIfNeeded];
    self.wantsToPlay = YES;
    [self.player play];

    [self updateNowPlayingInfo];
    [self postStateChange];
}

- (void)pause {
    self.wantsToPlay = NO;
    [_player pause];

    [self updateNowPlayingInfo];
    [self postStateChange];
}

- (void)togglePlayPause {
    self.isPlaying ? [self pause] : [self play];
}

- (void)nextTrack {
    if (self.mutableQueue.count == 0) return;

    NSInteger next = self.currentIndex + 1;
    if (next >= (NSInteger)self.mutableQueue.count) {
        // End of the queue: wrap around, but only keep playing when repeat is on
        self.currentIndex = 0;
        [self loadCurrentTrackAndPlay:self.repeatMode != YTMURepeatModeOff];
        return;
    }

    self.currentIndex = next;
    [self loadCurrentTrackAndPlay:YES];
}

- (void)previousTrack {
    if (self.mutableQueue.count == 0) return;

    if (self.currentTime > 3.0) {
        [self seekToTime:0];
        return;
    }

    if (self.currentIndex > 0) {
        self.currentIndex -= 1;
    } else if (self.repeatMode == YTMURepeatModeAll) {
        self.currentIndex = self.mutableQueue.count - 1;
    } else {
        [self seekToTime:0];
        return;
    }

    [self loadCurrentTrackAndPlay:YES];
}

- (void)seekToTime:(NSTimeInterval)time {
    if (!_player.currentItem || !isfinite(time)) return;

    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:CMTimeMakeWithSeconds(MAX(0, time), 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf updateNowPlayingInfo];
            [[NSNotificationCenter defaultCenter] postNotificationName:YTMULocalPlayerTimeDidChangeNotification object:weakSelf];
        });
    }];
}

- (void)stop {
    self.wantsToPlay = NO;
    [_player pause];
    [_player replaceCurrentItemWithPlayerItem:nil];
    [self.mutableQueue removeAllObjects];
    [self.originalQueue removeAllObjects];
    self.currentIndex = 0;
    self.currentArtwork = nil;

    [self deactivate];
    [self postStateChange];
}

- (void)itemDidPlayToEnd:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_player.currentItem || notification.object != self->_player.currentItem) return;

        if (self.repeatMode == YTMURepeatModeOne) {
            [self seekToTime:0];
            [self.player play];
        } else if (self.currentIndex + 1 < (NSInteger)self.mutableQueue.count) {
            self.currentIndex += 1;
            [self loadCurrentTrackAndPlay:YES];
        } else if (self.repeatMode == YTMURepeatModeAll) {
            self.currentIndex = 0;
            [self loadCurrentTrackAndPlay:YES];
        } else {
            self.wantsToPlay = NO;
            [self->_player pause];
            [self seekToTime:0];
            [self postStateChange];
        }
    });
}

- (void)audioSessionInterrupted:(NSNotification *)notification {
    NSUInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    NSUInteger options = [notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];

    if (type == AVAudioSessionInterruptionTypeEnded && (options & AVAudioSessionInterruptionOptionShouldResume)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.active && self.wantsToPlay) [self play];
        });
    }
}

- (void)audioRouteChanged:(NSNotification *)notification {
    NSUInteger reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.active) [self pause];
        });
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != YTMUPlayerKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateNowPlayingInfo];
        [self postStateChange];
    });
}

#pragma mark - Lock screen / Control Center

- (void)updateNowPlayingInfo {
    YTMULocalTrack *track = self.currentTrack;
    if (!self.active || !track) return;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = track.title;
    if (track.artist) info[MPMediaItemPropertyArtist] = track.artist;
    if (self.currentArtwork) info[MPMediaItemPropertyArtwork] = self.currentArtwork;
    info[MPMediaItemPropertyPlaybackDuration] = @(self.duration);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.currentTime);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.isPlaying ? 1.0 : 0.0);
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @1.0;
    info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = @(self.currentIndex);
    info[MPNowPlayingInfoPropertyPlaybackQueueCount] = @(self.mutableQueue.count);
    info[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeAudio);

    self.updatingSystemState = YES;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
    self.updatingSystemState = NO;
}

- (MPRemoteCommandHandlerStatus)handleRemoteAction:(dispatch_block_t)action {
    // While YouTube Music owns playback, its own handlers do the work
    if (!self.active) return MPRemoteCommandHandlerStatusSuccess;

    if ([NSThread isMainThread]) {
        action();
    } else {
        dispatch_async(dispatch_get_main_queue(), action);
    }

    return MPRemoteCommandHandlerStatusSuccess;
}

- (void)registerRemoteCommandsIfNeeded {
    if (self.commandsRegistered) return;
    self.commandsRegistered = YES;

    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    __weak typeof(self) weakSelf = self;

    self.updatingSystemState = YES;
    [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        return [weakSelf handleRemoteAction:^{ [weakSelf play]; }];
    }];
    [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        return [weakSelf handleRemoteAction:^{ [weakSelf pause]; }];
    }];
    [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        return [weakSelf handleRemoteAction:^{ [weakSelf togglePlayPause]; }];
    }];
    [center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        return [weakSelf handleRemoteAction:^{ [weakSelf nextTrack]; }];
    }];
    [center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        return [weakSelf handleRemoteAction:^{ [weakSelf previousTrack]; }];
    }];
    [center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NSTimeInterval position = ((MPChangePlaybackPositionCommandEvent *)event).positionTime;
        return [weakSelf handleRemoteAction:^{ [weakSelf seekToTime:position]; }];
    }];
    self.updatingSystemState = NO;
}

- (NSArray<MPRemoteCommand *> *)localCommands {
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    return @[center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand];
}

// Commands YouTube Music may show that mean nothing for local files
- (NSArray<MPRemoteCommand *> *)hiddenCommands {
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    return @[center.skipForwardCommand, center.skipBackwardCommand, center.seekForwardCommand, center.seekBackwardCommand, center.likeCommand, center.dislikeCommand, center.bookmarkCommand, center.changeRepeatModeCommand, center.changeShuffleModeCommand, center.changePlaybackRateCommand];
}

- (void)applyLocalCommandStates {
    @synchronized (self.hostEnabledStates) {
        [self.hostEnabledStates removeAllObjects];
        for (MPRemoteCommand *command in [[self localCommands] arrayByAddingObjectsFromArray:[self hiddenCommands]]) {
            self.hostEnabledStates[[NSValue valueWithNonretainedObject:command]] = @(command.isEnabled);
        }
    }

    self.updatingSystemState = YES;
    for (MPRemoteCommand *command in [self localCommands]) command.enabled = YES;
    for (MPRemoteCommand *command in [self hiddenCommands]) command.enabled = NO;
    self.updatingSystemState = NO;
}

- (void)restoreHostCommandStates {
    NSDictionary<NSValue *, NSNumber *> *states;
    @synchronized (self.hostEnabledStates) {
        states = [self.hostEnabledStates copy];
        [self.hostEnabledStates removeAllObjects];
    }

    self.updatingSystemState = YES;
    for (MPRemoteCommand *command in [[self localCommands] arrayByAddingObjectsFromArray:[self hiddenCommands]]) {
        NSNumber *enabled = states[[NSValue valueWithNonretainedObject:command]];
        if (enabled) command.enabled = enabled.boolValue;
    }
    self.updatingSystemState = NO;
}

#pragma mark - Handing playback between YouTube Music and us

- (void)activateIfNeeded {
    if (self.active) return;

    [self pauseHost];

    self.active = YES;
    self.activationDate = [NSDate date];

    AVAudioSession *session = [AVAudioSession sharedInstance];
    self.updatingSystemState = YES;
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayback]) {
        [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    }
    [session setActive:YES error:nil];
    self.updatingSystemState = NO;

    [self registerRemoteCommandsIfNeeded];
    [self applyLocalCommandStates];

    // If YouTube Music shrugged off the first pause, try once more after it settles
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(YTMUHostGracePeriod * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.active && [self.hostNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] doubleValue] > 0) {
            [self pauseHost];
        }
    });
}

- (void)deactivate {
    if (!self.active) return;

    self.active = NO;
    self.wantsToPlay = NO;
    [_player pause];
    [self restoreHostCommandStates];

    self.updatingSystemState = YES;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.hostNowPlayingInfo;
    self.updatingSystemState = NO;
}

- (NSArray<YTMURemoteHandler> *)hostHandlersForCommand:(MPRemoteCommand *)command {
    @synchronized (self.hostHandlers) {
        return [self.hostHandlers[[NSValue valueWithNonretainedObject:command]] copy] ?: @[];
    }
}

- (void)pauseHost {
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    BOOL hostPlaying = [self.hostNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] doubleValue] > 0;

    MPRemoteCommand *command = center.pauseCommand;
    unsigned int mediaRemoteType = YTMUMediaRemoteCommandPause;
    NSArray<YTMURemoteHandler> *handlers = [self hostHandlersForCommand:command];

    // Toggle is only safe when we know it's playing, otherwise it would start it
    if (handlers.count == 0 && hostPlaying) {
        command = center.togglePlayPauseCommand;
        mediaRemoteType = YTMUMediaRemoteCommandTogglePlayPause;
        handlers = [self hostHandlersForCommand:command];
    }

    if (handlers.count == 0) return;

    MPRemoteCommandEvent *event = [self eventForCommand:command mediaRemoteType:mediaRemoteType];
    if (!event) return;

    for (YTMURemoteHandler handler in handlers) {
        @try {
            handler(event);
        } @catch (NSException *exception) {
            NSLog(@"[YTMusicUltimate] Pausing YouTube Music failed: %@", exception);
        }
    }
}

// -[MPRemoteCommandEvent init] throws, so build the event the way MediaPlayer does internally
- (MPRemoteCommandEvent *)eventForCommand:(MPRemoteCommand *)command mediaRemoteType:(unsigned int)mediaRemoteType {
    SEL initializer = @selector(initWithCommand:mediaRemoteType:options:);
    if (![MPRemoteCommandEvent instancesRespondToSelector:initializer]) return nil;

    @try {
        return [[MPRemoteCommandEvent alloc] initWithCommand:command mediaRemoteType:mediaRemoteType options:@{}];
    } @catch (NSException *exception) {
        NSLog(@"[YTMusicUltimate] Couldn't create a pause event: %@", exception);
        return nil;
    }
}

// YouTube Music started playing something itself: step aside, but keep our queue so it can be resumed
- (void)hostDidStartPlayback {
    if (!self.active) return;

    [self deactivate];
    [self postStateChange];
}

- (void)registerHostHandler:(YTMURemoteHandler)handler forCommand:(MPRemoteCommand *)command {
    if (!handler || !command) return;

    @synchronized (self.hostHandlers) {
        NSValue *key = [NSValue valueWithNonretainedObject:command];
        if (!self.hostHandlers[key]) self.hostHandlers[key] = [NSMutableArray array];
        [self.hostHandlers[key] addObject:handler];
    }
}

- (void)unregisterHostHandler:(YTMURemoteHandler)handler {
    if (!handler) return;

    @synchronized (self.hostHandlers) {
        for (NSMutableArray<YTMURemoteHandler> *handlers in self.hostHandlers.allValues) {
            [handlers removeObjectIdenticalTo:handler];
        }
    }
}

- (void)hostDidSetEnabled:(BOOL)enabled forCommand:(MPRemoteCommand *)command {
    @synchronized (self.hostEnabledStates) {
        NSValue *key = [NSValue valueWithNonretainedObject:command];
        if (self.hostEnabledStates[key]) self.hostEnabledStates[key] = @(enabled);
    }
}

- (BOOL)shouldForwardHostNowPlayingInfo:(NSDictionary *)nowPlayingInfo {
    self.hostNowPlayingInfo = nowPlayingInfo;
    if (!self.active) return YES;

    BOOL hostPlaying = [nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] doubleValue] > 0;
    if (hostPlaying && -[self.activationDate timeIntervalSinceNow] > YTMUHostGracePeriod) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hostDidStartPlayback];
        });
        return YES;
    }

    return NO;
}

@end
