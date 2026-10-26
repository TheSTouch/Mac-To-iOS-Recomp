// Unity ports: the audio session in Playback, not Ambient. Unity's iOS player (its FMOD)
// sets Ambient, or SoloAmbient, which an iPhone's silent mode (the Ring/Silent switch or
// the Action button) mutes: the game was silent on a phone in silent mode. Playback mixed
// with others plays regardless and keeps the player's own music playing, as Ambient did;
// the AppKit route does the same in appkit/RecompAudio.m. Unity sets its category during
// start-up and again after interruptions, so this checks once a second and sets Playback
// back whenever the category differs. Unity ports get it in Assets/Plugins/iOS with the
// other top-level files of recomp/native.
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

static void RecompAudioSessionCheck(void)
{
    AVAudioSession *s = AVAudioSession.sharedInstance;
    if ([s.category isEqualToString:AVAudioSessionCategoryPlayback]
        && (s.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers))
        return;
    NSString *was = s.category;
    NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&e])
    {
        NSLog(@"[recomp] audio session: cannot set Playback (was %@): %@", was, e);
        return;
    }
    [s setActive:YES error:nil];
    NSLog(@"[recomp] audio session: %@ -> Playback, mixed with others (plays in silent mode), volume %.2f",
          was, s.outputVolume);
}

__attribute__((constructor)) static void RecompAudioSessionInstall(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            RecompAudioSessionCheck();
        }];
    });
}
