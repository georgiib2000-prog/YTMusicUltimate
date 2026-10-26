#import "YTMDownloads.h"
#import "../LocalPlayer/YTMULocalPlayer.h"
#import "../LocalPlayer/YTMUMiniPlayerView.h"
#import "../LocalPlayer/YTMUNowPlayingViewController.h"
#import "../Utils/MBProgressHUD/MBProgressHUD.h"

// Everything in this tab uses UIKit's own alerts, sheets and HUDs rather than YouTube Music's private
// classes, which change between app versions and crash when a selector disappears.

// Never nil, even if the tweak's bundle failed to load: UIAlertAction throws on a nil title
#define YTMU_STR(key, fallback) (LOC_DEFAULT(key, fallback) ?: fallback)

typedef NS_ENUM(NSInteger, YTMULibrarySort) {
    YTMULibrarySortRecent,
    YTMULibrarySortTitle,
    YTMULibrarySortArtist,
    YTMULibrarySortCustom
};

static NSString *const YTMULibrarySortKey = @"YTMULibrarySortMode";
static NSString *const YTMULibraryCustomOrderKey = @"YTMULibraryCustomOrder";
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
    if (!root) return nil;

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
        self.showsReorderControl = YES;
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
    BOOL isCurrent = self.track && [player.currentTrack isEqual:self.track];

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
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIButton *doneButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIView *emptyView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) YTMUMiniPlayerView *miniPlayer;
@property (nonatomic, strong) NSLayoutConstraint *searchBarTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *miniPlayerBottomConstraint;
@property (nonatomic, strong) NSArray<YTMULocalTrack *> *allTracks;
@property (nonatomic, strong) NSArray<YTMULocalTrack *> *visibleTracks;
@property (nonatomic, assign) YTMULibrarySort sortMode;
@property (nonatomic, assign, getter=isReordering) BOOL reordering;
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
    self.topObstruction = -1;
    self.bottomObstruction = -1;

    NSInteger savedSort = [[NSUserDefaults standardUserDefaults] integerForKey:YTMULibrarySortKey];
    self.sortMode = (savedSort >= YTMULibrarySortRecent && savedSort <= YTMULibrarySortCustom) ? savedSort : YTMULibrarySortRecent;

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = YTMU_STR(@"SEARCH_MY_MUSIC", @"Search your music");
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

    self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.menuButton.tintColor = [UIColor whiteColor];
    [self.menuButton setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    [self.menuButton addTarget:self action:@selector(menuTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.menuButton];

    self.doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.doneButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.doneButton.tintColor = [UIColor whiteColor];
    self.doneButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    self.doneButton.hidden = YES;
    [self.doneButton setTitle:YTMU_STR(@"DONE", @"Done") forState:UIControlStateNormal];
    [self.doneButton addTarget:self action:@selector(endReordering) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.doneButton];

    self.playButton = [self pillButtonWithTitle:YTMU_STR(@"PLAY", @"Play") symbol:@"play.fill" filled:YES action:@selector(playAllTapped)];
    self.shuffleButton = [self pillButtonWithTitle:YTMU_STR(@"SHUFFLE", @"Shuffle") symbol:@"shuffle" filled:NO action:@selector(shuffleAllTapped)];

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.playButton, self.shuffleButton]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 12;
    [self.headerView addSubview:buttons];

    [NSLayoutConstraint activateConstraints:@[
        [self.countLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16],
        [self.countLabel.centerYAnchor constraintEqualToAnchor:self.menuButton.centerYAnchor],
        [self.countLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.doneButton.leadingAnchor constant:-8],

        [self.menuButton.topAnchor constraintEqualToAnchor:self.headerView.topAnchor],
        [self.menuButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-8],
        [self.menuButton.widthAnchor constraintEqualToConstant:44],
        [self.menuButton.heightAnchor constraintEqualToConstant:36],

        [self.doneButton.centerYAnchor constraintEqualToAnchor:self.menuButton.centerYAnchor],
        [self.doneButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-16],

        [buttons.topAnchor constraintEqualToAnchor:self.menuButton.bottomAnchor constant:4],
        [buttons.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-16],
    ]];
}

