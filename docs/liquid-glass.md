# 液态玻璃界面

应用最低版本为 iOS 26。交互层使用系统 Liquid Glass，不用半透明填色或模糊层代替玻璃材质。

- 导航栏、标签栏、搜索、菜单和 popover 使用 UIKit 的系统外观。
- iPhone 迷你播放条由 `UITabAccessory` 提供玻璃与收起动画，内部不叠加第二层玻璃。独立播放条使用开启交互反馈的 `UIGlassEffect`，以 `cornerConfiguration` 设置胶囊外形。
- 全屏播放器的播放与切歌使用无底框图标和按压反馈；歌词、队列等选中状态使用圆形指示。队列模式使用独立原生玻璃按钮，音量条使用系统音量控件。
- 资料库的播放与随机播放入口、设置表单操作按钮使用相同的系统玻璃语言。
- 歌词、歌曲列表、封面及页面底色是内容层，不整页覆盖玻璃；歌词顶部信息固定，队列卡片和区段标题随列表滚动，遵循播放器布局约定。
- 系统玻璃负责材质和辅助功能适配；播放／暂停的图标切换与按压缩放分别由独立容器控制，减少动态效果时直接更新状态。

## 验证

在 macOS / Xcode 26 上运行 `bash BuildTools/test-iphone-changes.sh`，并在 iOS 26 模拟器或真机检查：

1. 浅色和深色主题下，滚动资料库时底部播放条只有一层玻璃边缘；收起与展开衔接正常。
2. 播放、暂停、切歌与音乐/播客切换后图标正确，按压反馈可见；显示额外快进/快退按钮时保持间距。
3. 歌词与队列切换后的选中状态清晰，队列标题不覆盖歌曲；快速切换、历史滚动和下滑取消仍正常。
4. 资料库按钮在窄屏、中英文标题下无截断；菜单、系统音量拖动和设置按钮均可操作。
5. 开启减少动态效果、降低透明度与增强对比度后，文字和选中状态仍能辨认。

Windows 上的源码检查不能替代以上构建及视觉验证。

参考：[Apple — Build a UIKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/284/)。


### Background artwork and detail pages

Artwork palette extraction is foreground UI work. `LibraryEntityImage.loadArtworkPalette`
checks application state before and after asynchronous decoding, caches results by artwork
path, and uses a fixed 64×64 RGB histogram. It performs no Core Image clustering or detached
palette task. The player and artwork headers cancel visual tasks on resignation; hidden
player callbacks do not update lyrics, queue rows, or gradients. Lock-screen artwork still
uses the shared prepared-image loader independently of these UI guards.

The November CPU-resource report records 48 CPU seconds in 48 wall seconds and an OS kill.
Image/Core Image stacks and the previous detached clustering path identify a strong suspect,
not a symbolicated function-level diagnosis. New IPA artifacts retain matching dSYMs/UUIDs.
Simulator resource reports check that palette computation counts stay constant in actual
background phases; they measure process CPU/RSS, not iPhone battery consumption.

Album details use centered artwork, title/artist metadata and playback controls, track-number
rows and a release/count/duration footer. There is no recommendation section. Artist details
have a full-width hero and exactly two sections: listening-count song rankings and horizontal
albums. The first five songs link to the complete ranking; ordering uses real `playCount`,
with stable title/ID ties and offline filtering. Song swipe actions show their icons only.

Regression coverage includes dense 1200px artwork with a bounded runtime, dominant/transparent
color handling, ranking/count updates, and actual album/artist screenshots and dock reversals.


### Detail navigation and account colors

Visible decoded artwork resolves its cached or bounded palette synchronously before a
new detail view's first frame. A cold cover is still loaded asynchronously; its background
fades after navigation completes. Library returns reuse the current snapshot, with category
reconfiguration only when the account theme changes. Remote detail sync starts in
`viewDidAppear`, keeping fetch/parse/snapshot work out of the navigation animation.

Song swipe styling checks the underlying `AbstractPlayable.isSong`, including generic
wrappers returned by playlist entries. Artist names have a separate region below the hero
image. Library category icons use the account theme. New accounts default to red; a one-time
migration changes the previous orange default to red without changing other account colors.
Regression probes include wrapped playlist swipes, the first displayed album background,
theme-tinted category icons and non-overlapping artist image/name frames.


### Return-transition chrome and artwork bounds

`MusicNavigationController` owns main-stack navigation appearance. It changes the navigation
bar and bottom dock with the same transition coordinator and restores the original appearance
when an interactive return is cancelled. Artwork controllers no longer mutate and later
restore shared navigation properties after a return. The Home avatar has an explicit account
tint, and Home snapshots/network refreshes are deferred until the page is visible; automatic
remote refresh is limited to once per minute on return.

The dock anchor and bottom inset use the settled tab-bar position, avoiding transient frame
readbacks during a push/pop. Bottom chrome has an explicit light/dark interface style for the
active page rather than changing contrast after content settles.

Artwork's internal nib margins ignore safe-area insets: the enclosing page handles those.
The artist's square photo and name have a 12pt visible gap. The regression probe measures the
inner image frame, not just its outer container. A re-decode of an unchanged artwork path keeps
the currently displayed image until its replacement is ready instead of flashing a placeholder.
New probes sample Home returns from albums, playlists and artists throughout push/pop, checking
button tints, synchronized bottom contrast and dock geometry.


The scroll diagnostic identified a concrete delayed inset: the album's bottom inset changed
from 83pt to 151pt while its dock, native bar, scroll offset and viewport frames stayed fixed.
The additional 68pt must belong to the leaf page before appearance, not its navigation
container. `reserveDockSpace` shares one per-page original inset across navigation and the
legacy safe-area helper, retaining exactly 56pt + 12pt regardless of dock collapse state.

The complete player regression also exposed a real release stall: the CI recording holds
the dragged lyrics page at its full size before jumping directly to Home. Interactive
player dismissals now pause, scrub, and continue their own `UIViewPropertyAnimator` through
`PlayerSurfaceInteraction`, while reporting progress and finish/cancellation to UIKit's
transition context. The surface and shared cover continue to read the same timing probe.
Interaction state remains owned until transition completion, including cancellation.

The first-collapse probe runs immediately after detail returns, before any test-only Home
scroll or forced layout can settle pending work. Failures retain geometry and compositor
captures and mark the whole suite failed while allowing independent page checks to run.
Library/playlist layout and scroll probes also run before full-player dismissal checks.

The first-collapse failure capture shows the dock expanded again, rather than sitting
at a wrong compact coordinate. Tab selection had been synchronized only during layout;
the first collapse could request the layout that finally processed a previous selection
change, whose reset then expanded the dock. Selection now synchronizes at the tab setter
and native selection callback, and is resolved before processing a scroll delta. Layout
remains an idempotent fallback, not the first owner of the tab-change reset.
