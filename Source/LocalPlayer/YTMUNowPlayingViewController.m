#import "YTMUNowPlayingViewController.h"
#import "YTMULocalPlayer.h"
#import "../Headers/Localization.h"
#import <AVKit/AVKit.h>

static NSString *YTMUFormatTime(NSTimeInterval time) {
    NSInteger seconds = (NSInteger)MAX(0, round(time));
    if (seconds >= 3600) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(seconds / 3600), (long)(seconds / 60 % 60), (long)(seconds % 60)];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

static UIImage *YTMUSymbol(NSString *name, CGFloat size) {
    return [UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold]];
}

#pragma mark - Up next

@interface YTMUQueueViewController : UITableViewController
@end

@implementation YTMUQueueViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = LOC_DEFAULT(@"UP_NEXT", @"Up next");
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = [UIColor colorWithRed:18/255.0 green:18/255.0 blue:18/255.0 alpha:1.0];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneTapped)];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadQueue) name:YTMULocalPlayerStateDidChangeNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    NSInteger current = [YTMULocalPlayer sharedPlayer].currentIndex;
    if (current < [self.tableView numberOfRowsInSection:0]) {
        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:current inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadQueue {
    [self.tableView reloadData];
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [YTMULocalPlayer sharedPlayer].queue.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"queueCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"queueCell"];

    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    NSArray<YTMULocalTrack *> *queue = player.queue;
    if (indexPath.row >= (NSInteger)queue.count) return cell;

    YTMULocalTrack *track = queue[indexPath.row];
    BOOL isCurrent = indexPath.row == player.currentIndex;
    BOOL isPast = indexPath.row < player.currentIndex;

    cell.backgroundColor = [UIColor clearColor];
    cell.textLabel.text = track.title;
    cell.textLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:isPast ? 0.4 : 1.0];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:isCurrent ? UIFontWeightBold : UIFontWeightRegular];
    cell.detailTextLabel.text = track.artist;
    cell.detailTextLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:isPast ? 0.3 : 0.6];
    cell.accessoryView = isCurrent ? [[UIImageView alloc] initWithImage:YTMUSymbol(@"speaker.wave.2.fill", 15)] : nil;
    cell.accessoryView.tintColor = [UIColor whiteColor];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [[YTMULocalPlayer sharedPlayer] playQueueIndex:indexPath.row];
}

@end

#pragma mark - Now playing

@interface YTMUNowPlayingViewController ()
@property (nonatomic, strong) UIImageView *backgroundView;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *remainingLabel;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *repeatButton;
@property (nonatomic, strong) YTMULocalTrack *displayedTrack;
@property (nonatomic, assign) BOOL scrubbing;
@end