- (void)buildEmptyView {
    self.emptyView = [[UIView alloc] init];

    UIImageView *imageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"yt_outline_audio_48pt" inBundle:[NSBundle mainBundle] compatibleWithTraitCollection:nil] ?: [UIImage systemImageNamed:@"music.note"]];
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

- (YTMULocalTrack *)trackAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.row < 0 || indexPath.row >= (NSInteger)self.visibleTracks.count) return nil;
    return self.visibleTracks[indexPath.row];
}

- (void)reloadData {
    NSArray<YTMULocalTrack *> *previous = self.allTracks;
    NSArray<YTMULocalTrack *> *tracks = [YTMULocalTrack allTracks];

    // Keep durations we already read so rows don't flicker
    for (YTMULocalTrack *track in tracks) {
        NSUInteger index = [previous indexOfObject:track];
        if (index != NSNotFound) track.duration = previous[index].duration;
    }

    self.allTracks = [self sortedTracks:tracks];
    if (self.allTracks.count == 0 && self.isReordering) [self endReordering];
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

        case YTMULibrarySortCustom: {
            NSArray<NSString *> *order = [[NSUserDefaults standardUserDefaults] stringArrayForKey:YTMULibraryCustomOrderKey];
            NSMutableDictionary<NSString *, NSNumber *> *positions = [NSMutableDictionary dictionary];
            [order enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) {
                if (!positions[name]) positions[name] = @(index);
            }];

            return [tracks sortedArrayUsingComparator:^NSComparisonResult(YTMULocalTrack *a, YTMULocalTrack *b) {
                NSNumber *positionA = positions[a.fileURL.lastPathComponent];
                NSNumber *positionB = positions[b.fileURL.lastPathComponent];

                // Songs downloaded since the order was saved go on top, newest first
                if (!positionA && !positionB) return [b.dateAdded compare:a.dateAdded];
                if (!positionA) return NSOrderedAscending;
                if (!positionB) return NSOrderedDescending;
                return [positionA compare:positionB];
            }];
        }

        default:
            return [tracks sortedArrayUsingComparator:^NSComparisonResult(YTMULocalTrack *a, YTMULocalTrack *b) {
                return [b.dateAdded compare:a.dateAdded];
            }];
    }
}

- (void)setSortModeAndSave:(YTMULibrarySort)sortMode {
    self.sortMode = sortMode;
    [[NSUserDefaults standardUserDefaults] setInteger:sortMode forKey:YTMULibrarySortKey];
}

- (void)saveCustomOrder {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (YTMULocalTrack *track in self.allTracks) {
        NSString *name = track.fileURL.lastPathComponent;
        if (name) [names addObject:name];
    }
    [[NSUserDefaults standardUserDefaults] setObject:names forKey:YTMULibraryCustomOrderKey];
}

- (void)renameCustomOrderEntryFrom:(NSString *)oldName to:(NSString *)newName {
    NSMutableArray<NSString *> *order = [[[NSUserDefaults standardUserDefaults] stringArrayForKey:YTMULibraryCustomOrderKey] mutableCopy];
    NSUInteger index = [order indexOfObject:oldName];
    if (!order || index == NSNotFound || !newName) return;

    order[index] = newName;
    [[NSUserDefaults standardUserDefaults] setObject:order forKey:YTMULibraryCustomOrderKey];
}

