#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "YTMULocalPlayer.h"

// YouTube Music and our local player share one MPRemoteCommandCenter and one MPNowPlayingInfoCenter.
// These hooks wrap YouTube Music's handlers so that while our player is active, the lock screen,
// Control Center, headphones and CarPlay controls drive our queue instead of the YouTube Music one.

static const void *YTMUHostHandlerKey = &YTMUHostHandlerKey;
static const void *YTMUHostTargetsKey = &YTMUHostTargetsKey;
// Non-zero while we are inside MediaPlayer's own add-target code, which may call the other add method internally
static __thread int YTMUCommandHookDepth = 0;

static YTMURemoteHandler YTMUGuardedHandler(YTMURemoteHandler hostHandler) {
    return ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if ([YTMULocalPlayer sharedPlayer].isActive) return MPRemoteCommandHandlerStatusSuccess;
        return hostHandler(event);
    };
}

%hook MPRemoteCommand
- (id)addTargetWithHandler:(YTMURemoteHandler)handler {
    YTMULocalPlayer *localPlayer = [YTMULocalPlayer sharedPlayer];
    if (!handler || YTMUCommandHookDepth > 0 || localPlayer.isUpdatingSystemState) return %orig;

    YTMURemoteHandler hostHandler = [handler copy];
    [localPlayer registerHostHandler:hostHandler forCommand:self];

    YTMUCommandHookDepth++;
    id token = %orig(YTMUGuardedHandler(hostHandler));
    YTMUCommandHookDepth--;
    if (token) objc_setAssociatedObject(token, YTMUHostHandlerKey, hostHandler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return token;
}

- (void)addTarget:(id)target action:(SEL)action {
    YTMULocalPlayer *localPlayer = [YTMULocalPlayer sharedPlayer];
    if (!target || !action || YTMUCommandHookDepth > 0 || localPlayer.isUpdatingSystemState) {
        %orig;
        return;
    }

    __weak id weakTarget = target;
    YTMURemoteHandler hostHandler = ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        id strongTarget = weakTarget;
        if (!strongTarget) return MPRemoteCommandHandlerStatusCommandFailed;

        NSMethodSignature *signature = [strongTarget methodSignatureForSelector:action];
        if (signature.methodReturnLength == 0) {
            ((void (*)(id, SEL, id))objc_msgSend)(strongTarget, action, event);
            return MPRemoteCommandHandlerStatusSuccess;
        }

        return ((MPRemoteCommandHandlerStatus (*)(id, SEL, id))objc_msgSend)(strongTarget, action, event);
    };
    [localPlayer registerHostHandler:hostHandler forCommand:self];

    YTMUCommandHookDepth++;
    id token = [self addTargetWithHandler:YTMUGuardedHandler(hostHandler)];
    YTMUCommandHookDepth--;
    if (!token) return;

    objc_setAssociatedObject(token, YTMUHostHandlerKey, hostHandler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Remember which token stands in for this target/action so removeTarget: still works
    NSMutableArray *entries = objc_getAssociatedObject(self, YTMUHostTargetsKey);
    if (!entries) {
        entries = [NSMutableArray array];
        objc_setAssociatedObject(self, YTMUHostTargetsKey, entries, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [entries addObject:@{@"target": [NSValue valueWithNonretainedObject:target], @"action": NSStringFromSelector(action), @"token": token}];
}

- (void)removeTarget:(id)target action:(SEL)action {
    NSMutableArray *entries = objc_getAssociatedObject(self, YTMUHostTargetsKey);
    for (NSDictionary *entry in [entries copy]) {
        BOOL targetMatches = !target || [entry[@"target"] nonretainedObjectValue] == target;
        BOOL actionMatches = !action || [entry[@"action"] isEqualToString:NSStringFromSelector(action)];
        if (targetMatches && actionMatches) {
            [self removeTarget:entry[@"token"]];
            [entries removeObject:entry];
        }
    }

    %orig;
}

- (void)removeTarget:(id)target {
    if (target) {
        [[YTMULocalPlayer sharedPlayer] unregisterHostHandler:objc_getAssociatedObject(target, YTMUHostHandlerKey)];

        NSMutableArray *entries = objc_getAssociatedObject(self, YTMUHostTargetsKey);
        for (NSDictionary *entry in [entries copy]) {
            if ([entry[@"target"] nonretainedObjectValue] == target) {
                [self removeTarget:entry[@"token"]];
                [entries removeObject:entry];
            }
        }
    }

    %orig;
}

- (void)setEnabled:(BOOL)enabled {
    YTMULocalPlayer *localPlayer = [YTMULocalPlayer sharedPlayer];
    if (localPlayer.isUpdatingSystemState) {
        %orig;
        return;
    }

    // Remember what YouTube Music wants, and apply it once our player hands control back
    [localPlayer hostDidSetEnabled:enabled forCommand:self];
    if (!localPlayer.isActive) %orig;
}
%end

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)nowPlayingInfo {
    YTMULocalPlayer *localPlayer = [YTMULocalPlayer sharedPlayer];
    if (localPlayer.isUpdatingSystemState || self != [MPNowPlayingInfoCenter defaultCenter]) {
        %orig;
        return;
    }

    if ([localPlayer shouldForwardHostNowPlayingInfo:nowPlayingInfo]) %orig;
}
%end

// YouTube Music deactivates the audio session when it pauses, which would cut our audio off
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)outError {
    YTMULocalPlayer *localPlayer = [YTMULocalPlayer sharedPlayer];
    if (!active && localPlayer.isActive && !localPlayer.isUpdatingSystemState) return YES;
    return %orig;
}

- (BOOL)setActive:(BOOL)active error:(NSError **)outError {
    YTMULocalPlayer *localPlayer = [YTMULocalPlayer sharedPlayer];
    if (!active && localPlayer.isActive && !localPlayer.isUpdatingSystemState) return YES;
    return %orig;
}
%end