@implementation YTMUNowPlayingViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationPageSheet;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithRed:18/255.0 green:18/255.0 blue:18/255.0 alpha:1.0];

    _backgroundView = [[UIImageView alloc] init];
    _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    _backgroundView.contentMode = UIViewContentModeScaleAspectFill;
    _backgroundView.clipsToBounds = YES;
    [self.view addSubview:_backgroundView];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:blur];

    UIView *dim = [[UIView alloc] init];
    dim.translatesAutoresizingMaskIntoConstraints = NO;
    dim.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
    [self.view addSubview:dim];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    closeButton.tintColor = [UIColor whiteColor];
    [closeButton setImage:YTMUSymbol(@"chevron.down", 20) forState:UIControlStateNormal];
    [closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:closeButton];

    AVRoutePickerView *routePicker = [[AVRoutePickerView alloc] init];
    routePicker.translatesAutoresizingMaskIntoConstraints = NO;
    routePicker.tintColor = [UIColor whiteColor];
    routePicker.activeTintColor = [UIColor systemBlueColor];
    [self.view addSubview:routePicker];

    UIButton *queueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    queueButton.translatesAutoresizingMaskIntoConstraints = NO;
    queueButton.tintColor = [UIColor whiteColor];
    [queueButton setImage:YTMUSymbol(@"list.bullet", 18) forState:UIControlStateNormal];
    [queueButton addTarget:self action:@selector(queueTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:queueButton];

    _artworkView = [[UIImageView alloc] init];
    _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    _artworkView.contentMode = UIViewContentModeScaleAspectFill;
    _artworkView.clipsToBounds = YES;
    _artworkView.layer.cornerRadius = 10;
    _artworkView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    [self.view addSubview:_artworkView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    _titleLabel.textColor = [UIColor whiteColor];
    [self.view addSubview:_titleLabel];

    _artistLabel = [[UILabel alloc] init];
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _artistLabel.font = [UIFont systemFontOfSize:17];
    _artistLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
    [self.view addSubview:_artistLabel];

    _slider = [[UISlider alloc] init];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    _slider.minimumTrackTintColor = [UIColor whiteColor];
    _slider.maximumTrackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25];
    [_slider setThumbImage:[self thumbImageWithDiameter:12] forState:UIControlStateNormal];
    [_slider setThumbImage:[self thumbImageWithDiameter:20] forState:UIControlStateHighlighted];
    [_slider addTarget:self action:@selector(sliderTouchDown) forControlEvents:UIControlEventTouchDown];
    [_slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(sliderReleased) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:_slider];

    _elapsedLabel = [self timeLabel];
    _remainingLabel = [self timeLabel];
    _remainingLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:_elapsedLabel];
    [self.view addSubview:_remainingLabel];

    _shuffleButton = [self controlButtonWithSymbol:@"shuffle" size:20 action:@selector(shuffleTapped)];
    _previousButton = [self controlButtonWithSymbol:@"backward.fill" size:30 action:@selector(previousTapped)];
    _playPauseButton = [self controlButtonWithSymbol:@"play.circle.fill" size:64 action:@selector(playPauseTapped)];
    _nextButton = [self controlButtonWithSymbol:@"forward.fill" size:30 action:@selector(nextTapped)];
    _repeatButton = [self controlButtonWithSymbol:@"repeat" size:20 action:@selector(repeatTapped)];

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[_shuffleButton, _previousButton, _playPauseButton, _nextButton, _repeatButton]];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.distribution = UIStackViewDistributionEqualSpacing;
    controls.alignment = UIStackViewAlignmentCenter;
    [self.view addSubview:controls];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    NSLayoutConstraint *preferredArtworkWidth = [_artworkView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-64];
    preferredArtworkWidth.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [_backgroundView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_backgroundView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_backgroundView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_backgroundView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [blur.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dim.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dim.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [dim.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dim.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [closeButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [closeButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [closeButton.widthAnchor constraintEqualToConstant:44],
        [closeButton.heightAnchor constraintEqualToConstant:44],

        [queueButton.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [queueButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [queueButton.widthAnchor constraintEqualToConstant:44],
        [queueButton.heightAnchor constraintEqualToConstant:44],

        [routePicker.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [routePicker.trailingAnchor constraintEqualToAnchor:queueButton.leadingAnchor constant:-4],
        [routePicker.widthAnchor constraintEqualToConstant:44],
        [routePicker.heightAnchor constraintEqualToConstant:44],

        [_artworkView.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:24],
        [_artworkView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_artworkView.heightAnchor constraintEqualToAnchor:_artworkView.widthAnchor],
        [_artworkView.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-64],
        [_artworkView.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.42],
        preferredArtworkWidth,

        [_titleLabel.topAnchor constraintEqualToAnchor:_artworkView.bottomAnchor constant:32],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:32],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-32],

        [_artistLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
        [_artistLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_artistLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

        [_slider.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor constant:24],
        [_slider.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_slider.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

        [_elapsedLabel.topAnchor constraintEqualToAnchor:_slider.bottomAnchor constant:4],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:_slider.leadingAnchor],
        [_remainingLabel.topAnchor constraintEqualToAnchor:_slider.bottomAnchor constant:4],
        [_remainingLabel.trailingAnchor constraintEqualToAnchor:_slider.trailingAnchor],

        [controls.topAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor constant:20],
        [controls.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [controls.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [controls.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(refresh) name:YTMULocalPlayerStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(refreshTime) name:YTMULocalPlayerTimeDidChangeNotification object:nil];
    [self refresh];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UILabel *)timeLabel {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    label.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    return label;
}

- (UIButton *)controlButtonWithSymbol:(NSString *)symbol size:(CGFloat)size action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = [UIColor whiteColor];
    [button setImage:YTMUSymbol(symbol, size) forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return button;
}

- (UIImage *)thumbImageWithDiameter:(CGFloat)diameter {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(diameter, diameter)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor whiteColor] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, diameter, diameter)] fill];
    }];
}

- (void)refresh {
    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    YTMULocalTrack *track = player.currentTrack;

    if (!track) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    self.titleLabel.text = track.title;
    self.artistLabel.text = track.artist;

    if (![track isEqual:self.displayedTrack]) {
        self.displayedTrack = track;
        UIImage *artwork = [track artworkImage];
        self.artworkView.image = artwork;
        self.backgroundView.image = artwork;
    }

    [self.playPauseButton setImage:YTMUSymbol(player.isPlaying ? @"pause.circle.fill" : @"play.circle.fill", 64) forState:UIControlStateNormal];

    self.shuffleButton.tintColor = player.isShuffleEnabled ? [UIColor whiteColor] : [[UIColor whiteColor] colorWithAlphaComponent:0.35];
    [self.repeatButton setImage:YTMUSymbol(player.repeatMode == YTMURepeatModeOne ? @"repeat.1" : @"repeat", 20) forState:UIControlStateNormal];
    self.repeatButton.tintColor = player.repeatMode != YTMURepeatModeOff ? [UIColor whiteColor] : [[UIColor whiteColor] colorWithAlphaComponent:0.35];

    [self refreshTime];
}

- (void)refreshTime {
    if (self.scrubbing) return;

    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    NSTimeInterval duration = player.duration;
    self.slider.maximumValue = (float)MAX(duration, 1);
    self.slider.value = (float)player.currentTime;
    [self updateTimeLabelsWithElapsed:player.currentTime duration:duration];
}

- (void)updateTimeLabelsWithElapsed:(NSTimeInterval)elapsed duration:(NSTimeInterval)duration {
    self.elapsedLabel.text = YTMUFormatTime(elapsed);
    self.remainingLabel.text = [@"-" stringByAppendingString:YTMUFormatTime(MAX(0, duration - elapsed))];
}

- (void)sliderTouchDown {
    self.scrubbing = YES;
}

- (void)sliderChanged {
    [self updateTimeLabelsWithElapsed:self.slider.value duration:[YTMULocalPlayer sharedPlayer].duration];
}

- (void)sliderReleased {
    [[YTMULocalPlayer sharedPlayer] seekToTime:self.slider.value];
    self.scrubbing = NO;
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)queueTapped {
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:[[YTMUQueueViewController alloc] initWithStyle:UITableViewStylePlain]];
    navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:navigationController animated:YES completion:nil];
}

- (void)shuffleTapped {
    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    player.shuffleEnabled = !player.isShuffleEnabled;
}

- (void)previousTapped {
    [[YTMULocalPlayer sharedPlayer] previousTrack];
}

- (void)playPauseTapped {
    [[YTMULocalPlayer sharedPlayer] togglePlayPause];
}

- (void)nextTapped {
    [[YTMULocalPlayer sharedPlayer] nextTrack];
}

- (void)repeatTapped {
    [[YTMULocalPlayer sharedPlayer] cycleRepeatMode];
}

@end
