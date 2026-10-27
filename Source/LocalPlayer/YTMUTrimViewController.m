#import "YTMUTrimViewController.h"
#import "YTMULocalPlayer.h"
#import "../Headers/Localization.h"
#import <AVFoundation/AVFoundation.h>

// Never nil, even if the tweak's bundle failed to load: UIAlertAction throws on a nil title
#define YTMU_STR(key, fallback) (LOC_DEFAULT(key, fallback) ?: fallback)

static NSString *YTMUTrimFormatTime(NSTimeInterval time) {
    if (!isfinite(time) || time < 0) time = 0;

    long tenths = (long)llround(time * 10);
    long seconds = tenths / 10;
    long fraction = tenths % 10;

    NSString *text = seconds >= 3600
        ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", seconds / 3600, seconds / 60 % 60, seconds % 60]
        : [NSString stringWithFormat:@"%ld:%02ld", seconds / 60, seconds % 60];
    return fraction > 0 ? [text stringByAppendingFormat:@".%ld", fraction] : text;
}

// Accepts "83", "1:23", "1:23.5" and "1:02:03"
static BOOL YTMUTrimParseTime(NSString *text, NSTimeInterval *outSeconds) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length == 0) return NO;

    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@":"];
    if (parts.count > 3) return NO;

    double total = 0;
    for (NSString *rawPart in parts) {
        NSString *part = [[rawPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] stringByReplacingOccurrencesOfString:@"," withString:@"."];
        if (part.length == 0) return NO;

        NSScanner *scanner = [NSScanner scannerWithString:part];
        double value = 0;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) || value < 0) return NO;
        total = total * 60 + value;
    }

    if (!isfinite(total)) return NO;
    if (outSeconds) *outSeconds = total;
    return YES;
}

@interface YTMUTrimViewController () <UITextFieldDelegate>
@property (nonatomic, strong) YTMULocalTrack *track;
@property (nonatomic, strong) AVPlayer *previewPlayer;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, assign) NSTimeInterval fullDuration;
@property (nonatomic, assign) NSTimeInterval previewEnd;
@property (nonatomic, assign) BOOL scrubbing;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *playheadLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UITextField *startField;
@property (nonatomic, strong) UITextField *endField;
@end

@implementation YTMUTrimViewController

- (instancetype)initWithTrack:(YTMULocalTrack *)track {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _track = track;
        self.modalPresentationStyle = UIModalPresentationPageSheet;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:18/255.0 green:18/255.0 blue:18/255.0 alpha:1.0];

    self.fullDuration = self.track.duration;
    if (self.fullDuration <= 0 && self.track.fileURL) {
        NSTimeInterval seconds = CMTimeGetSeconds([AVURLAsset URLAssetWithURL:self.track.fileURL options:nil].duration);
        self.fullDuration = isfinite(seconds) && seconds > 0 ? seconds : 0;
        if (self.fullDuration > 0) self.track.duration = self.fullDuration;
    }

    if (self.track.fileURL) {
        self.previewPlayer = [AVPlayer playerWithURL:self.track.fileURL];
        __weak typeof(self) weakSelf = self;
        self.timeObserver = [self.previewPlayer addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, 600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
            [weakSelf previewTimeChanged:CMTimeGetSeconds(time)];
        }];
    }

    [self buildTopBar];
    [self buildContent];

    if (self.track.trimStart > 0) self.startField.text = YTMUTrimFormatTime(self.track.trimStart);
    if (self.track.trimEnd > 0) self.endField.text = YTMUTrimFormatTime(self.track.trimEnd);

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [self previewTimeChanged:0];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.previewPlayer pause];
}

- (void)dealloc {
    if (self.previewPlayer && self.timeObserver) [self.previewPlayer removeTimeObserver:self.timeObserver];
    [self.previewPlayer pause];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Building

- (void)buildTopBar {
    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    cancelButton.tintColor = [UIColor whiteColor];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17];
    [cancelButton setTitle:YTMU_STR(@"CANCEL", @"Cancel") forState:UIControlStateNormal];
    [cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancelButton];

    UIButton *saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    saveButton.tintColor = [UIColor whiteColor];
    saveButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [saveButton setTitle:YTMU_STR(@"SAVE", @"Save") forState:UIControlStateNormal];
    [saveButton addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:saveButton];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = YTMU_STR(@"TRIM_TITLE", @"Start & end");
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:titleLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [cancelButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [cancelButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [cancelButton.heightAnchor constraintEqualToConstant:44],

        [saveButton.centerYAnchor constraintEqualToAnchor:cancelButton.centerYAnchor],
        [saveButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [saveButton.heightAnchor constraintEqualToConstant:44],

        [titleLabel.centerYAnchor constraintEqualToAnchor:cancelButton.centerYAnchor],
        [titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:cancelButton.trailingAnchor constant:8],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:saveButton.leadingAnchor constant:-8],
    ]];

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:cancelButton.bottomAnchor constant:8],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (UIButton *)symbolButton:(NSString *)symbol size:(CGFloat)size action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = [UIColor whiteColor];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return button;
}

