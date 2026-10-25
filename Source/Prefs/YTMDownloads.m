#import "YTMDownloads.h"
#import "../LocalPlayer/YTMULocalPlayer.h"
#import "../LocalPlayer/YTMUMiniPlayerView.h"
#import "../LocalPlayer/YTMUNowPlayingViewController.h"

typedef NS_ENUM(NSInteger, YTMULibrarySort) {
    YTMULibrarySortRecent,
    YTMULibrarySortTitle,
    YTMULibrarySortArtist
};

static NSString *const YTMULibrarySortKey = @"YTMULibrarySortMode";
static const CGFloat YTMUMiniPlayerHeight = 64;

static NSString *YTMUDurationString(NSTimeInterval duration) {
    NSInteger seconds = (NSInteger)round(duration);
    if (seconds >= 3600) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(seconds / 3600), (long)(seconds / 60 % 60), (long)(seconds % 60)];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

static BOOL YTMUViewIsVisible(UIView *view) {
    if (!view.window) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    return YES;
}

static UIView *YTMUFindView(UIView *root, BOOL (^matches)(UIView *view)) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (matches(view)) return view;
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

#pragma mark - Cell

@interface YTMULibraryCell : UITableViewCell
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIImageView *playingView;
@property (nonatomic, strong) YTMULocalTrack *track;
@end

@implementation YTMULibraryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        UIView *selection = [[UIView alloc] init];
        selection.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        self.selectedBackgroundView = selection;

        _artworkView = [[UIImageView alloc] init];
        _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.layer.cornerRadius = 6;
        _artworkView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [self.contentView addSubview:_artworkView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor whiteColor];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.font = [UIFont systemFontOfSize:13];
        _subtitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];

        UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
        labels.translatesAutoresizingMaskIntoConstraints = NO;
        labels.axis = UILayoutConstraintAxisVertical;
        labels.spacing = 3;
        [self.contentView addSubview:labels];

        _playingView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speaker.wave.2.fill"]];
        _playingView.translatesAutoresizingMaskIntoConstraints = NO;
        _playingView.tintColor = [UIColor whiteColor];
        _playingView.contentMode = UIViewContentModeScaleAspectFit;
        _playingView.hidden = YES;
        [self.contentView addSubview:_playingView];

        [NSLayoutConstraint activateConstraints:@[
            [_artworkView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_artworkView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_artworkView.widthAnchor constraintEqualToConstant:48],
            [_artworkView.heightAnchor constraintEqualToConstant:48],
            [_artworkView.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8],

            [labels.leadingAnchor constraintEqualToAnchor:_artworkView.trailingAnchor constant:12],
            [labels.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [labels.trailingAnchor constraintEqualToAnchor:_playingView.leadingAnchor constant:-8],

            [_playingView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_playingView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_playingView.widthAnchor constraintEqualToConstant:18],
            [_playingView.heightAnchor constraintEqualToConstant:18],
        ]];
    }

    return self;
}

- (void)configureWithTrack:(YTMULocalTrack *)track {
    self.track = track;
    self.titleLabel.text = track.title;
    self.subtitleLabel.text = [self subtitleForTrack:track];

    self.artworkView.image = [track cachedThumbnailWithSize:48];
    if (!self.artworkView.image) {
        __weak typeof(self) weakSelf = self;
        [track loadThumbnailWithSize:48 completion:^(UIImage *image) {
            if (weakSelf.track == track) weakSelf.artworkView.image = image;
        }];
    }

    if (track.duration <= 0) {
        __weak typeof(self) weakSelf = self;
        [track loadDurationWithCompletion:^(NSTimeInterval duration) {
            if (weakSelf.track == track) weakSelf.subtitleLabel.text = [weakSelf subtitleForTrack:track];
        }];
    }

    [self updatePlayingState];
}

- (NSString *)subtitleForTrack:(YTMULocalTrack *)track {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (track.artist.length > 0) [parts addObject:track.artist];
    if (track.duration > 0) [parts addObject:YTMUDurationString(track.duration)];
    return [parts componentsJoinedByString:@" • "];
}