- (void)applySearch {
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";

    if (query.length == 0 || self.isReordering) {
        self.visibleTracks = self.allTracks ?: @[];
    } else {
        self.visibleTracks = [self.allTracks filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(YTMULocalTrack *track, NSDictionary *bindings) {
            return [track matchesSearchText:query];
        }]];
    }

    NSUInteger total = self.allTracks.count;
    NSUInteger shown = self.visibleTracks.count;

    self.tableView.tableHeaderView = total > 0 ? self.headerView : nil;
    self.searchBar.hidden = total == 0;

    if (total == 0) {
        self.emptyLabel.text = YTMU_STR(@"EMPTY", @"Songs and videos you download will show here.\n\nPlay anything, tap the download button in the player and choose Download audio.");
        self.tableView.backgroundView = self.emptyView;
    } else if (shown == 0) {
        self.emptyLabel.text = YTMU_STR(@"NO_RESULTS", @"No results");
        self.tableView.backgroundView = self.emptyView;
    } else {
        self.tableView.backgroundView = nil;
    }

    [self updateHeaderControls];
    [self.tableView reloadData];
}

- (void)updateHeaderControls {
    BOOL reordering = self.isReordering;
    NSUInteger total = self.allTracks.count;
    NSUInteger shown = self.visibleTracks.count;
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if (reordering) {
        self.countLabel.text = YTMU_STR(@"REORDER_HINT", @"Drag the handles to reorder");
    } else if (query.length > 0) {
        self.countLabel.text = [NSString stringWithFormat:YTMU_STR(@"SONGS_FILTERED_COUNT", @"%lu of %lu songs"), (unsigned long)shown, (unsigned long)total];
    } else {
        self.countLabel.text = total == 1 ? YTMU_STR(@"ONE_SONG", @"1 song") : [NSString stringWithFormat:YTMU_STR(@"SONGS_COUNT", @"%lu songs"), (unsigned long)total];
    }

    self.menuButton.hidden = reordering;
    self.doneButton.hidden = !reordering;

    for (UIButton *button in @[self.playButton, self.shuffleButton]) {
        button.enabled = !reordering && shown > 0;
        button.alpha = button.enabled ? 1.0 : 0.4;
    }

    self.searchBar.userInteractionEnabled = !reordering;
    self.searchBar.alpha = reordering ? 0.4 : 1.0;
}

- (void)playerStateChanged {
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell isKindOfClass:[YTMULibraryCell class]]) [(YTMULibraryCell *)cell updatePlayingState];
    }

    BOOL showMiniPlayer = [YTMULocalPlayer sharedPlayer].currentTrack != nil;
    if (self.miniPlayer.hidden == showMiniPlayer) {
        self.miniPlayer.hidden = !showMiniPlayer;
        [self applyInsets];
    }
}

#pragma mark - Reordering

- (void)beginReordering {
    if (self.allTracks.count == 0 || self.isReordering) return;

    [self.searchBar resignFirstResponder];
    self.searchBar.text = @"";
    [self.searchBar setShowsCancelButton:NO animated:NO];

    // Start from whatever order is on screen now
    if (self.sortMode != YTMULibrarySortCustom) {
        [self saveCustomOrder];
        [self setSortModeAndSave:YTMULibrarySortCustom];
    }

    self.reordering = YES;
    [self reloadData];
    [self.tableView setEditing:YES animated:YES];
}

- (void)endReordering {
    if (!self.isReordering) return;

    self.reordering = NO;
    [self saveCustomOrder];
    [self.tableView setEditing:NO animated:YES];
    [self updateHeaderControls];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.isReordering;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSMutableArray<YTMULocalTrack *> *tracks = [self.allTracks mutableCopy];
    NSInteger from = sourceIndexPath.row;
    NSInteger to = destinationIndexPath.row;

    if (from < 0 || to < 0 || from >= (NSInteger)tracks.count || to >= (NSInteger)tracks.count) {
        // Out of sync with the table somehow; redraw from the real data instead of guessing
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
        });
        return;
    }

    YTMULocalTrack *track = tracks[from];
    [tracks removeObjectAtIndex:from];
    [tracks insertObject:track atIndex:to];

    self.allTracks = tracks;
    self.visibleTracks = tracks;
    [self saveCustomOrder];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
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
    if (!isfinite(top) || !isfinite(bottom)) return;
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
    if (self.visibleTracks.count == 0) return;

    YTMULocalPlayer *player = [YTMULocalPlayer sharedPlayer];
    player.shuffleEnabled = NO;
    [player playTracks:self.visibleTracks startingAtIndex:0];
}

