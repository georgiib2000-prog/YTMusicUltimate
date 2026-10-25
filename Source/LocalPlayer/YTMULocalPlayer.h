#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import "YTMULocalTrack.h"

typedef NS_ENUM(NSInteger, YTMURepeatMode) {
    YTMURepeatModeOff,
    YTMURepeatModeAll,
    YTMURepeatModeOne
};

typedef MPRemoteCommandHandlerStatus (^YTMURemoteHandler)(MPRemoteCommandEvent *event);

// Posted on the main queue whenever the track, queue or play state changes
extern NSString *const YTMULocalPlayerStateDidChangeNotification;
// Posted on the main queue twice a second while a track is loaded
extern NSString *const YTMULocalPlayerTimeDidChangeNotification;

@interface YTMULocalPlayer : NSObject
@property (nonatomic, readonly) NSArray<YTMULocalTrack *> *queue;
@property (nonatomic, readonly) NSInteger currentIndex;
@property (nonatomic, readonly) YTMULocalTrack *currentTrack;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) YTMURepeatMode repeatMode;
@property (nonatomic, assign, getter=isShuffleEnabled) BOOL shuffleEnabled;
@property (nonatomic, readonly, getter=isPlaying) BOOL playing;

// YES while our player owns the lock screen and remote controls instead of YouTube Music's
@property (atomic, readonly, getter=isActive) BOOL active;
// YES while we talk to MPRemoteCommandCenter / MPNowPlayingInfoCenter / AVAudioSession ourselves, so the hooks let us through
@property (atomic, readonly, getter=isUpdatingSystemState) BOOL updatingSystemState;

+ (instancetype)sharedPlayer;

- (void)playTracks:(NSArray<YTMULocalTrack *> *)tracks startingAtIndex:(NSInteger)index;
- (void)shuffleTracks:(NSArray<YTMULocalTrack *> *)tracks;
- (void)playNext:(YTMULocalTrack *)track;
- (void)addToQueue:(YTMULocalTrack *)track;
- (void)playQueueIndex:(NSInteger)index;

- (void)play;
- (void)pause;
- (void)togglePlayPause;
- (void)nextTrack;
- (void)previousTrack;
- (void)seekToTime:(NSTimeInterval)time;
- (void)stop;
- (void)cycleRepeatMode;

- (void)trackWasRemoved:(NSURL *)fileURL;
- (void)trackWasRenamedFrom:(NSURL *)oldURL to:(NSURL *)newURL;

// Bridge for YTMULocalPlayerHooks.x
- (void)registerHostHandler:(YTMURemoteHandler)handler forCommand:(MPRemoteCommand *)command;
- (void)unregisterHostHandler:(YTMURemoteHandler)handler;
- (void)hostDidSetEnabled:(BOOL)enabled forCommand:(MPRemoteCommand *)command;
- (BOOL)shouldForwardHostNowPlayingInfo:(NSDictionary *)nowPlayingInfo;
@end