- (void)updatePlayingState {
    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    BOOL isCurrent = [player.currentTrack isEqual:self.track];

    self.playingView.hidden = !isCurrent;
    self.playingView.image = [UIImage systemImageNamed:player.isPlaying ? @"speaker.wave.2.fill" : @"speaker.fill"];
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:isCurrent ? UIFontWeightBold : UIFontWeightMedium];
}

@end

#pragma mark - Library

@interface YTMDownloads ()
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIView *emptyView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) YTMUMiniPlayerView *miniPlayer;
@property (nonatomic, strong) NSLayoutConstraint *searchBarTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *miniPlayerBottomConstraint;
@property (nonatomic, strong) NSArray<YTMULocalTrack *> *allTracks;
@property (nonatomic, strong) NSArray<YTMULocalTrack *> *visibleTracks;
@property (nonatomic, assign) YTMULibrarySort sortMode;
@property (nonatomic, assign) CGFloat topObstruction;
@property (nonatomic, assign) CGFloat bottomObstruction;
@property (nonatomic, strong) NSTimer *layoutTimer;
@property (nonatomic, weak) UIView *navigationBarView;
@property (nonatomic, weak) UIView *pivotBarView;
@property (nonatomic, weak) UIView *watchView;
@end

@implementation YTMDownloads

- (void)viewDidLoad {
    [super viewDidLoad];

    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = [UIColor colorWithRed:3/255.0 green:3/255.0 blue:3/255.0 alpha:1.0];
    self.sortMode = [[NSUserDefaults standardUserDefaults] integerForKey:YTMULibrarySortKey];
    self.topObstruction = -1;
    self.bottomObstruction = -1;

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = LOC_DEFAULT(@"SEARCH_MY_MUSIC", @"Search your music");
    self.searchBar.tintColor = [UIColor whiteColor];
    self.searchBar.keyboardAppearance = UIKeyboardAppearanceDark;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.returnKeyType = UIReturnKeyDone;
    self.searchBar.delegate = self;
    self.searchBar.searchTextField.textColor = [UIColor whiteColor];
    [self.view addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 64;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[YTMULibraryCell class] forCellReuseIdentifier:@"trackCell"];
    [self.view addSubview:self.tableView];

    [self buildHeaderView];
    [self buildEmptyView];

    __weak typeof(self) weakSelf = self;
    self.miniPlayer = [[YTMUMiniPlayerView alloc] init];
    self.miniPlayer.translatesAutoresizingMaskIntoConstraints = NO;
    self.miniPlayer.hidden = YES;
    self.miniPlayer.openHandler = ^{
        [weakSelf openNowPlaying];
    };
    [self.view addSubview:self.miniPlayer];

    self.searchBarTopConstraint = [self.searchBar.topAnchor constraintEqualToAnchor:self.view.topAnchor];
    self.miniPlayerBottomConstraint = [self.miniPlayer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        self.searchBarTopConstraint,
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.miniPlayer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.miniPlayer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.miniPlayer.heightAnchor constraintEqualToConstant:YTMUMiniPlayerHeight],
        self.miniPlayerBottomConstraint,
    ]];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(reloadData) name:@"ReloadDataNotification" object:nil];
    [center addObserver:self selector:@selector(playerStateChanged) name:YTMULocalPlayerStateDidChangeNotification object:nil];

    // YouTube Music's top bar, tab bar and its own mini player float over this view; keep clear of them as they move
    self.layoutTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateObstructions];
    }];

    [self reloadData];
    [self playerStateChanged];
}

- (void)dealloc {
    [self.layoutTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateObstructions];
}

#pragma mark - Building

- (UIButton *)pillButtonWithTitle:(NSString *)title symbol:(NSString *)symbol filled:(BOOL)filled action:(SEL)action {
    UIColor *foreground = filled ? [UIColor blackColor] : [UIColor whiteColor];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = filled ? [UIColor whiteColor] : [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    button.layer.cornerRadius = 20;
    button.tintColor = foreground;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:foreground forState:UIControlStateNormal];
    [button setTitleColor:[foreground colorWithAlphaComponent:0.5] forState:UIControlStateHighlighted];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    button.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, -4);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:40].active = YES;
    return button;
}

