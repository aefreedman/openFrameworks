//
//  AVSoundPlayer.m
//  Created by lukasz karluk on 14/06/12.
//  http://julapy.com/blog
//

#include "ofxiOSConstants.h"
#if defined(OF_IOS_AVSOUNDPLAYER)
#import "AVSoundPlayer.h"
#include <TargetConditionals.h>
@interface AVSoundPlayer() {
    BOOL bMultiPlay;
    BOOL asyncReplay;
    BOOL preparing;
    BOOL committing;
    BOOL pendingPlay;
    BOOL deferredStop;
    BOOL deferredPause;
    BOOL positionChanged;
    NSUInteger lifetimeGeneration;
    NSUInteger requestGeneration;
    float desiredVolume, desiredPan, desiredRate;
    NSInteger desiredLoops;
    NSTimeInterval cachedTime, cachedDuration;
    dispatch_queue_t preparationQueue;
}
@end

@implementation AVSoundPlayer

- (instancetype)init {
    self = [super init];
    if(self) {
        bMultiPlay = NO;
        asyncReplay = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"ofxiOSAsyncAudioReplay"] boolValue];
        if (asyncReplay) preparationQueue = dispatch_queue_create("org.openframeworks.audio-replay-preparation", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// setupSharedSession is to prevent other iOS Classes closing the audio feed, such as AVAssetReader, when reading from disk
// It is set once on first launch of a AVAudioPlayer and remains as a set property from then on
- (void) setupSharedSession {
    // Opt-in apps configure/activate their session before loading players.
    if ([[[NSBundle mainBundle] objectForInfoDictionaryKey:@"ofxiOSAppManagedAudioSession"] boolValue]) return;
	static BOOL audioSessionSetup = NO;
	if(audioSessionSetup) {
		return;
	}
	NSString * playbackCategory = AVAudioSessionCategoryPlayAndRecord;
#ifdef TARGET_OS_TV
	playbackCategory = AVAudioSessionCategoryPlayback;
#endif
	[[AVAudioSession sharedInstance] setCategory:playbackCategory error: nil];
    AVAudioSession * audioSession = [AVAudioSession sharedInstance];
    NSError * err = nil;
    // need to configure set the audio category, and override to it route the audio to the speaker
    if([audioSession respondsToSelector:@selector(setCategory:withOptions:error:)]) {

        if(![audioSession setCategory:playbackCategory
                                       withOptions:(AVAudioSessionCategoryOptionMixWithOthers |
                                                   AVAudioSessionCategoryOptionAllowAirPlay |
                                                   AVAudioSessionCategoryOptionAllowBluetooth |
                                                   AVAudioSessionCategoryOptionAllowBluetoothA2DP)
                                        error:&err]) { err = nil; }
    }
	[[AVAudioSession sharedInstance] setActive: YES error: nil];
	audioSessionSetup = YES;
}

- (void)dealloc {
    [self unloadSound];
}

//----------------------------------------------------------- load / unload.
- (BOOL)loadWithFile:(NSString*)file {
    NSArray * fileSplit = [file componentsSeparatedByString:@"."];
    NSURL * fileURL = [[NSBundle mainBundle] URLForResource:[fileSplit objectAtIndex:0] 
                                              withExtension:[fileSplit objectAtIndex:1]];
	return [self loadWithURL:fileURL];
}

- (BOOL)loadWithPath:(NSString*)path {
    NSURL * fileURL = [NSURL fileURLWithPath:path];
	return [self loadWithURL:fileURL];
}

- (BOOL)loadWithURL:(NSURL*)url {
    [self unloadSound];
	[self setupSharedSession];
    NSError * error = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:url
                                                         error:&error];
    if([self.player respondsToSelector:@selector(setEnableRate:)]) {
        [self.player setEnableRate:YES];
    }
    [self.player prepareToPlay];
    if(error) {
        if([self.delegate respondsToSelector:@selector(soundPlayerError:)]) {
            [self.delegate soundPlayerError:error];
        }
        return NO;
    }
    
    self.player.delegate = self;
    if (asyncReplay) {
        desiredVolume = self.player.volume;
        desiredPan = self.player.pan;
        desiredRate = self.player.rate;
        desiredLoops = self.player.numberOfLoops;
        cachedTime = self.player.currentTime;
        cachedDuration = self.player.duration;
    }
    return YES;
}