- (void)shuffleAllTapped {
    if (self.visibleTracks.count == 0) return;
    [[YTMULocalPlayer sharedPlayer] shuffleTracks:self.visibleTracks];
}

- (void)openNowPlaying {
    if (![YTMULocalPlayer sharedPlayer].currentTrack || self.presentedViewController || !self.view.window) return;

    [self.searchBar resignFirstResponder];
    [self presentViewController:[[YTMUNowPlayingViewController alloc] init] animated:YES completion:nil];
}

- (void)showToast:(NSString *)message {
    UIView *host = self.view.window ?: self.view;
    if (!host || message.length == 0) return;

    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:host animated:YES];
    hud.mode = MBProgressHUDModeText;
    hud.label.text = message;
    hud.label.numberOfLines = 0;
    hud.userInteractionEnabled = NO;
    [hud hideAnimated:YES afterDelay:1.5];
}

// Present only when nothing else is on screen, so taps during an animation can't stack two alerts
- (void)presentSafely:(UIViewController *)viewController sourceView:(UIView *)sourceView {
    [self presentSafely:viewController sourceView:sourceView attempt:0];
}

- (void)presentSafely:(UIViewController *)viewController sourceView:(UIView *)sourceView attempt:(NSInteger)attempt {
    if (!self.view.window) return;

    UIViewController *presented = self.presentedViewController;
    if (presented) {
        // A menu that is still animating away; try again once it's gone
        if (presented.isBeingDismissed && attempt < 5) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self presentSafely:viewController sourceView:sourceView attempt:attempt + 1];
            });
        }
        return;
    }

    UIPopoverPresentationController *popover = viewController.popoverPresentationController;
    if (popover) {
        UIView *anchor = sourceView.window ? sourceView : self.view;
        popover.sourceView = anchor;
        popover.sourceRect = sourceView.window ? sourceView.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }

    [self presentViewController:viewController animated:YES completion:nil];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleTracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULibraryCell *cell = [tableView dequeueReusableCellWithIdentifier:@"trackCell" forIndexPath:indexPath];
    YTMULocalTrack *track = [self trackAtIndexPath:indexPath];
    if (track) [cell configureWithTrack:track];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.isReordering || ![self trackAtIndexPath:indexPath]) return;

    [self.searchBar resignFirstResponder];

    // Play from the tapped song through the rest of what's on screen (including search results)
    [[YTMULocalPlayer sharedPlayer] playTracks:self.visibleTracks startingAtIndex:indexPath.row];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    YTMULocalTrack *track = [self trackAtIndexPath:indexPath];
    if (!track || self.isReordering) return nil;

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
    YTMULocalTrack *track = [self trackAtIndexPath:indexPath];
    if (!track || self.isReordering) return nil;

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        completionHandler(YES);
        [self confirmDeleteTrack:track sourceView:sourceView];
    }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];

    UIContextualAction *renameAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        completionHandler(YES);
        [self promptRenameTrack:track];
    }];
    renameAction.image = [UIImage systemImageNamed:@"pencil"];
    renameAction.backgroundColor = [UIColor systemOrangeColor];

    UIContextualAction *shareAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        completionHandler(YES);
        [self shareFiles:@[track.fileURL] sourceView:sourceView];
    }];
    shareAction.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    shareAction.backgroundColor = [UIColor systemBlueColor];

    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, renameAction, shareAction]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    YTMULocalTrack *track = [self trackAtIndexPath:indexPath];
    if (!track || self.isReordering) return nil;

    __weak UIView *sourceView = [tableView cellForRowAtIndexPath:indexPath];

    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *playNext = [UIAction actionWithTitle:YTMU_STR(@"PLAY_NEXT", @"Play next") image:[UIImage systemImageNamed:@"text.insert"] identifier:nil handler:^(UIAction *action) {
            [self playNext:track];
        }];
        UIAction *addToQueue = [UIAction actionWithTitle:YTMU_STR(@"ADD_TO_QUEUE", @"Add to queue") image:[UIImage systemImageNamed:@"text.append"] identifier:nil handler:^(UIAction *action) {
            [self addToQueue:track];
        }];
        UIAction *share = [UIAction actionWithTitle:YTMU_STR(@"SHARE", @"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action) {
            [self shareFiles:@[track.fileURL] sourceView:sourceView];
        }];
        UIAction *rename = [UIAction actionWithTitle:YTMU_STR(@"RENAME", @"Rename") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *action) {
            [self promptRenameTrack:track];
        }];
        UIAction *remove = [UIAction actionWithTitle:YTMU_STR(@"DELETE", @"Delete") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
            [self confirmDeleteTrack:track sourceView:sourceView];
        }];
        remove.attributes = UIMenuElementAttributesDestructive;

        return [UIMenu menuWithTitle:track.title ?: @"" children:@[playNext, addToQueue, share, rename, remove]];
    }];
}