- (void)buildHeaderView {
    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 96)];
    self.headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.countLabel = [[UILabel alloc] init];
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.countLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.countLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    [self.headerView addSubview:self.countLabel];

    UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    menuButton.tintColor = [UIColor whiteColor];
    [menuButton setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    [menuButton addTarget:self action:@selector(menuTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:menuButton];

    UIButton *playButton = [self pillButtonWithTitle:LOC_DEFAULT(@"PLAY", @"Play") symbol:@"play.fill" filled:YES action:@selector(playAllTapped)];
    UIButton *shuffleButton = [self pillButtonWithTitle:LOC_DEFAULT(@"SHUFFLE", @"Shuffle") symbol:@"shuffle" filled:NO action:@selector(shuffleAllTapped)];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[playButton, shuffleButton]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 12;
    [self.headerView addSubview:buttons];

    [NSLayoutConstraint activateConstraints:@[
        [self.countLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16],
        [self.countLabel.centerYAnchor constraintEqualToAnchor:menuButton.centerYAnchor],

        [menuButton.topAnchor constraintEqualToAnchor:self.headerView.topAnchor],
        [menuButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-8],
        [menuButton.widthAnchor constraintEqualToConstant:44],
        [menuButton.heightAnchor constraintEqualToConstant:36],

        [buttons.topAnchor constraintEqualToAnchor:menuButton.bottomAnchor constant:4],
        [buttons.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-16],
    ]];
}

- (void)buildEmptyView {
    self.emptyView = [[UIView alloc] init];

    UIImageView *imageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"yt_outline_audio_48pt" inBundle:[NSBundle mainBundle] compatibleWithTraitCollection:nil]];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
    [self.emptyView addSubview:imageView];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.8];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.font = [UIFont systemFontOfSize:16];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    [self.emptyView addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [imageView.centerXAnchor constraintEqualToAnchor:self.emptyView.centerXAnchor],
        [imageView.bottomAnchor constraintEqualToAnchor:self.emptyView.centerYAnchor constant:-30],
        [imageView.widthAnchor constraintEqualToConstant:48],
        [imageView.heightAnchor constraintEqualToConstant:48],

        [self.emptyLabel.topAnchor constraintEqualToAnchor:imageView.bottomAnchor constant:20],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.emptyView.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.emptyView.trailingAnchor constant:-32],
    ]];
}

#pragma mark - Data

- (void)reloadData {
    NSArray<YTMULocalTrack *> *previous = self.allTracks;
    NSArray<YTMULocalTrack *> *tracks = [YTMULocalTrack allTracks];

    // Keep durations we already read so rows don't flicker
    for (YTMULocalTrack *track in tracks) {
        NSUInteger index = [previous indexOfObject:track];
        if (index != NSNotFound) track.duration = previous[index].duration;
    }

    self.allTracks = [self sortedTracks:tracks];
    [self applySearch];
}

- (NSArray<YTMULocalTrack *> *)sortedTracks:(NSArray<YTMULocalTrack *> *)tracks {
    switch (self.sortMode) {
        case YTMULibrarySortTitle:
            return [tracks sortedArrayUsingComparator:^NSComparisonResult(YTMULocalTrack *a, YTMULocalTrack *b) {
                return [a.title localizedCaseInsensitiveCompare:b.title];
            }];
        case YTMULibrarySortArtist:
            return [tracks sortedArrayUsingComparator:^NSComparisonResult(YTMULocalTrack *a, YTMULocalTrack *b) {
                NSComparisonResult result = [(a.artist ?: @"") localizedCaseInsensitiveCompare:(b.artist ?: @"")];
                return result != NSOrderedSame ? result : [a.title localizedCaseInsensitiveCompare:b.title];
            }];
        default:
            return [tracks sortedArrayUsingComparator:^NSComparisonResult(YTMULocalTrack *a, YTMULocalTrack *b) {
                return [b.dateAdded compare:a.dateAdded];
            }];
    }
}