- (UIButton *)textButton:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = color;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return button;
}

- (UITextField *)timeField:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] init];
    field.delegate = self;
    field.textColor = [UIColor whiteColor];
    field.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightMedium];
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    field.keyboardAppearance = UIKeyboardAppearanceDark;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.returnKeyType = UIReturnKeyDone;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    field.layer.cornerRadius = 8;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    field.leftViewMode = UITextFieldViewModeAlways;
    field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder attributes:@{NSForegroundColorAttributeName: [[UIColor whiteColor] colorWithAlphaComponent:0.35]}];
    [field.heightAnchor constraintEqualToConstant:44].active = YES;
    return field;
}

- (UIStackView *)rowWithTitle:(NSString *)title field:(UITextField *)field action:(SEL)action {
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [label.widthAnchor constraintEqualToConstant:52].active = YES;

    UIButton *useButton = [self textButton:YTMU_STR(@"USE_PLAYHEAD", @"Use current time") color:[UIColor systemBlueColor] action:action];
    [useButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, field, useButton]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10;
    return row;
}

- (void)buildContent {
    UILabel *songLabel = [[UILabel alloc] init];
    songLabel.text = self.track.fileName;
    songLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    songLabel.font = [UIFont systemFontOfSize:15];
    songLabel.numberOfLines = 2;
    songLabel.textAlignment = NSTextAlignmentCenter;

    self.slider = [[UISlider alloc] init];
    self.slider.minimumTrackTintColor = [UIColor whiteColor];
    self.slider.maximumTrackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25];
    self.slider.minimumValue = 0;
    self.slider.maximumValue = (float)MAX(self.fullDuration, 1);
    [self.slider addTarget:self action:@selector(sliderTouchDown) forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(sliderReleased) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    self.playheadLabel = [[UILabel alloc] init];
    self.playheadLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    self.playheadLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.playheadLabel.textAlignment = NSTextAlignmentCenter;

    self.playButton = [self symbolButton:@"play.circle.fill" size:48 action:@selector(playTapped)];
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self symbolButton:@"gobackward.10" size:24 action:@selector(backTapped)],
        self.playButton,
        [self symbolButton:@"goforward.10" size:24 action:@selector(forwardTapped)],
    ]];
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.alignment = UIStackViewAlignmentCenter;
    controls.spacing = 36;

    UIStackView *controlsRow = [[UIStackView alloc] initWithArrangedSubviews:@[controls]];
    controlsRow.axis = UILayoutConstraintAxisVertical;
    controlsRow.alignment = UIStackViewAlignmentCenter;

    self.startField = [self timeField:@"0:00"];
    self.endField = [self timeField:YTMU_STR(@"TRIM_END_PLACEHOLDER", @"End of song")];

    UILabel *hintLabel = [[UILabel alloc] init];
    hintLabel.text = YTMU_STR(@"TRIM_HINT", @"Play or scrub to the moment you want, then tap Use current time. You can also type times like 1:23 or 1:02:03. Leave End empty to play to the end.");
    hintLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.5];
    hintLabel.font = [UIFont systemFontOfSize:13];
    hintLabel.numberOfLines = 0;

    UIButton *previewButton = [UIButton buttonWithType:UIButtonTypeCustom];
    previewButton.backgroundColor = [UIColor whiteColor];
    previewButton.layer.cornerRadius = 22;
    previewButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [previewButton setTitle:YTMU_STR(@"TRIM_PREVIEW", @"Preview selection") forState:UIControlStateNormal];
    [previewButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [previewButton setTitleColor:[UIColor grayColor] forState:UIControlStateHighlighted];
    [previewButton addTarget:self action:@selector(previewSelectionTapped) forControlEvents:UIControlEventTouchUpInside];
    [previewButton.heightAnchor constraintEqualToConstant:44].active = YES;

    UIButton *resetButton = [self textButton:YTMU_STR(@"TRIM_RESET", @"Reset to the whole song") color:[UIColor systemRedColor] action:@selector(resetTapped)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        songLabel,
        self.slider,
        self.playheadLabel,
        controlsRow,
        [self rowWithTitle:YTMU_STR(@"TRIM_START", @"Start") field:self.startField action:@selector(useCurrentForStart)],
        [self rowWithTitle:YTMU_STR(@"TRIM_END", @"End") field:self.endField action:@selector(useCurrentForEnd)],
        hintLabel,
        previewButton,
        resetButton,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    [stack setCustomSpacing:4 afterView:self.slider];
    [stack setCustomSpacing:28 afterView:controlsRow];
    [self.scrollView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.trailingAnchor constant:-20],
    ]];
}

#pragma mark - Preview player

