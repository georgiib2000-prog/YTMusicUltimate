#import "YTMUMiniPlayerView.h"
#import "YTMULocalPlayer.h"

@interface YTMUMiniPlayerView ()
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) YTMULocalTrack *displayedTrack;
@end

@implementation YTMUMiniPlayerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.4;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, 4);

        UIVisualEffectView *background = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        background.translatesAutoresizingMaskIntoConstraints = NO;
        background.layer.cornerRadius = 12;
        background.clipsToBounds = YES;
        [self addSubview:background];

        UIView *content = background.contentView;

        _artworkView = [[UIImageView alloc] init];
        _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.layer.cornerRadius = 6;
        _artworkView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
        [content addSubview:_artworkView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor whiteColor];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.font = [UIFont systemFontOfSize:13];
        _subtitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];

        UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
        labels.translatesAutoresizingMaskIntoConstraints = NO;
        labels.axis = UILayoutConstraintAxisVertical;
        labels.spacing = 2;
        [content addSubview:labels];

        _playPauseButton = [self buttonWithSymbol:@"play.fill" action:@selector(playPauseTapped)];
        _nextButton = [self buttonWithSymbol:@"forward.fill" action:@selector(nextTapped)];
        [content addSubview:_playPauseButton];
        [content addSubview:_nextButton];

        _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        _progressView.translatesAutoresizingMaskIntoConstraints = NO;
        _progressView.progressTintColor = [UIColor whiteColor];
        _progressView.trackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        [content addSubview:_progressView];

        [NSLayoutConstraint activateConstraints:@[
            [background.topAnchor constraintEqualToAnchor:self.topAnchor],
            [background.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [background.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [background.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [_artworkView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:10],
            [_artworkView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
            [_artworkView.widthAnchor constraintEqualToConstant:44],
            [_artworkView.heightAnchor constraintEqualToConstant:44],

            [labels.leadingAnchor constraintEqualToAnchor:_artworkView.trailingAnchor constant:12],
            [labels.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
            [labels.trailingAnchor constraintEqualToAnchor:_playPauseButton.leadingAnchor constant:-4],

            [_nextButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-6],
            [_nextButton.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
            [_nextButton.widthAnchor constraintEqualToConstant:44],
            [_nextButton.heightAnchor constraintEqualToConstant:44],

            [_playPauseButton.trailingAnchor constraintEqualToAnchor:_nextButton.leadingAnchor],
            [_playPauseButton.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
            [_playPauseButton.widthAnchor constraintEqualToConstant:44],
            [_playPauseButton.heightAnchor constraintEqualToConstant:44],

            [_progressView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_progressView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [_progressView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_progressView.heightAnchor constraintEqualToConstant:2],
        ]];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openTapped)]];

        UISwipeGestureRecognizer *swipeUp = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(openTapped)];
        swipeUp.direction = UISwipeGestureRecognizerDirectionUp;
        [self addGestureRecognizer:swipeUp];

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(refresh) name:YTMULocalPlayerStateDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(refreshProgress) name:YTMULocalPlayerTimeDidChangeNotification object:nil];
        [self refresh];
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = [UIColor whiteColor];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)refresh {
    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    YTMULocalTrack *track = player.currentTrack;

    self.titleLabel.text = track.title;
    self.subtitleLabel.text = track.artist;
    self.subtitleLabel.hidden = track.artist.length == 0;

    NSString *symbol = player.isPlaying ? @"pause.fill" : @"play.fill";
    [self.playPauseButton setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];

    if (track && ![track isEqual:self.displayedTrack]) {
        self.displayedTrack = track;
        self.artworkView.image = [track cachedThumbnailWithSize:44];
        __weak typeof(self) weakSelf = self;
        [track loadThumbnailWithSize:44 completion:^(UIImage *image) {
            if ([weakSelf.displayedTrack isEqual:track]) weakSelf.artworkView.image = image;
        }];
    } else if (!track) {
        self.displayedTrack = nil;
        self.artworkView.image = nil;
    }

    [self refreshProgress];
}

- (void)refreshProgress {
    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    NSTimeInterval duration = player.duration;
    self.progressView.progress = duration > 0 ? (float)(player.currentTime / duration) : 0;
}

- (void)playPauseTapped {
    [[YTMULocalPlayer sharedPlayer] togglePlayPause];
}

- (void)nextTapped {
    [[YTMULocalPlayer sharedPlayer] nextTrack];
}

- (void)openTapped {
    if (self.openHandler) self.openHandler();
}

@end