- (void)applySearch {
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if (query.length == 0) {
        self.visibleTracks = self.allTracks;
    } else {
        self.visibleTracks = [self.allTracks filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(YTMULocalTrack *track, NSDictionary *bindings) {
            return [track matchesSearchText:query];
        }]];
    }

    NSUInteger total = self.allTracks.count;
    NSUInteger shown = self.visibleTracks.count;
    if (query.length > 0) {
        self.countLabel.text = [NSString stringWithFormat:LOC_DEFAULT(@"SONGS_FILTERED_COUNT", @"%lu of %lu songs"), (unsigned long)shown, (unsigned long)total];
    } else {
        self.countLabel.text = total == 1 ? LOC_DEFAULT(@"ONE_SONG", @"1 song") : [NSString stringWithFormat:LOC_DEFAULT(@"SONGS_COUNT", @"%lu songs"), (unsigned long)total];
    }

    self.tableView.tableHeaderView = total > 0 ? self.headerView : nil;
    self.searchBar.hidden = total == 0;

    if (total == 0) {
        self.emptyLabel.text = LOC(@"EMPTY");
        self.tableView.backgroundView = self.emptyView;
    } else if (shown == 0) {
        self.emptyLabel.text = LOC_DEFAULT(@"NO_RESULTS", @"No results");
        self.tableView.backgroundView = self.emptyView;
    } else {
        self.tableView.backgroundView = nil;
    }

    [self.tableView reloadData];
}

- (void)playerStateChanged {
    for (YTMULibraryCell *cell in self.tableView.visibleCells) {
        if ([cell isKindOfClass:[YTMULibraryCell class]]) [cell updatePlayingState];
    }

    BOOL showMiniPlayer = [YTMULocalPlayer sharedPlayer].currentTrack != nil;
    if (self.miniPlayer.hidden == showMiniPlayer) {
        self.miniPlayer.hidden = !showMiniPlayer;
        [self applyInsets];
    }
}

#pragma mark - Layout around YouTube Music's floating UI

- (UIView *)cachedView:(UIView *)cached inWindow:(UIWindow *)window matching:(BOOL (^)(UIView *view))matches {
    if (cached && cached.window == window) return cached;
    return YTMUFindView(window, matches);
}

- (void)updateObstructions {
    UIWindow *window = self.view.window;
    if (!window) return;

    CGRect bounds = self.view.bounds;
    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat bottomEdge = CGRectGetMaxY(bounds) - self.view.safeAreaInsets.bottom;

    Class navigationBarClass = NSClassFromString(@"YTMNavigationBarView");
    Class pivotBarClass = NSClassFromString(@"YTPivotBarView");
    Class watchControllerClass = NSClassFromString(@"YTMWatchViewController");

    self.navigationBarView = [self cachedView:self.navigationBarView inWindow:window matching:^BOOL(UIView *view) {
        return navigationBarClass && [view isKindOfClass:navigationBarClass];
    }];
    self.pivotBarView = [self cachedView:self.pivotBarView inWindow:window matching:^BOOL(UIView *view) {
        return pivotBarClass && [view isKindOfClass:pivotBarClass];
    }];
    self.watchView = [self cachedView:self.watchView inWindow:window matching:^BOOL(UIView *view) {
        return watchControllerClass && [view.nextResponder isKindOfClass:watchControllerClass];
    }];

    if (YTMUViewIsVisible(self.navigationBarView)) {
        CGRect frame = [self.navigationBarView convertRect:self.navigationBarView.bounds toView:self.view];
        if (CGRectGetMaxY(frame) > 0 && CGRectGetMinY(frame) < CGRectGetMidY(bounds)) top = MAX(top, CGRectGetMaxY(frame));
    } else if (!self.navigationBarView) {
        // Couldn't find it: leave room for a standard-height top bar, like the old Downloads list did
        top += 56;
    }

    // The tab bar, and YouTube Music's own mini player when something is loaded in it
    NSMutableArray<UIView *> *bottomViews = [NSMutableArray array];
    if (self.pivotBarView) [bottomViews addObject:self.pivotBarView];
    if (self.watchView) [bottomViews addObject:self.watchView];

    for (UIView *view in bottomViews) {
        if (!YTMUViewIsVisible(view)) continue;

        CGRect frame = [view convertRect:view.bounds toView:self.view];
        if (CGRectGetMinY(frame) > CGRectGetMidY(bounds) && CGRectGetMinY(frame) < bottomEdge) bottomEdge = CGRectGetMinY(frame);
    }

    if (!self.pivotBarView) bottomEdge = MIN(bottomEdge, CGRectGetMaxY(bounds) - self.view.safeAreaInsets.bottom - 56);

    CGFloat bottom = MAX(0, CGRectGetMaxY(bounds) - bottomEdge);
    if (fabs(top - self.topObstruction) < 0.5 && fabs(bottom - self.bottomObstruction) < 0.5) return;

    self.topObstruction = top;
    self.bottomObstruction = bottom;
    self.searchBarTopConstraint.constant = top + 4;
    self.miniPlayerBottomConstraint.constant = -(bottom + 8);
    [self applyInsets];
}