#pragma mark - Track actions

- (void)playNext:(YTMULocalTrack *)track {
    [[YTMULocalPlayer sharedPlayer] playNext:track];
    [self showToast:YTMU_STR(@"WILL_PLAY_NEXT", @"Will play next")];
}

- (void)addToQueue:(YTMULocalTrack *)track {
    [[YTMULocalPlayer sharedPlayer] addToQueue:track];
    [self showToast:YTMU_STR(@"ADDED_TO_QUEUE", @"Added to queue")];
}

- (void)promptRenameTrack:(YTMULocalTrack *)track {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTMU_STR(@"RENAME", @"Rename") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = track.fileName;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.keyboardAppearance = UIKeyboardAppearanceDark;
    }];

    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"CANCEL", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"RENAME", @"Rename") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self renameTrack:track to:weakAlert.textFields.firstObject.text];
    }]];

    [self presentSafely:alert sourceView:nil];
}

- (void)renameTrack:(YTMULocalTrack *)track to:(NSString *)name {
    NSString *newName = name ?: @"";
    for (NSString *bad in @[@"/", @":", @"\n", @"\r"]) {
        newName = [newName stringByReplacingOccurrencesOfString:bad withString:@""];
    }
    newName = [newName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (newName.length == 0 || [newName hasPrefix:@"."] || [newName isEqualToString:track.fileName]) return;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *audioURL = track.fileURL;
    NSURL *coverURL = [track artworkURL];
    NSURL *folderURL = [audioURL URLByDeletingLastPathComponent];
    NSString *extension = audioURL.pathExtension.length > 0 ? audioURL.pathExtension : @"m4a";
    NSURL *newAudioURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", newName, extension]];
    NSURL *newCoverURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", newName]];

    if ([fileManager fileExistsAtPath:newAudioURL.path]) {
        [self showToast:YTMU_STR(@"NAME_TAKEN", @"A song with that name already exists")];
        return;
    }

    if (![fileManager moveItemAtURL:audioURL toURL:newAudioURL error:nil]) {
        [self showToast:YTMU_STR(@"OOPS", @"Oops\nsomething went wrong")];
        return;
    }

    if ([fileManager fileExistsAtPath:coverURL.path] && ![fileManager fileExistsAtPath:newCoverURL.path]) {
        [fileManager moveItemAtURL:coverURL toURL:newCoverURL error:nil];
    }

    [self renameCustomOrderEntryFrom:audioURL.lastPathComponent to:newAudioURL.lastPathComponent];
    [[YTMULocalPlayer sharedPlayer] trackWasRenamedFrom:audioURL to:newAudioURL];
    [self reloadData];
    [self showToast:YTMU_STR(@"DONE", @"Done")];
}

- (void)confirmDeleteTrack:(YTMULocalTrack *)track sourceView:(UIView *)sourceView {
    NSString *message = [NSString stringWithFormat:YTMU_STR(@"DELETE_MESSAGE", @"Are you sure you want to delete %@?"), track.fileName ?: @""];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"CANCEL", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"DELETE", @"Delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self deleteTrack:track];
    }]];

    [self presentSafely:alert sourceView:sourceView];
}