- (void)unloadSound {
    if (asyncReplay) {
        ++lifetimeGeneration;
        [self cancelPendingPlayback];
        [self stopTimer];
        AVAudioPlayer *retired = self.player;
        self.player = nil;
        if (preparing) {
            // The loan, not the wrapper, owns backend lifetime. Never wait for it
            // or touch its properties/delegate while prepareToPlay is running.
            dispatch_async(preparationQueue, ^{ [retired stop]; retired.delegate = nil; });
        } else {
            [retired stop];
            retired.delegate = nil;
        }
        preparing = deferredStop = deferredPause = positionChanged = NO;
        cachedTime = cachedDuration = 0;
        return;
    }
    [self stop];
    self.player.delegate = nil;
    self.player = nil;
}

- (void)cancelPendingPlayback {
    if (!asyncReplay) return;
    ++requestGeneration;
    pendingPlay = NO;
}

- (BOOL)isPlaybackPending { return asyncReplay && pendingPlay; }

- (void)preparePendingPlayback {
    NSAssert([NSThread isMainThread], @"Opt-in playback is main-owned");
    if (preparing || committing || !pendingPlay || !self.player) return;
    [self stopTimer];
    if (!positionChanged) cachedTime = self.player.currentTime;
    self.player.delegate = nil;
    preparing = YES;
    const NSUInteger lifetime = lifetimeGeneration;
    const NSUInteger preparationRequest = requestGeneration;
    AVAudioPlayer *loan = self.player;
    __weak AVSoundPlayer *weakSelf = self;
    dispatch_async(preparationQueue, ^{
        @autoreleasepool {
            BOOL prepared = [loan prepareToPlay];
            // Do not capture the wrapper OR backend in this main completion.
            // Unload/release can retire the loan without late playback or a wait.
            dispatch_async(dispatch_get_main_queue(), ^{
                AVSoundPlayer *owner = weakSelf;
                if (!owner || lifetime != owner->lifetimeGeneration) return;
                owner->preparing = NO;
                owner.player.delegate = owner;
                BOOL needsNewLoan = owner->deferredStop || owner->deferredPause ||
                    (owner->pendingPlay && preparationRequest != owner->requestGeneration);
                if (owner->deferredStop || owner->deferredPause) {
                    if (owner->deferredStop) [owner.player stop];
                    else [owner.player pause];
                    owner->deferredStop = owner->deferredPause = NO;
                }
                const NSUInteger request = owner->requestGeneration;
                owner->committing = YES;
                owner.player.volume = owner->desiredVolume;
                owner.player.pan = owner->desiredPan;
                owner.player.rate = owner->desiredRate;
                owner.player.numberOfLoops = owner->desiredLoops;
                if (owner->positionChanged) owner.player.currentTime = owner->cachedTime;
                owner->positionChanged = NO;
                owner->committing = NO;
                // Main owns property commit, cancellation and play together;
                // no worker can restore volume or reset an active voice later.
                // Also reject a reentrant cancellation during property setters.
                if (lifetime != owner->lifetimeGeneration || !owner->pendingPlay) return;
                if (request != owner->requestGeneration || needsNewLoan) {
                    // stop invalidates preparation; only the NEW pending request
                    // can take another loan after deferred stop/pause completes.
                    [owner preparePendingPlayback];
                    return;
                }
                if (!prepared) { owner->pendingPlay = NO; return; }
                owner->pendingPlay = NO;
                if ([owner.player play]) [owner startTimer];
            });
        }
    });
}

//----------------------------------------------------------- play / pause / stop.
- (void)play {
    if (asyncReplay) {
        NSAssert([NSThread isMainThread], @"Opt-in playback is main-owned");
        if (!self.player) return;
        if (!preparing && self.player.isPlaying) {
            self.player.currentTime = 0; // preserve legacy reset-only semantics
            return;
        }
        pendingPlay = YES; // repeated requests coalesce without hiding actual state
        [self preparePendingPlayback];
        return;
    }
    if([self isPlaying]) {
        [self position:0];
        return;
    }
    BOOL bOk = [self.player play];
    if(bOk) {
        [self startTimer];
    }
}

- (void)pause {
    if (asyncReplay) {
        [self cancelPendingPlayback];
        [self stopTimer];
        if (preparing) deferredPause = YES;
        else [self.player pause];
        return;
    }
    [self.player pause];
    [self stopTimer];
}

- (void)stop {
    if (asyncReplay) {
        [self cancelPendingPlayback];
        [self stopTimer];
        if (preparing) deferredStop = YES;
        else [self.player stop];
        return;
    }
    [self.player stop];
    [self stopTimer];
}

//----------------------------------------------------------- states.
- (BOOL)isLoaded {
    return (self.player != nil);
}

- (BOOL)isPlaying {
    if (asyncReplay && preparing) return NO; // pending is not confirmed playing
    if(self.player == nil) {
        return NO;
    }
    return self.player.isPlaying;
}

//----------------------------------------------------------- properties.
- (void)volume:(float)value {
    if (asyncReplay) { desiredVolume = value; if (preparing) return; }
    self.player.volume = value;
}