- (void)applyInsets {
    CGFloat bottom = MAX(0, self.bottomObstruction) + 8;
    if (!self.miniPlayer.hidden) bottom += YTMUMiniPlayerHeight + 8;

    UIEdgeInsets insets = self.tableView.contentInset;
    insets.bottom = bottom;
    self.tableView.contentInset = insets;
    self.tableView.scrollIndicatorInsets = insets;
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applySearch];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:searchBar.text.length > 0 animated:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    [searchBar setShowsCancelButton:NO animated:YES];
    [self applySearch];
}

#pragma mark - Playback

- (void)playAllTapped {
    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    player.shuffleEnabled = NO;
    [player playTracks:self.visibleTracks startingAtIndex:0];
}

- (void)shuffleAllTapped {
    [[YTMULocalPlayer sharedPlayer] shuffleTracks:self.visibleTracks];
}

- (void)openNowPlaying {
    if (![YTMULocalPlayer sharedPlayer].currentTrack || self.presentedViewController) return;

    [self.searchBar resignFirstResponder];
    [self presentViewController:[[YTMUNowPlayingViewController alloc] init] animated:YES completion:nil];
}

- (void)showToast:(NSString *)message {
    [[NSClassFromString(@"YTMToastController") alloc] showMessage:message];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleTracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULibraryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"trackCell" forIndexPath:indexPath];
    if (indexPath.row < (NSInteger)self.visibleTracks.count) [cell configureWithTrack:self.visibleTracks[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.searchBar resignFirstResponder];

    // Play from the tapped song through the rest of what's on screen (including search results)
    [[YTMULocalPlayer sharedPlayer] playTracks:self.visibleTracks startingAtIndex:indexPath.row];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULocalTrack *track = self.visibleTracks[indexPath.row];

    UIContextualAction *playNextAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self playNext:track];
        completionHandler(YES);
    }];
    playNextAction.image = [UIImage systemImageNamed:@"text.insert"];
    playNextAction.backgroundColor = [UIColor systemIndigoColor];

    UIContextualAction *queueAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self addToQueue:track];
        completionHandler(YES);
    }];
    queueAction.image = [UIImage systemImageNamed:@"text.append"];
    queueAction.backgroundColor = [UIColor systemGreenColor];

    return [UISwipeActionsConfiguration configurationWithActions:@[playNextAction, queueAction]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULocalTrack *track = self.visibleTracks[indexPath.row];

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self deleteTrack:track];
        completionHandler(YES);
    }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];

    UIContextualAction *renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self renameTrack:track];
        completionHandler(YES);
    }];
    renameAction.image = [UIImage systemImageNamed:@"pencil"];
    renameAction.backgroundColor = [UIColor systemOrangeColor];

    UIContextualAction *shareAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self activityControllerWithObjects:@[track.fileURL] sender:sourceView];
        completionHandler(YES);
    }];
    shareAction.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    shareAction.backgroundColor = [UIColor systemBlueColor];

    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, renameAction, shareAction]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    YTMULocalTrack *track = self.visibleTracks[indexPath.row];
    UIView *sourceView = [tableView cellForRowAtIndexPath:indexPath];

    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *playNext = [UIAction actionWithTitle:LOC_DEFAULT(@"PLAY_NEXT", @"Play next") image:[UIImage systemImageNamed:@"text.insert"] identifier:nil handler:^(UIAction *action) {
            [self playNext:track];
        }];
        UIAction *addToQueue = [UIAction actionWithTitle:LOC_DEFAULT(@"ADD_TO_QUEUE", @"Add to queue") image:[UIImage systemImageNamed:@"text.append"] identifier:nil handler:^(UIAction *action) {
            [self addToQueue:track];
        }];
        UIAction *share = [UIAction actionWithTitle:LOC_DEFAULT(@"SHARE", @"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action) {
            [self activityControllerWithObjects:@[track.fileURL] sender:sourceView];
        }];
        UIAction *rename = [UIAction actionWithTitle:LOC(@"RENAME") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *action) {
            [self renameTrack:track];
        }];
        UIAction *remove = [UIAction actionWithTitle:LOC(@"DELETE") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
            [self deleteTrack:track];
        }];
        remove.attributes = UIMenuElementAttributesDestructive;

        return [UIMenu menuWithTitle:track.title children:@[playNext, addToQueue, share, rename, remove]];
    }];
}