- (void)deleteTrack:(YTMULocalTrack *)track {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL audioRemoved = [fileManager removeItemAtURL:track.fileURL error:nil];
    [fileManager removeItemAtURL:[track artworkURL] error:nil];

    if (audioRemoved || ![fileManager fileExistsAtPath:track.fileURL.path]) {
        [[YTMULocalPlayer sharedPlayer] trackWasRemoved:track.fileURL];
    } else {
        [self showToast:YTMU_STR(@"OOPS", @"Oops\nsomething went wrong")];
    }

    [self reloadData];
}

#pragma mark - Library menu

- (void)menuTapped:(UIButton *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    if (self.allTracks.count > 1) {
        [sheet addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"REORDER", @"Reorder songs") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self beginReordering];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@: %@", YTMU_STR(@"SORT_BY", @"Sort by"), [self nameForSort:self.sortMode]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showSortMenu:sender];
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"SHARE_ALL", @"Share all audios") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSMutableArray<NSURL *> *files = [NSMutableArray array];
        for (YTMULocalTrack *track in self.allTracks) [files addObject:track.fileURL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self shareFiles:files sourceView:sender];
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"REMOVE_ALL", @"Remove all audios") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self confirmRemoveAll:sender];
        });
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"CANCEL", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentSafely:sheet sourceView:sender];
}

- (NSString *)nameForSort:(YTMULibrarySort)sort {
    switch (sort) {
        case YTMULibrarySortTitle: return YTMU_STR(@"SORT_TITLE", @"Title");
        case YTMULibrarySortArtist: return YTMU_STR(@"SORT_ARTIST", @"Artist");
        case YTMULibrarySortCustom: return YTMU_STR(@"SORT_CUSTOM", @"Custom order");
        default: return YTMU_STR(@"SORT_RECENT", @"Recently added");
    }
}

- (void)showSortMenu:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:YTMU_STR(@"SORT_BY", @"Sort by") message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSNumber *option in @[@(YTMULibrarySortCustom), @(YTMULibrarySortRecent), @(YTMULibrarySortTitle), @(YTMULibrarySortArtist)]) {
        YTMULibrarySort sort = option.integerValue;
        NSString *title = [self nameForSort:sort];
        if (sort == self.sortMode) title = [title stringByAppendingString:@"  ✓"];

        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            // A custom order that was never saved starts from the current one
            if (sort == YTMULibrarySortCustom && ![[NSUserDefaults standardUserDefaults] stringArrayForKey:YTMULibraryCustomOrderKey]) {
                [self saveCustomOrder];
            }
            [self setSortModeAndSave:sort];
            [self reloadData];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"CANCEL", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentSafely:sheet sourceView:sourceView];
}

- (void)confirmRemoveAll:(UIView *)sourceView {
    NSString *message = [NSString stringWithFormat:YTMU_STR(@"DELETE_MESSAGE", @"Are you sure you want to delete %@?"), YTMU_STR(@"ALL_DOWNLOADS", @"all download audios")];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"CANCEL", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:YTMU_STR(@"DELETE", @"Delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[YTMULocalPlayer sharedPlayer] stop];
        [[NSFileManager defaultManager] removeItemAtURL:[YTMULocalTrack libraryURL] error:nil];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:YTMULibraryCustomOrderKey];
        [self reloadData];
    }]];

    [self presentSafely:alert sourceView:sourceView];
}

- (void)shareFiles:(NSArray<NSURL *> *)files sourceView:(UIView *)sourceView {
    NSMutableArray<NSURL *> *existing = [NSMutableArray array];
    for (NSURL *file in files) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:file.path]) [existing addObject:file];
    }
    if (existing.count == 0) return;

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:existing applicationActivities:nil];
    activityVC.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];
    [self presentSafely:activityVC sourceView:sourceView];
}

@end