- (float)volume {
    if (asyncReplay && self.player) return desiredVolume;
    if(self.player == nil) {
        return 0;
    }
    return self.player.volume;
}

- (void)pan:(float)value {
    if (asyncReplay) { desiredPan = value; if (preparing) return; }
    self.player.pan = value;
}

- (float)pan {
    if (asyncReplay && self.player) return desiredPan;
    if(self.player == nil) {
        return 0;
    }
    return self.player.pan;
}

- (void)speed:(float)value {
    if(value < 0.5) { // min play speed is 0.5 and max speed is 2.0 as per apple docs.
        value = 0.5;
    } else if(value > 2.0) {
        value = 2.0;
    }
    if (asyncReplay) { desiredRate = value; if (preparing) return; }
    self.player.rate = value;
}

- (float)speed {
    if (asyncReplay && self.player) return desiredRate;
    if(self.player == nil) {
        return 0;
    }
    return self.player.rate;
}

- (void)loop:(BOOL)bLoop {
    if (asyncReplay) { desiredLoops = bLoop ? -1 : 0; if (preparing) return; }
    if(bLoop) {
        self.player.numberOfLoops = -1;
    } else {
        self.player.numberOfLoops = 0;
    }
}

- (BOOL)loop {
    if (asyncReplay && self.player) return desiredLoops < 0;
    return self.player.numberOfLoops < 0;
}

- (void)multiPlay:(BOOL)value {
    bMultiPlay = value;
}

- (BOOL)multiPlay {
    return bMultiPlay;
}

- (void)position:(float)value {
    if (asyncReplay) {
        cachedTime = value * cachedDuration;
        if (preparing) { positionChanged = YES; return; }
    }
    self.player.currentTime = value * self.player.duration;
}

- (float)position {
    if (asyncReplay && preparing) return cachedDuration > 0 ? cachedTime / cachedDuration : 0;
    if(self.player == nil) {
        return 0;
    }
    return self.player.currentTime / (float)self.player.duration;
}

- (void)positionMs:(int)value {
    if (asyncReplay) {
        cachedTime = value / 1000.0;
        if (preparing) { positionChanged = YES; return; }
    }
    self.player.currentTime = value / 1000.0;
}

- (int)positionMs {
    if (asyncReplay && preparing) return cachedTime * 1000;
    if(self.player == nil) {
        return 0;
    }
    return self.player.currentTime * 1000;
}

- (float)duration {
    if (asyncReplay && preparing) return cachedDuration;
	if(self.player == nil) {
		return 0.f;
	}
	return self.player.duration;
}

//----------------------------------------------------------- timer.
- (void)updateTimer {
    if([self.delegate respondsToSelector:@selector(soundPlayerDidChange)]) {
        [self.delegate soundPlayerDidChange];
    }
}

- (void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)startTimer {
    [self stopTimer];
	self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                                  target:self 
                                                selector:@selector(updateTimer) 
                                                userInfo:nil 
                                                 repeats:YES];
}

//----------------------------------------------------------- audio player events.
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player 
                                 error:(NSError *)error {
    if (asyncReplay && ![NSThread isMainThread]) {
        __weak AVSoundPlayer *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf audioPlayerDecodeErrorDidOccur:player error:error]; });
        return;
    }
    if (asyncReplay && (preparing || player != self.player)) return;
    if([self.delegate respondsToSelector:@selector(soundPlayerError:)]) {
        [self.delegate soundPlayerError:error];
    }
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player 
                       successfully:(BOOL)flag {
    if (asyncReplay && ![NSThread isMainThread]) {
        __weak AVSoundPlayer *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf audioPlayerDidFinishPlaying:player successfully:flag]; });
        return;
    }
    if (asyncReplay && (preparing || player != self.player || self.player.isPlaying)) return;
    [self stopTimer];
    
    if([self.delegate respondsToSelector:@selector(soundPlayerDidFinish)]) {
        [self.delegate soundPlayerDidFinish];
    }
}

- (void) audioPlayerEndInterruption:(AVAudioPlayer *)player withFlags:(NSUInteger)flags {
    // The opt-in app owns interruption recovery too; do not independently replay
    // interrupted one-shots or compete with its focus/session ordering.
    if ([[[NSBundle mainBundle] objectForInfoDictionaryKey:@"ofxiOSAppManagedAudioSession"] boolValue]) return;
#if TARGET_OS_IOS || (TARGET_OS_IPHONE && !TARGET_OS_TV)
    if(flags == AVAudioSessionInterruptionOptionShouldResume) {
		[self.player play];
	}
#elif TARGET_OS_TV
	//
#endif
}

@end
#endif