#pragma mark - Track actions

- (void)playNext:(YTMULocalTrack *)track {
    [[YTMULocalPlayer sharedPlayer] playNext:track];
    [self showToast:LOC_DEFAULT(@"WILL_PLAY_NEXT", @"Will play next")];
}

- (void)addToQueue:(YTMULocalTrack *)track {
    [[YTMULocalPlayer sharedPlayer] addToQueue:track];
    [self showToast:LOC_DEFAULT(@"ADDED_TO_QUEUE", @"Added to queue")];
}

- (void)renameTrack:(YTMULocalTrack *)track {
    NSURL *audioURL = track.fileURL;
    NSURL *coverURL = [track artworkURL];

    UITextView *textView = [[UITextView alloc] init];
    textView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.15];
    textView.layer.cornerRadius = 3.0;
    textView.layer.borderWidth = 1.0;
    textView.layer.borderColor = [[UIColor grayColor] colorWithAlphaComponent:0.5].CGColor;
    textView.textColor = [UIColor whiteColor];
    textView.text = track.fileName;
    textView.editable = YES;
    textView.scrollEnabled = YES;
    textView.textAlignment = NSTextAlignmentNatural;
    textView.font = [UIFont systemFontOfSize:14.0];

    YTAlertView *alertView = [NSClassFromString(@"YTAlertView") confirmationDialogWithAction:^{
        NSString *newName = [[textView.text stringByReplacingOccurrencesOfString:@"/" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (newName.length == 0 || [newName isEqualToString:track.fileName]) return;

        NSURL *folderURL = [audioURL URLByDeletingLastPathComponent];
        NSURL *newAudioURL = [folderURL URLByAppendingPathComponent:[newName stringByAppendingPathExtension:audioURL.pathExtension]];
        NSURL *newCoverURL = [folderURL URLByAppendingPathComponent:[newName stringByAppendingPathExtension:@"png"]];

        NSError *error = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:audioURL toURL:newAudioURL error:&error]) return;
        [[NSFileManager defaultManager] moveItemAtURL:coverURL toURL:newCoverURL error:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[YTMULocalPlayer sharedPlayer] trackWasRenamedFrom:audioURL to:newAudioURL];
            [self reloadData];
            [self showToast:LOC(@"DONE")];
        });
    }
    actionTitle:LOC(@"RENAME")];
    alertView.title = @"YTMusicUltimate";

    UIView *customView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, alertView.frameForDialog.size.width - 50, 75)];
    textView.frame = customView.frame;
    [customView addSubview:textView];

    alertView.customContentView = customView;
    [alertView show];
}

