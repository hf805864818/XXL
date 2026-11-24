//
//  PDSoundPlayer : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDSoundPlayer : NSObject {
    BOOL _speechPlaying;
    BOOL _sessionChanged;
    BOOL _enabled;
    BOOL _visible;
    BOOL _unlocked;
    BOOL _interrupted;
    BOOL _voiceInputActive;
    NSObject<OS_dispatch_queue> * _audioQueue;
    AVAudioEngine * _engine;
    AVAudioFormat * _format;
    NSArray * _voices;
    NSString * _previousCategory;
    unsigned long long _previousCategoryOptions;
    double _pan;
    AVAudioPlayerNode * _speechNode;
    AVAudioFormat * _speechFormat;
    AVAudioFile * _speechFile;
    NSURL * _speechURL;
    void (^_speechCompletion)(void);
    unsigned long long _speechGeneration;
}

@property (nonatomic, strong) NSObject<OS_dispatch_queue> * audioQueue;
@property (nonatomic, strong) AVAudioEngine * engine;
@property (nonatomic, strong) AVAudioFormat * format;
@property (nonatomic, strong) NSArray * voices;
@property (nonatomic, copy) NSString * previousCategory;
@property (nonatomic) unsigned long long previousCategoryOptions;
@property (nonatomic) BOOL sessionChanged;
@property (nonatomic) BOOL enabled;
@property (nonatomic) BOOL visible;
@property (nonatomic) BOOL unlocked;
@property (nonatomic) BOOL interrupted;
@property (nonatomic) BOOL voiceInputActive;
@property (nonatomic) double pan;
@property (nonatomic, strong) AVAudioPlayerNode * speechNode;
@property (nonatomic, strong) AVAudioFormat * speechFormat;
@property (nonatomic, strong) AVAudioFile * speechFile;
@property (nonatomic, strong) NSURL * speechURL;
@property (nonatomic, copy) void (^speechCompletion)(void);
@property (nonatomic) unsigned long long speechGeneration;
@property (nonatomic) BOOL speechPlaying;

- (id)init;
- (void)setEnabled:(BOOL)arg1;
- (void)setVisible:(BOOL)arg1;
- (void)unlock;
- (void)setVoiceInputActive:(BOOL)arg1 completion:(void (^)(void))arg2;
- (void)finishSpeech:(id)arg1;
- (void)stopSpeech;
- (void)playSpeechData:(NSData *)arg1 completion:(void (^)(void))arg2;
- (void)playSound:(id)arg1 kind:(id)arg2 arguments:(id)arg3 pan:(double)arg4;
- (void)interruption:(id)arg1;
- (void)routeChanged:(id)arg1;
- (BOOL)startGraph;
- (void)stopGraphAndRestoreSession;
- (void)restoreSession;
- (id)notesForSound:(id)arg1 arguments:(id)arg2;
- (id)bufferForNotes:(id)arg1 pan:(double)arg2;
- (BOOL)speechPlaying;
- (void)setSpeechPlaying:(BOOL)arg1;
- (unsigned long long)previousCategoryOptions;
- (void)setPreviousCategoryOptions:(unsigned long long)arg1;
- (BOOL)sessionChanged;
- (void)setSessionChanged:(BOOL)arg1;
- (BOOL)enabled;
- (BOOL)visible;
- (BOOL)unlocked;
- (void)setUnlocked:(BOOL)arg1;
- (BOOL)interrupted;
- (void)setInterrupted:(BOOL)arg1;
- (BOOL)voiceInputActive;
- (void)setVoiceInputActive:(BOOL)arg1;
- (double)pan;
- (void)setPan:(double)arg1;
- (void (^)(void))speechCompletion;
- (void)setSpeechCompletion:(void (^)(void))arg1;
- (unsigned long long)speechGeneration;
- (void)setSpeechGeneration:(unsigned long long)arg1;
+ (id)sharedPlayer;
@end