- (NSTimeInterval)previewTime {
    if (!self.previewPlayer.currentItem) return 0;

    NSTimeInterval seconds = CMTimeGetSeconds(self.previewPlayer.currentTime);
    return isfinite(seconds) && seconds > 0 ? seconds : 0;
}

- (void)previewTimeChanged:(NSTimeInterval)time {
    if (!isfinite(time) || time < 0) time = 0;

    // Stop at the end of the selection when previewing it
    if (self.previewEnd > 0 && time >= self.previewEnd) {
        self.previewEnd = 0;
        [self.previewPlayer pause];
    }

    if (!self.scrubbing) {
        self.slider.value = (float)time;
        [self updatePlayheadLabel:time];
    }

    BOOL playing = self.previewPlayer.rate > 0;
    [self.playButton setImage:[UIImage systemImageNamed:playing ? @"pause.circle.fill" : @"play.circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:48 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
}

- (void)updatePlayheadLabel:(NSTimeInterval)time {
    self.playheadLabel.text = [NSString stringWithFormat:@"%@ / %@", YTMUTrimFormatTime(time), YTMUTrimFormatTime(self.fullDuration)];
}

- (void)seekPreviewTo:(NSTimeInterval)time {
    if (!self.previewPlayer.currentItem || !isfinite(time)) return;

    time = MAX(0, self.fullDuration > 0 ? MIN(time, self.fullDuration) : time);
    [self.previewPlayer seekToTime:CMTimeMakeWithSeconds(time, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [self previewTimeChanged:time];
}

- (void)startPreview {
    // Don't talk over the song that's playing in My Music
    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    if (player.isPlaying) [player pause];

    [self.previewPlayer play];
}

- (void)playTapped {
    self.previewEnd = 0;
    if (self.previewPlayer.rate > 0) {
        [self.previewPlayer pause];
    } else {
        [self startPreview];
    }
    [self previewTimeChanged:self.previewTime];
}

- (void)backTapped {
    [self seekPreviewTo:self.previewTime - 10];
}

- (void)forwardTapped {
    [self seekPreviewTo:self.previewTime + 10];
}

- (void)sliderTouchDown {
    self.scrubbing = YES;
}

- (void)sliderChanged {
    [self updatePlayheadLabel:self.slider.value];
}

- (void)sliderReleased {
    self.scrubbing = NO;
    [self seekPreviewTo:self.slider.value];
}

- (void)useCurrentForStart {
    self.startField.text = YTMUTrimFormatTime(self.previewTime);
}

- (void)useCurrentForEnd {
    self.endField.text = YTMUTrimFormatTime(self.previewTime);
}

- (void)previewSelectionTapped {
    NSTimeInterval start = 0, end = 0;
    if (![self readStart:&start end:&end]) return;

    [self.view endEditing:YES];
    [self seekPreviewTo:start];
    self.previewEnd = end;
    [self startPreview];
}

#pragma mark - Saving

- (void)showProblem:(NSString *)message {
    if (self.presentedViewController) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"OK", @"OK") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Reads both fields. end comes back as 0 when the song should play to the end of the file.
- (BOOL)readStart:(NSTimeInterval *)outStart end:(NSTimeInterval *)outEnd {
    NSString *startText = [self.startField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    NSString *endText = [self.endField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    NSTimeInterval start = 0, end = 0;

    if ((startText.length > 0 && !YTMUTrimParseTime(startText, &start)) || (endText.length > 0 && !YTMUTrimParseTime(endText, &end))) {
        [self showProblem:YTMU_STR(@"TRIM_BAD_TIME", @"Enter times like 1:23 or 1:02:03.")];
        return NO;
    }

    if (self.fullDuration > 0) {
        if (end >= self.fullDuration - 0.05) end = 0;
        if (start >= self.fullDuration) start = -1;
    }

    NSTimeInterval effectiveEnd = end > 0 ? end : self.fullDuration;
    BOOL validRange = start >= 0 && (effectiveEnd <= 0 || effectiveEnd - start >= 1);
    if (!validRange) {
        [self showProblem:YTMU_STR(@"TRIM_BAD_RANGE", @"The end has to be at least 1 second after the start, and the start has to be inside the song.")];
        return NO;
    }

    if (outStart) *outStart = start;
    if (outEnd) *outEnd = end;
    return YES;
}

- (void)applyAndClose {
    [[YTMULocalPlayer sharedPlayer] trackTrimDidChange:self.track.fileURL];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadDataNotification" object:nil];
    [self.previewPlayer pause];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveTapped {
    NSTimeInterval start = 0, end = 0;
    if (![self readStart:&start end:&end]) return;

    [self.track setTrimStart:start end:end];
    [self applyAndClose];
}

- (void)resetTapped {
    [self.track clearTrim];
    [self applyAndClose];
}

- (void)cancelTapped {
    [self.previewPlayer pause];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Keyboard

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification {
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (!frameValue || !self.view.window) return;

    CGRect keyboard = [self.view convertRect:frameValue.CGRectValue fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboard));

    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = overlap;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

@end