- (void)deleteTrack:(YTMULocalTrack *)track {
    YTAlertView *alertView = [NSClassFromString(@"YTAlertView") confirmationDialogWithAction:^{
        BOOL audioRemoved = [[NSFileManager defaultManager] removeItemAtURL:track.fileURL error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:[track artworkURL] error:nil];

        if (audioRemoved) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[YTMULocalPlayer sharedPlayer] trackWasRemoved:track.fileURL];
                [self reloadData];
            });
        }
    }
    actionTitle:LOC(@"DELETE")];
    alertView.title = @"YTMusicUltimate";
    alertView.subtitle = [NSString stringWithFormat:LOC(@"DELETE_MESSAGE"), track.fileName];
    [alertView show];
}

#pragma mark - Library menu

- (void)menuTapped:(UIButton *)sender {
    YTMActionSheetController *sheetController = [NSClassFromString(@"YTMActionSheetController") musicActionSheetController];
    sheetController.sourceView = sender;
    [sheetController addHeaderWithTitle:LOC_DEFAULT(@"SORT_BY", @"Sort by") subtitle:nil];

    NSArray *sortOptions = @[
        @[@(YTMULibrarySortRecent), LOC_DEFAULT(@"SORT_RECENT", @"Recently added"), @"clock"],
        @[@(YTMULibrarySortTitle), LOC_DEFAULT(@"SORT_TITLE", @"Title"), @"textformat"],
        @[@(YTMULibrarySortArtist), LOC_DEFAULT(@"SORT_ARTIST", @"Artist"), @"person"],
    ];

    for (NSArray *option in sortOptions) {
        YTMULibrarySort sort = [option[0] integerValue];
        NSString *icon = sort == self.sortMode ? @"checkmark" : option[2];
        [sheetController addAction:[NSClassFromString(@"YTActionSheetAction") actionWithTitle:option[1] iconImage:[self menuIcon:icon] style:0 handler:^{
            self.sortMode = sort;
            [[NSUserDefaults standardUserDefaults] setInteger:sort forKey:YTMULibrarySortKey];
            [self reloadData];
        }]];
    }

    [sheetController addAction:[NSClassFromString(@"YTActionSheetAction") actionWithTitle:LOC(@"SHARE_ALL") iconImage:[self menuIcon:@"square.and.arrow.up.on.square"] style:0 handler:^{
        NSMutableArray<NSURL *> *files = [NSMutableArray array];
        for (YTMULocalTrack *track in self.allTracks) [files addObject:track.fileURL];
        [self activityControllerWithObjects:files sender:sender];
    }]];

    [sheetController addAction:[NSClassFromString(@"YTActionSheetAction") actionWithTitle:LOC(@"REMOVE_ALL") iconImage:[self menuIcon:@"trash"] style:0 handler:^{
        [self removeAll];
    }]];

    [sheetController presentFromViewController:self animated:YES completion:nil];
}

- (UIImage *)menuIcon:(NSString *)symbol {
    UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular]];
    return [image imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (void)removeAll {
    YTAlertView *alertView = [NSClassFromString(@"YTAlertView") confirmationDialogWithAction:^{
        BOOL audiosRemoved = [[NSFileManager defaultManager] removeItemAtURL:[YTMULocalTrack libraryURL] error:nil];

        if (audiosRemoved) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[YTMULocalPlayer sharedPlayer] stop];
                [self reloadData];
            });
        }
    }
    actionTitle:LOC(@"DELETE")];
    alertView.title = @"YTMusicUltimate";
    alertView.subtitle = [NSString stringWithFormat:LOC(@"DELETE_MESSAGE"), LOC(@"ALL_DOWNLOADS")];
    [alertView show];
}

- (void)activityControllerWithObjects:(NSArray<id> *)items sender:(UIView *)sender {
    if (items.count == 0) return;

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    activityVC.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];

    UIPopoverPresentationController *popover = activityVC.popoverPresentationController;
    if (popover && sender) {
        popover.sourceView = sender;
        popover.sourceRect = sender.bounds;
    }

    [self presentViewController:activityVC animated:YES completion:nil];
}

@end
