# ACGO PC 客户端（Flutter macOS + Windows）UI 设计规范

> 整体风格为 **正式、极简、扁平** 的桌面应用设计语言：
> 白色/深色双主题、无边框分区、二层背景层次、系统主题蓝、克制动效、iOS 风格统一圆角。
> 所有颜色与圆角统一取自 `lib/app_theme.dart`，**禁止在业务代码中硬编码颜色/圆角**。
> 主题偏好统一由 `lib/theme_controller.dart` 管理。

---

## 0. 平台差异（顶部栏）

macOS 与 Windows 双端，顶部栏存在差异（其余布局/颜色/圆角/组件通用）。

| 项 | macOS | Windows |
|----|-------|---------|
| 原生标题栏 | 隐藏（红黄绿按钮悬浮在左上角） | 隐藏（自绘顶栏） |
| 顶栏高度 | 20px（内容尽量上移） | 35px（内容上移） |
| 顶栏范围 | 仅内容区（不含左侧导航栏） | 仅内容区（不含左侧导航栏） |
| 左侧导航栏宽度 | 150px（Finder 风格：图标 + 文字） | 150px（Finder 风格，与 macOS 一致） |
| 左侧导航栏 logo | 不显示 | 显示（导航栏顶部，保持原尺寸/位置，不受右侧顶栏影响） |
| 红黄绿安全区 | 导航栏顶部 `kMacTrafficLightWidth`(78px) 容纳左上角红黄绿按钮 | 无 |
| 自绘窗口按钮 | 无（原生红黄绿承担） | 内容区顶栏右侧显示缩小/全屏/关闭 |
| 实现 | `_TitleBar` + `_buildMacRail`（`Platform.isMacOS` 分支） | `_TitleBar` + `_buildMacRail`（共享） |

> 顶栏与左侧导航栏互不影响：顶栏（拖拽区 + 窗口按钮）只渲染在右侧内容区顶部；左侧导航栏顶部独立渲染 logo（Windows）或红黄绿安全区（macOS），顶栏高度变化不会移动或缩放 logo。

**macOS 专属逻辑一律用 `Platform.isMacOS` 分支隔离，Windows 不受影响。**

### 0.1 通用规则：不遮盖左侧导航栏

- 在有左侧导航栏的窗口（主窗口）中，任何二级页面（帖子详情、发帖页、通知页等）**不得遮盖左侧导航栏**，应作为「内容区内嵌/覆盖」展示（保留左侧栏）。
- 唯一例外：**当前窗口本身不存在左侧栏**（如登录页、注册页、启动页）时不受此限。
- 双端统一通过 `_HomePageState._macOverlay`（内容区覆盖层）实现，**不再使用 Navigator.push 全屏**打开二级页面。广场详情、收藏详情、发帖、发帖成功后的新帖详情、通知页、通知/推送跳详情，均走内容区覆盖。
- 通知页在双端均为**侧边栏 tab**（不 push）。
- 从通知/消息进入帖子详情时，**保留左侧导航栏**，并支持定位到对应评论位置。

---

## 1. 主题体系

### 1.1 主题模式
客户端支持三种外观，用户在**设置页**切换，偏好持久化到用户目录（`~/acgo_pc/theme_pref`）：

| 模式 | 说明 |
|------|------|
| `light` 白天 | 默认，白底深字 |
| `dark` 黑夜 | 深底浅字 |
| `system` 跟随系统 | 自动跟随 Windows 明暗 |

**切换机制**：
- `lib/theme_controller.dart` 管理：`ThemeController` 继承 `ChangeNotifier`，持有 `AppThemeMode`，`setMode()` 切换并持久化
- 通过 `AnimatedBuilder` 监听，动态改 `MaterialApp` 的 `themeMode`（`ThemeMode.light/dark/system`）
- 颜色在 `app_theme.dart` 通过 `Brightness` 分流（`LightColors` / `DarkColors`）

### 1.2 色板（唯一颜色来源，定义在 `app_theme.dart`）

**二层背景层次**（核心原则）：
- **侧边栏** = 副区块，背景略深一层
- **内容页** = 主区块，背景为标准色

| 用途 | 白天 | 黑夜 | 语义 |
|------|------|------|------|
| `bg` 内容页背景 | `#FFFFFF` | `#23232A` | 主区块标准色 |
| `bgSoft` 侧边栏背景 | `#F5F7FA` | `#1E1E23` | 副区块标准色 |
| `bgHover` 悬停/输入框 | `#EBEEF3` | `#2C2C2E` | 悬停、卡片、输入框底 |
| `primarySoft` 选中浅蓝底 | `rgba(10,132,255,.10)` | `rgba(10,132,255,.22)` | 选中态 |
| `primary` 主题蓝 | `#0A84FF` | `#0A84FF` | 品牌色 |
| `text` 主文字 | `#111827` | `#F5F5F7` | 标题、强调 |
| `textBody` 正文 | `#374151` | `#E5E5EA` | 正文、表格 |
| `textSecondary` 次要文字 | `#4B5563` | `#D1D1D6` | 次要信息 |
| `textMuted` 弱文字 | `#6B7280` | `#98989D` | 描述、提示 |
| `textFaint` 最弱/占位 | `#9CA3AF` | `#636366` | placeholder、图标 |
| `border` 分隔线 | `#E5E7EB` | `#3A3A3C` | 备用 |

**语义色**（两种主题通用）：
- `success` `#34C759`、`warning` `#FF9500`、`danger` `#FF3B30`、`info` `#32ADE6`

> **取色方式**：业务代码通过 `app_theme.dart` 提供的函数按当前明暗取值，例如：
> ```dart
> final b = Theme.of(context).brightness;
> final c = textMutedColor(b);
> ```

---

## 2. 布局规范

### 2.1 左右分区（无边框）
- 左侧导航栏 + 右侧内容页，**两者之间无分割线、无边框**
- 导航栏宽默认 80px（`NavigationRail`），背景 `bgSoft`（副区块）
- 内容页背景 `bg`（标准色），`Expanded` 填充剩余宽度

```dart
Row(
  children: [
    NavigationRail(/* 背景 bgSoft，无边框 */),
    Expanded(child: IndexedStack(/* 内容页背景 bg */)),
  ],
)
```

### 2.2 内容页
- **没有头部标题区域**，也没有其下分割边框（去掉原来的 Divider）
- 内容页内各页面通过 `_PageScaffold` 提供页面内标题（20px/600/`text`）
- **页面标题规范（我的 / 通知 / 设置 三页统一）**：
  - 字号统一 **20px / w600**（`_PageScaffold` 与通知页内嵌标题行一致）
  - **左右边距统一 24px**（`_PageScaffold` 与通知页内嵌标题行均为此值）
  - 标题与下一行内容间距统一 **20px**（标题行 bottom padding 4 + 内容区自带顶部 padding 16）
  - **Windows**：标题距顶 **-25px**（相对原 5px 整体上移 30px，让标题行与下方内容整体贴顶、去掉顶部冗余留白）
  - **macOS**：标题距顶 20px 保持不动

### 2.3 侧边导航
- 自绘 `_MacRailItem`（图标 + 文字，左对齐，Finder 风格），顶部 Logo，中间为功能项，底部为通知 + 设置
- **选中态**：图标与文字均 `primary` 蓝，文字**不加粗**（w400），指示器 `primarySoft` 浅蓝底
- **未选中态**：图标与文字均 `text`（白天黑 `#111827` / 夜晚白 `#F5F5F7`），与内容页主文字一致
- **角标**：`badge` 参数（红色 `kDanger` 胶囊，99+ 封顶，`Positioned` 于图标右上角）——「消息」显示**聊天未读总数**（监听 `ChatStore.chatUnreadTick`）；「通知」显示**通知中心未读数**（`NotificationCenter.instance.unread`，`kPrimary` 铃铛高亮）
- **图标整体下移 1px**：导航项图标（含角标）用 `Transform.translate(Offset(0,1))` 视觉下移 1px（不参与布局，旁边文字位置不受影响）
- 背景：实心 `bgSoft` 不透明（玻璃/半透明方案已于 2026-08-17 永久放弃，勿再引入 Acrylic/Mica）

---

## 3. 字体规范

| 用途 | 字体族 | 说明 |
|------|--------|------|
| 默认字体 | `Segoe UI Variable` | Windows 11 系统字体，自带完整字重 |
| 中文回退 | `Segoe UI` / `Microsoft YaHei` / `Microsoft YaHei UI` | 中文自动回退微软雅黑 |
| 字号标题 | 20px / w600 | 页面标题 |
| 字号正文 | 14px | 正文、列表 |

**配置位置**：`app_theme.dart` 的 `ThemeData.fontFamily` + `fontFamilyFallback`。

> **禁止**使用自定义单字重字体配合 `fontWeight`（会伪造加粗导致发虚），应采用系统自带完整字重的字体族。

---

## 4. 统一圆角曲率（iOS 风格，全局双端一致）

所有圆角从以下常量取值，**修改曲率只需改 `app_theme.dart` 一处，全局生效**。禁止硬编码圆角数值。

| 常量 | 值 | 用途 |
|------|-----|------|
| `kRadiusFull` | 999 | 胶囊角标、未读角标、状态徽标 |
| `kRadiusCard` | 18 | 大卡片、弹窗、评论框、发帖/暂存按钮、封面图顶部圆角 |
| `kRadiusMd` | 12 | 输入框、列表项、设置卡、缩略图、返回按钮、弹窗容器 |
| `kRadiusBtn` | 10 | 按钮、通知弹窗、菜单、用户信息卡 |
| `kRadiusSm` | 6 | 小标签、验证码、emoji 网格、骨架屏、状态色条 |

便捷构造：`kRadiusCardAll` / `kRadiusMdAll` / `kRadiusBtnAll` / `kRadiusSmAll`（返回 `BorderRadius`）。

**映射规则**（历史硬编码值 → 统一常量）：`8→12`（更圆润）、`20→18`、`15→10`、`5/4/2→6`、`999` 保持胶囊。

**图片圆角平滑**：帖子卡片封面图用 `ClipRRect` 独立裁剪顶部圆角（`kRadiusCard`），不依赖外层容器整体 clip，确保圆角平滑无锯齿。双端共享组件 `_CoverImage`。

## 4.1 卡片规范

- 卡片：`elevation: 0`（无阴影）、圆角 `kRadiusCard`(18px)、背景 `bgHover`
- 列表项 `ListTile`：图标头像用 `primarySoft` 底 + `primary` 图标
- 分隔线用 `Divider(height:1)`，颜色由主题自动适配

---

## 5. 组件规范

### 5.1 单选（RadioListTile）
- `activeColor: kPrimary`
- 主题：白天/黑夜/跟随系统
- 选项内文字用 `text`，副标题用 `textMuted`

### 5.2 按钮
- `FilledButton`：主题蓝背景 + 白色文字
- 语义按钮：`FilledButton.tonal` / `OutlinedButton`

### 5.3 图标
- 统一 **Material Icons**（`Icons.*`）
- 尺寸：导航 24px，列表 24px，页面图标 72px
- 图标颜色：普通 `textMuted`，选中/强调 `kPrimary`

### 5.4 提示框（统一封装，禁止重复造轮子）

所有反馈类 UI 统一走 `lib/notify.dart` 中的三类封装，**禁止在业务代码里自行 `showDialog` / `showSnackBar` / `ScaffoldMessenger` 造轮子**。

| 类型 | 封装入口 | 形态 | 适用场景 |
|------|----------|------|----------|
| 常规提示框 | `NotifyStack.info` / `success` / `warning` | 底部中央卡片，3 秒自动消失 | 轻量反馈：成功、失败、校验提醒 |
| 常驻提示框 | `NotifyStack.update` / `NotifyStack.notify(persistent: true)` | 底部中央卡片，常驻不消失，可点击/关闭 | 需用户关注或操作的重要提醒（如版本更新） |
| 对话提示框 | `AppDialog.confirm` | 模态 `AlertDialog`，返回确认/取消 | 需用户明确决策的操作（退出、删除、忽略等） |

#### 选择原则
- 只是"告知结果"（成功/失败/提示）→ 用**常规提示框**。
- "重要、需要用户处理、不应自动消失" → 用**常驻提示框**。
- "需要用户在【是/否】之间做决定、会改变状态" → 用**对话提示框**；必要时先弹常驻通知，点关闭再走 `AppDialog.confirm` 二次确认（见更新通知用法）。

#### 常规提示框
```dart
NotifyStack.success('发布成功', title: '耶熊');
NotifyStack.warning('说点什么吧', title: '提示');
NotifyStack.info('已是最新版本');
```
默认类型色：`success` 绿、`warning` 黄、`info` 随主题（白底/黑底）。

#### 常驻提示框
```dart
NotifyStack.update(
  '发现新版本 1.2.0',
  title: '发现新版本',
  onDownload: () { /* 跳转下载 */ },
  onIgnore: () { /* 忽略该版本 */ },
);
```
- `persistent: true` 不自动消失；点击卡片触发 `onTap`，点右上角 X 触发 `onDismiss`。
- 需二次确认时设 `confirmOnDismiss: true` + `dismissConfirmTitle/Message/Text`，点 X 会先弹 `AppDialog.confirm`。

#### 对话提示框
```dart
final ok = await AppDialog.confirm(
  context,
  title: '忽略更新',
  message: '是否忽略当前版本？',
  confirmText: '忽略',
  danger: true, // 危险操作确认键用红色
);
if (ok == true) { /* 确认后的逻辑 */ }
```

#### 规范要点
- **颜色**：三种提示框内部颜色均取自 `app_theme.dart`（`kSuccess`/`kWarning`/`kDanger`/`kPrimary`、`textColor`/`textMutedColor` 等），业务调用时**不传颜色**，除非特殊场景（如检查更新完成的绿色）。
- **层级与透传**：通知挂在 `MaterialApp.builder` 之上，全局覆盖所有路由（主页/发布页/登录页）。用 `Stack(alignment: Alignment.bottomCenter)` 把通知对齐到底部、**只占卡片区域**（不用 `Positioned.fill` 全屏覆盖层），其余区域自然透传，**不得**让通知层拦截底层页面的点击/输入。
- **统一入口**：`NotifyStack`（通知）与 `AppDialog`（对话框）都定义在 `lib/notify.dart`，新增页面直接 `import 'notify.dart'`，不要另起封装。

---

## 6. 窗口 / 托盘 / 单实例规范

- **窗口**：`window_manager` 管理，`TitleBarStyle.hidden` 隐藏系统标题栏，Flutter 自绘顶栏承担拖拽 + 窗口按钮
- **安全最小尺寸**：全程序统一 `Size(900, 640)`（`WindowOptions.minimumSize` + `setMinimumSize` 双重保障）
- **托盘驻留**：`tray_manager` + 托盘图标。点关闭按钮 → `_WindowCloseListener.onWindowClose` 拦截为 `windowManager.hide()`（隐藏到托盘而非退出）；托盘左键显示窗口、右键弹菜单（显示主窗口 / 退出）
- **单实例**：`AppService` 双层检测 —— 进程检测（Windows 用 PowerShell `Get-Process`，macOS/Linux 用 `pgrep -x`）+ 文件锁兜底（`AppConfig.dataDir/single_instance.lock`）。重复启动则请求唤起已有实例窗口并退出

**托盘图标**：Windows 用 `.ico`（`assets/images/app_icon.ico`），macOS 用 `.png` 模板图（`assets/images/app_logo.png`），由 `AppService._extractTrayIcon` 按 `Platform.isMacOS` 分支选择。`setIcon` 需要文件路径（asset 需 `rootBundle.load` 后写入临时目录再传 `File`）。

> **跨平台说明**：项目已做 macOS/Linux 基本兼容（单实例、托盘图标、更新安装方式按平台分支）。当前仅含 `windows/` 平台目录，在 Mac 上需先 `flutter create --platforms=macos .` 生成，并给 entitlements 加 `com.apple.security.network.client`。

---

## 7. 文件结构

| 文件 | 职责 |
|------|------|
| `lib/main.dart` | 应用入口、布局框架、页面视图、登录/主界面切换 |
| `lib/app_theme.dart` | 颜色色板 + 亮/暗 ThemeData 构建（唯一颜色来源） |
| `lib/theme_controller.dart` | 主题偏好（白天/黑夜/跟随系统）+ 持久化 |
| `lib/login_page.dart` | 登录窗口（对接 `app/api` 用户登录接口） |
| `lib/app_service.dart` | 单实例锁 + 系统托盘 + 关闭驻留后台 |
| `lib/sticker_panel.dart` | 表情面板（`EmojiPanel` 供帖子评论/发布页；`StickerPanel` 含表情包供聊天） |
| `lib/utils/time_format.dart` | 时间/日期格式化（相对时间 + 归属地占位） |
| `lib/utils/net_image.dart` | 通用网络图片组件 `NetImage`（统一加载中/加载失败占位，头像除外） |

---

## 8. 滚动规范（silky_scroll）

全局使用 **silky_scroll** 实现鼠标/触控板/触摸的平滑 + 惯性滚动（替代 Flutter 默认"逐格跳动"）。

**统一参数**（所有滚动区域一致）：
```dart
scrollSpeed: 1.6,                        // 滚动手速倍数
silkyScrollDuration: Duration(milliseconds: 600), // 惯性时长（短→更快停下）
animationCurve: Curves.easeOutCubic,     // 减速曲线
```

**使用方式**：用 silky 预设组件替换对应 Flutter 滚动组件：

| Flutter 组件 | silky 替代 |
|--------------|-----------|
| `SingleChildScrollView` | `SilkySingleChildScrollView` |
| `ListView` | `SilkyListView` |
| `ListView.separated` | `SilkyListView.separated` |
| `GridView.builder` | `SilkyGridView.builder` |

**已覆盖的滚动区域**：首页广场瀑布流（主体/骨架屏）、个人中心、设置页、登录页、注册页、详情页评论列表、发布页图片横滑、表情面板（emoji 列表 + 表情包 grid）。

**规则**：
- **所有可滚动容器必须用 silky 组件包裹**（用户主动滚动的内容），保持手感统一
- 横向小列表（图片缩略图、表情预览条）同样包裹
- 嵌套在列表内的 `GridView.count`（`NeverScrollableScrollPhysics`）无需包裹
- 图片轮播 `PageView`（自动播放）不包裹

> **手感调节**：过快调小 `scrollSpeed`，惯性大可调小 `silkyScrollDuration`，跟手可设更小（如 300ms）。参数统一一处改多处生效前，先在各组件逐处调整并确认。

---

## 9. 图片加载规范

除头像外，所有网络图片统一使用 `lib/utils/net_image.dart` 的 **`NetImage`** 组件，保证"加载中"和"加载不出来"有统一的默认状态，不出现空白：

- **加载中**：底色占位 + 转圈（默认 18px，`strokeWidth: 2`，主题主色）
- **加载失败**：底色占位 + `broken_image` 图标（默认 24px，主题弱化色）
- 组件内部统一 `AppConfig.resolveUrl`，外部直接传原始路径

**适用范围**：首页封面图、详情页轮播图、评论图片、全屏图片预览、表情面板与内联表情图。

**头像不使用 `NetImage`**：头像有专属的圆形首字兜底（`_UserAvatar` / `_AvatarBox` / `_NotifyAvatar` / `_Avatar`），保持各自样式。

**可覆盖参数**：`fit` / `cacheWidth` / `bgColor` / `loadingSize` / `spinnerColor` / `errorIcon` / `errorIconSize` / `errorIconColor`（如深色大图预览用白字图标、表情小图用更小图标）。

---

## 9. 内容区细节规范（广场 / 详情页）

- **时间显示**：用 `formatRelativeTime`（`lib/utils/time_format.dart`），本地相对时间：
  - <1 分钟「刚刚」；<1 小时「X分钟前」；今天「X小时前」；昨天「昨天 HH:mm」
  - 前天起 <7 天「X天前」；同年 ≥7 天「M月d日」；跨年「YYYY-MM-DD」
  - 时间右侧拼接归属地：`formatTimeWithLocation`（IP 转省份未接入前显示「未知」）
- **楼中楼折叠**（小红书/抖音式）：每个顶层评论的楼中楼**默认只显示 1 条**；超出部分显示「展开 5 条回复 ▾」，点击每次 +5 条（剩余 ≤5 条时显示「展开全部 N 条回复 ▾」），全部展开后按钮消失。实现：`_PostDetailPageState._childShowCount`（评论 id → 已展示条数）+ `_CommentItem.childShowCount/onExpandMore`
- **聊天气泡评论**（抖音/小红书式，`_ChatBubble`）：帖子详情页的主贴、顶层评论、楼中楼统一为**聊天气泡**布局——
  - **头像位置**：本人（`isMine`）头像在**右侧**，他人头像在**左侧**；头像在右时爱心被挤压到气泡左侧
  - **气泡**：本人 = **蓝色底（`kPrimary`）+ 白色文字**；他人 = `bgSoftColor` 底 + 主题文字色；圆角矩形 + 小三角，小三角**对准头像**（头像左→三角朝左，头像右→三角朝右）
  - **气泡内容**：昵称 + 内容 + 图片 + 时间/定位 + **点赞按钮（与时间/定位同一行，包裹在气泡内）**
  - **删除/举报**：**无删除按钮、无省略号**——统一通过**右键气泡**弹出菜单（本人=删除，他人=举报；`BubbleMenu(triggerOnRightClick: true)`）
  - **系统右键菜单**：气泡内容用 `SelectableText`（可拖动选择复制），但其**系统右键菜单已禁用**（`contextMenuBuilder` 返回空）——复制功能**合并进气泡菜单**（菜单首项「复制」），避免右键时系统复制菜单与气泡菜单**双弹窗**；文本仍可拖动选中后 Ctrl+C
  - **回复**：**点击气泡区域**发起评论/回复（无独立「回复」按钮）；评论点赞 `_CommentLikeButton` 在气泡内时间/定位右侧，本人（蓝底）爱心为白色
  - **折叠图片区**：`_buildBody` 用 `LayoutBuilder`+`Stack`+`AnimatedPositioned`，左侧图片轮播可收起/展开（折叠按钮位于分割线，动画 300ms，箭头 `AnimatedRotation` 0/0.5 圈）。右侧内容最大宽度 `maxPanelW=720` 居中，滚动条贴最右。
  - **图片区背景色**：白天模式用白天背景色（`bgColor`，白底），夜晚用暗色（`0xFF19191E`）；**放大的图片背景色不变**（保持深色 `0xFF000000` 遮罩）。
- **纯文本帖子假封面**（`_TextCover`）：确定性纯色背景（浅底深字，客户端本地生成）。**封面内始终显示**正文前 30 字 + 中文双引号 `"…"`（字号 18）；**卡片场景**封面内引文 + 封面下方正文区（≤2 行）**两者都显示**，与真图片卡片结构一致
- **评论点赞对齐**（抖音式）：爱心图标统一 **16px**，用固定宽度容器（44px）左对齐——**点赞数字宽度不影响爱心位置**，同层级所有爱心图标中心在完全同一垂直列对齐
- **点赞数格式化**：≥1000 用 `k`（如 `1k` / `1.2k` / `10k`），整数去小数、保留 1 位小数去末尾 0
- **帖子级点赞/收藏乐观更新**（`_togglePostLike`/`_togglePostFavorite`）：点击后**先本地立即渲染**（切换高亮态 + 计数 ±1），**不等接口返回**；接口成功后用返回的最新 `is_liked/is_favorited/like_count/favorite_count` 校准；**失败回滚**（还原点击前状态与计数）+ `NotifyStack.warning` 提示「点赞/收藏失败，请稍后重试」

> **新增页面/组件时**：颜色一律用 `app_theme.dart` 的函数/常量 → 文字用对应层级（text/textBody/textMuted...）→ 卡片 `elevation:0` + 8px 圆角 → 图标用 Material Icons → 主题用 `Theme.of(context).brightness` 分流 → **禁硬编码颜色** → 可滚动区域用 silky_scroll → 时间用 `formatRelativeTime`。

---

## 10. 个人中心规范

- **右上角省略号**（`Icons.more_horiz`，`BubbleMenu` 气泡菜单）：点击弹出更多操作气泡 —— 「隐私设置」「更改密码」「退出账户」三项，**隐私设置在最上方**。均从此菜单进入，**页面主体不再单独放账户安全卡**
- **隐私设置页**（`pages/privacy_settings_page.dart`，由省略号菜单「隐私设置」进入）：以 **内容区覆盖模式**打开（通过 `_HomePageState._macOverlay`，`embedded: true`），**保留左侧导航栏、不遮挡整个窗口**。内嵌标题栏与发布页/详情页一致（高 48、标题 15px/w600、macOS 风格返回按钮），顶部距离由宿主 `_TitleBar` 承担；内容区可滚动用 `SilkyListView`。**全屏模式**（`embedded: false`）遵守双端顶距规范（Win 顶距 5px / macOS 20px、标题 20px/w600、左右 24px）。
  - **主页可见性**：一张卡片（`bgHoverColor` + `kRadiusMd` 圆角）内含两项开关（动态/收藏），每项为自绘行：标题（14px/w600）+ 副标题（12px `textMutedColor`）+ 右侧 Material `Switch`（`activeThumbColor: kPrimary`，保存中禁用）。**开关即改即存**（调 `user/privacy`），失败回滚并提示。对应后端 `privacy_posts`/`privacy_favorites`（1公开 0仅自己），为访问他人主页功能提供可见性依据。

## 10.2 消息页（好友列表 + 聊天）

- **入口**：左侧导航「广场」上方「消息」项（图标 `Icons.mode_comment_rounded` 圆润聊天气泡），页面内嵌于左侧导航栏（不 push、无返回按钮）。**导航项右上角红色数字角标 = 所有会话未读总数**（`ChatStore.totalUnread()` 汇总，99+ 封顶；收到新消息 / 打开会话清零 / 跨端已读同步 / 删除会话时实时刷新，切换账号后显示新账号未读）。
- **背景与顶栏**：**顶栏**背景 = `bgSoftColor`（与左侧导航栏一致，`_TitleBar` 传 `color: bgSoftColor(b)`）；**好友列表**（左 260px）背景 = `bgSoftColor`（比聊天区**深**）；**聊天内容页**（右）背景 = **主背景 `bgColor`**（标题栏/输入区同用主背景色）；**macOS 无顶栏**（消息页顶到窗口顶）。
- **布局**：左右分栏——左侧好友列表（宽 260px，**无分割线**）；右侧聊天区。
- **好友列表**：标题「好友」（16px/w600）；好友项 = 头像（40px 圆形）+ 昵称（14px/w500）；选中项 `primarySoftColor` 底；空态「还没有好友 / 互相关注后即可成为好友」+ `Icons.chat_bubble_rounded` 圆润气泡图标；分页加载（page_size=50，触底加载更多）。**好友 = 互相关注**（`/api/user/friends`）。
- **左侧列表双视图**：顶部胶囊切换「会话 / 好友」。
  - **会话**（默认）：本地 `local_conversation` 驱动，按最近消息时间倒序；每项 = 头像 40px + 昵称（14px/w500）+ 最后消息摘要（12px `textMutedColor` 单行截断）+ 时间（今天 HH:mm / 昨天 / MM-DD）+ **未读红点角标**（`kDanger` 胶囊，99+ 封顶）；打开会话清零未读。
  - **好友**：原好友列表，点击进入会话（会话项自动出现）。
- **聊天区**（第二期已实现）：未选中好友时右侧为 `Icons.chat_bubble_rounded` 64px 圆润气泡占位（颜色 `textFaintColor`——白天很浅/晚上很深，**无文字**）；选中好友后：
  - 聊天对象标题栏（头像 32px + 昵称 15px/w600，无分割线；对方未开启聊天时右侧提示"对方暂未开启聊天"）
  - 消息区：气泡列表（自己 `kPrimary` 蓝底白字靠右、对方 `bgHoverColor` 底靠左带 32px 头像）；时间 + 发送状态（发送中 `schedule` 图标、失败 `error_outline` 红色）；空态"和好友打个招呼吧"
  - **输入区（微信/QQ 式）**：
    - **输入框行**：多行 TextField 占满整行（左侧无按钮留白），视觉高度 **4 行**（固定高度，实际满 4 行后**内部滚动**）；右侧留白 40px 避免被右上角按钮遮挡；**Enter 发送、Ctrl/Cmd+Enter 换行**（中文输入法候选确认时 Enter 交给输入法）
    - **背景**：输入框背景 = **左侧导航栏背景色**（`bgSoftColor`）；好友/会话列表背景 = **原输入框背景色**（`bgHoverColor`），两层视觉互换（列表更亮、输入框更沉）
  - **在线状态（QQ 逻辑）**：在线/离线圆点**叠加在头像右下角**、覆盖头像一部分（`_avatarWithStatus`：Stack + Positioned，绿 `kSuccess`=在线 / 灰 `textFaintColor`=离线，圆点带 1.5px `bgColor` 描边"切"进头像）——应用于**聊天标题栏头像**（32px，原昵称旁独立圆点移除）、**会话列表项**（40px，online 从好友列表实时取）、**好友列表项**（40px）
    - **右上角**（叠加在输入框顶层 `Stack`，`_InputResizeButton`）：**默认显示贴合右上角弧边的弧线符号**（`_CornerArcPainter` 两条短边 + 90° 圆弧，弧度与输入框圆角视觉一致，半透明弱化不抢焦点）；**鼠标悬停切换成放大/缩小图标**（`open_in_full` ↔ `close_fullscreen`，主色高亮），点击切换输入框高度 4 行 ↔ 10 行
    - **输入框下侧工具栏行**：**左侧**表情按钮（`Icons.emoji_emotions_outlined`，面板打开时高亮 `kPrimary`，点击向上弹 BubbleMenu 表情气泡）+ 图片按钮（`Icons.image_rounded`）；**右侧**发送按钮（`kPrimary` 圆角胶囊，纸飞机图标 + "发送" 文字）
    - **表情气泡交互**：点 **emoji** 插入字符或点**表情包**发送后，气泡**自动收起**（微信式，下次点表情按钮再弹出）；面板顶栏 tab 为**表情图标**（`emoji_emotions_outlined`）+ **爱心图标**（`favorite_outline`），选中主色高亮
    - 引用条显示在输入框上方（同前）
  - **表情消息**：点表情按钮 → **`BubbleMenu` 气泡弹出 `StickerPanel`**（宽度 360、高度 236，向上弹出，箭头对齐按钮），emoji 列表 + 表情包 grid 均为 silky 滚动：
    - 点 emoji → 光标处插入 Unicode 字符（随文本一起发送）
    - 点表情包 → **直接发送表情消息**（`msg_type=3`，按原图宽高比缩放、最长边 120px；**无气泡包裹/圆角**，透明底直接透出表情图片，gif 支持动效）
    - **表情消息不可点击放大**（去掉了全屏预览）；右键菜单含「添加到表情」——收藏该表情到自己的表情包（走 `/api/sticker/add` 软引用，图片文件不复制）；**自己发的表情消息（自己的表情包）不显示「添加到表情」**
    - 会话摘要显示「[表情]」
  - **表情面板**（`StickerPanel`）：emoji 网格间距紧凑（`mainAxisSpacing/crossAxisSpacing: 0`）；**表情包网格间距加大**（`mainAxisSpacing/crossAxisSpacing: 8`，微信式呼吸感）；**云端表情包图片 404/文件已删 → 自动删除数据库记录**（仅自己上传的能删）**或本地屏蔽**（非本人上传的失效表情从列表过滤 + 本会话黑名单，重启后重新检测）
  - **账号隔离**：表情包列表仅显示**当前账号自己**的（上传的 + 收藏的）——后端 `sticker/list` 按 uid 过滤 + 缓存按 uid 维度；切换账号后表情包列表随账号切换，不会串号显示别人的表情
  - **拉黑后不可见（前后端）**：被拉黑者访问拉黑者主页 → 顶部按钮变「已被拉黑」禁用、动态/收藏 tab 显示"你们之间存在拉黑关系，无法查看 TA 的内容"占位（后端 `blocked=1`）；广场与帖子详情由后端过滤（拉黑双方的帖子互不可见）；无法关注、无法聊天
  - **前端缓存账号隔离**：聊天本地 SQLite（`acgo_chat_<uid>.db`）、**聊天图片缓存**（`chat_images/<uid>/`）、**发帖草稿**（`draft/<uid>/`）均按账号隔离——切换账号后各账号数据完全独立，互不可见/不覆盖；老版本无 uid 子目录的旧文件仍可读（历史路径存绝对路径），新缓存进账号目录
  - **引用（回复）**：气泡右键菜单新增「回复」；点击后输入区上方出现引用条（`format_quote` 图标 + 「回复 昵称」w600 主色 + 单行预览，右侧 X 取消）；发送时消息体打包 `{"text","reply_to":{id,nickname,msg_type,preview}}`（E2EE 密文内自包含，对端直接渲染）；气泡内引用块 = 左侧 3px 强调竖条 + 昵称（`kPrimary`）+ 单行预览（超出省略），点击引用块定位跳转到被引用消息（`Scrollable.ensureVisible`，不在当前加载范围时提示）；被引用内容为图片/表情/撤回时预览分别显示 `[图片]`/`[表情]`/「该消息已撤回」
  - **多选删除**：气泡右键菜单新增「多选」；进入多选模式后：
    - 每条消息左侧显示圆形复选框（选中 = `kPrimary` 填充 + 白勾，150ms 动画）
    - 点击气泡勾选/取消（图片/表情点击不弹预览，发送失败重发点击不触发）
    - 输入区被多选工具栏替换：「已选 N 项」+ 全选/取消全选 + 删除（危险红，未选中禁用）+ 取消
    - 删除走 `AppDialog.confirm` 确认（danger 红键）→ **仅本设备删除**（服务器消息不受影响，其他设备仍可见）；删除后拉历史/断线同步按 msg_id 过滤已删消息，不会"复活"；被引用的消息若被删则自动取消引用
  - **离线消息通知**：收到对方新消息且**当前没在查看该会话**（消息页切走 / 看着其他会话 / 窗口遮挡或托盘）时，弹**应用内通知**（NotifyStack：昵称 + 内容摘要）+ **Windows 系统通知**（Toast：标题昵称 + 正文摘要），**点击跳转到对应会话**（切消息 tab + 打开会话）。离线期间断线 sync 拉取的消息同样通知（统一在解密入库时触发）；同一消息去重（只通知一次）；自己其他设备发出的消息不通知；会话昵称取本地会话缓存（找不到用「新消息」兜底）；图片/表情/引用消息摘要为 `[图片]`/`[表情]`/实际文本
  - **已读状态跨端同步**：在本设备读消息 → 服务器除推 `chat_read` 给发送方外，还推 `chat_read_sync` 给自己其他在线设备 → 其他设备**清零该会话未读角标**（多端已读一致，A 端读了 B 端不再显示红点）
  - **气泡连续（微信风格）**：同一发送者、相邻消息均**纯文本**（msg_type=1、未撤回、无引用块）、时间差 <5 分钟且同一天 → **合并成连续气泡**：组内成员之间不显示头像（**头像只在组头（最旧）那条显示**，自己消息右侧、对方消息左侧）、气泡圆角朝组内一侧变小贴合、垂直间距收紧到 1px；发送状态（已读/未读/失败）只在组尾显示
  - **头像磁盘缓存**：新增 `widgets/cached_avatar.dart`（`CachedAvatar`）——头像缓存到 `<dataDir>/avatar_cache/<url哈希>`，**好友不换头像时不重复网络加载**（磁盘命中 → `Image.file`，内存 ImageCache 二次加速）；换头像（url 变）→ 哈希变 → 自动重新下载；缓存超 7 天自动清理；`message_page`（`_avatarWithStatus`/`_peerAvatar`/`_myAvatar`）、`main.dart`（`_UserAvatar`）、`post_detail_page`（`_AvatarBox`）均已接入
- **图片磁盘缓存**：`NetImage` 升级支持磁盘缓存（`services/image_cache.dart`）——帖子/评论图片首次加载后缓存到 `<dataDir>/image_cache/<uid>/`（**按用户隔离**），再次打开直接命中不再网络加载；**所有缓存一律用户隔离**（头像、聊天图片、帖子图片均按账号分目录），7 天自动清理；设置页「清除缓存」一键清理（含占用大小显示）
- **聊天搜索框**：背景用**主背景色 `bgColor`**（非蓝色），图标/文字/光标/清除按钮跟随主题（会话+好友搜索统一）
- **好友备注**：弹出层昵称旁**编辑按钮**（`edit_outlined`）→ 输入框设置备注（≤50 字，可空清除）；**好友列表与会话列表优先显示备注名**（微信风格）；后端存于「我关注对方」的关系上，仅自己可见
- **动态卡片动态高度（小红书样式）**：封面高度**按图片真实宽高比动态计算**（客户端读图自身尺寸，不依赖后端字段）：首次渲染用确定性伪随机占位高度 [200,320] 制造错落（`_coverHeightFor`），图片解码完成后 `_CoverImage` 用 `NetImage.onLoaded` 回调的真实宽高重算 `宽×高/宽`（**图片本身最多 9:16**——高 > 宽×16/9 封顶裁剪、9:16 竖图/方图/横图按真实比例显示，**最小高度 180** 防细条）；`_CoverImage` 用 `BoxFit.cover` 铺满裁剪（顶部圆角独立裁剪）；**无图帖子卡片结构与真图片卡片一致**：封面内显示内容引文 + 封面下方正文 ≤2 行 + 底部头像昵称+赞数
- **图片上传客户端统一转码 JPEG**（`utils/image_transcoder.dart` `ImageTranscoder.toJpeg`）：**头像/帖子/评论/聊天**图片选择后**客户端解码重编码为 JPEG**（`image` 包，质量 88），支持 webp/png/bmp/jpg 等任意格式；**GIF 动图保留原样**（转 jpg 会丢动画）；**头像禁止 GIF**（选图时 `isGif` 拦截提示「头像暂不支持GIF动图」，未来可作会员特权）；上传文件名统一 `.jpg`；**表情包不走此转码**（`StickerCompressor` 保留 PNG/GIF 动图与透明）
- **聊天输入框粘贴图片**（message_page）：**Ctrl/Cmd+V** 检测剪贴板图片（`ImageTranscoder.readClipboardImage` 用 **win32 直读系统剪贴板 CF_DIBV5/CF_DIB**，构造 BMP 交给 image 包解码，浏览器/截图工具复制的图片系统统一转成 DIB）→ 转 jpg → 直接发送图片消息（GIF 保留动画）；无图片时回落到文本粘贴；右键菜单「粘贴」同逻辑
- **剪贴板读取方案（跨平台）**：**Windows** 用 `dart:ffi` 直连 user32/kernel32（函数内 try/catch 懒加载，`OpenClipboard`/`IsClipboardFormatAvailable(CF_DIBV5=17 优先, 回退 CF_DIB=8)`/`GetClipboardData`/`GlobalLock`+`GlobalSize` 读 DIB 字节，拼 14 字节 BMP 文件头成完整 BMP 给 image 包解码）；**macOS** 走原生 MethodChannel「com.acgo/photopicker」新增 `readImage` 方法（`PhotoPickerPlugin.swift` `NSPasteboard` 读 PNG 优先回退 TIFF，NSImage 统一转 PNG 返回 `FlutterStandardTypedData`）；其他平台返回 null。**不用 super_clipboard**（底层 super_native_extensions 需 Rust/cargokit 编译，无 cargo 构建必失败）；**不 import `win32` 包**（其顶层 `DynamicLibrary.open('user32.dll')` 在 macOS 上 import 即崩）
  - **图片另存为**：图片消息（msg_type=2）**放大预览底部工具栏有「另存为」**（半透明黑底胶囊按钮，**弹系统保存对话框由用户选择保存位置/文件名**，`FilePicker.saveFile`；优先拷贝本地缓存文件，无缓存走网络）；气泡右键菜单也有「另存为」（`save_alt_rounded`，同逻辑）；**表情消息不支持另存为**；用户取消保存不提示
  - **图片大图预览增强**（`_previewImage`）：**左上角显示序号**（当前/共 N 张）；**左右切换**当前聊天记录里所有图片消息（`_messages` 过滤 msg_type==2，`StatefulBuilder` 维护索引，首/尾点击提示「没有图片了」）；**底部工具栏**：「另存为」+「定位到聊天记录」（关闭预览后 `_jumpToMessage(msg_id)` 滚动到该消息，`msg_id` 无效时禁用）
  - **标题栏右上角省略号 → 右侧弹出层**（`_showChatMenu`，从右滑入、右对齐、左侧圆角、宽 300，微信风格）：顶部头像+昵称+在线+关闭，菜单项——「进入他的主页」（内容区覆盖打开）、「清空对话记录」（`AppDialog.confirm` 交互提示，清本地+服务器缓存+WS 多端同步）、「查找聊天记录」（切回会话视图聚焦搜索框）、「取消好友」（confirm 提示 → 后端 `removeFriend` 解除双方关注 → 本地移除好友+隐藏会话）、「拉黑名单」（confirm 提示拉黑后果 → 后端 `block` 自动解除双方关注 → 本地移除好友+隐藏会话，`kDanger` 红字）
  - **E2EE**：消息全程加密（RSA-OAEP + AES-GCM），本地 SQLite 存明文供离线浏览；聊天密钥首次进入自动生成并上传公钥；引用/表情元数据同样在密文内传递

## 10.3 他人个人中心页

- **入口**（`main.dart` 内 `UserProfilePage`，内容区覆盖打开，`embedded: true`，保留左侧导航栏）：帖子详情页**点击他人头像/昵称**、评论里**@昵称（含楼中楼）**进入。由 `_HomePageState.openUserProfile(uid, nickname, avatar)` 实现。
- **标题栏**：与帖子详情页等**二级页面一致**（embedded：高 48、水平 8px、macOS 风格返回按钮 40x40/`kRadiusMd` 圆角/`arrow_back_ios_new_rounded` 16px、标题 15px/w600）；**标题 = 「昵称的主页」**；右上角省略号 `BubbleMenu` = 举报。
- **内容**：用户信息卡（头像 56px 圆形 + 昵称 18px/w600 + UID）+ **关注按钮**（信息卡右侧）：
  - 未关注：`kPrimary` 蓝底白字「关注」；已关注：**胶囊**（`kRadiusFull`）+ **左侧导航栏背景色 `bgSoftColor`**「已关注」；互相关注：胶囊 + `bgSoftColor`「互相关注」
  - 进入页面加载关注状态（`followStatus`），点击切换（`follow`），忙碌态转圈
  - + **动态/收藏双 tab**（胶囊切换，`primarySoft` 底选中 + `kPrimary` 字）。
  - 数据源：`GET /api/post/myPosts`、`/api/post/favorites` 带 `target_uid`。
  - **隐私占位**：对方将动态/收藏设为仅自己（`visible=0`）时，展示锁图标 +「对方将「动态/收藏」设为仅自己可见」。
  - 空态：动态「还没有发布任何动态」、收藏「还没有收藏任何帖子」。
  - 帖子卡片：内容摘要（最多 3 行）+ 图片横排（最多 3 张 72x72）+ 点赞/评论数 + 时间；点击卡片进帖子详情（全屏打开）。
- **聊天区点击约定**：主贴气泡昵称（气泡上方）、顶层评论昵称（气泡内）、楼中楼昵称（气泡上方）、头像、`@昵称` 均可点击进入对应主页（本人昵称/头像点击也打开自身主页）。
  - `@昵称` 点击跳**被@者**主页（`reply_to_uid`）；楼中楼回复者头像/昵称跳**回复者**主页。

## 10.1 气泡菜单（省略号弹层）规范

- 所有**弹出层**（省略号弹层 + **全局右键菜单** + **扩展面板**）统一用 `widgets/bubble_menu.dart` 的 `BubbleMenu`：帖子详情删除/举报（右键气泡）、个人中心更多操作（省略号）、我的动态/收藏/历史卡片右键、消息页会话/气泡右键、**聊天表情面板**（`content` 参数传入 `StickerPanel`，配 `width`/`panelHeight` 限制尺寸）。**不再用 `PopupMenuButton` / `showMenu` / `GestureDetector.onSecondaryTapDown` 自弹菜单**
- `BubbleMenu` 的 `content` 参数：非空时气泡内渲染自定义面板替代菜单项（`panelHeight` 定高），用于非菜单的扩展面板（表情等）；`onOpenChange` 回调可联动触发按钮高亮
- `BubbleMenuState` 公开 `close()`：点击面板内容（emoji/表情包）后由外部调用**自动收起气泡**（微信式）；触发按钮配 `GlobalKey<BubbleMenuState>` 绑定
- **帖子详情页 emoji 面板**：表情按钮同样走 `BubbleMenu` 气泡（`content: EmojiPanel(transparent: true)`，宽 340 高 209，仅 emoji 无表情包），点击 emoji 插入后自动收起；移除旧 inline `AnimatedSize` 面板
- **样式**：圆角矩形气泡（`kRadiusBtn`）+ **框外**小三角箭头（三角完全在矩形外、底边与矩形边缘相接，不侵入框内），带 1px 边框（白天浅灰 / 夜晚深灰，取 `bgHoverColor`）、**无阴影、无分割线**，主题明暗自适应（白天白底 / 夜晚深色底，取 `bgColor`）
- **文字不加粗**（`FontWeight.w400`）、**无下划线**（`decoration:none`）
- **菜单项反馈**：**仅鼠标悬停**时整行显示**蓝色胶囊**（`kPrimary` 圆角底），图标与文字变**白色**；其余状态用项自身颜色（默认白天黑 / 夜晚白 `textColor`；删除项 `kDanger`）
- **宽度**：`width` 参数不传时**按最长菜单项文字自动计算**（文字完整显示不截断，`TextPainter` 测量 + clamp 84~240）；传入数值则固定宽度（省略号菜单等场景）
- **合并系统菜单**：气泡内 `SelectableText`/`TextField` 的系统右键菜单（复制/粘贴）在全局右键统一后**一律禁用**（`contextMenuBuilder` 返回空），对应功能（如「复制」）合入 `BubbleMenu` 菜单项，避免右键**双弹窗**
- **输入框右键统一气泡**（`widgets/text_input_menu.dart` `TextInputBubbleMenu`）：**所有输入框**（搜索/昵称/密码/发帖/评论/聊天/备注/举报等 16 处）右键一律外包 `TextInputBubbleMenu`（`BubbleMenu(triggerOnRightClick:true)`），菜单含**剪切/复制/粘贴/全选**；密码框（`obscure:true`）隐藏剪切/复制（与系统一致）；聊天输入框传 `onPasteImage`——粘贴时优先读剪贴板图片（有图转 jpg 发送，无图落文本粘贴）；输入框自身 `contextMenuBuilder` 一律返回空禁用系统菜单
- **内容对齐**：**所有菜单项内容宽度一致 → 内容居中显示**；**宽窄不一 → 左对齐**（图标+文字整体对齐，微信/QQ 右键菜单风格）。判断用 `TextPainter` 测量每项（图标 15 + 间距 6 + 文字宽）是否全部相等
- **方向**：默认向下弹出；下方空间不足自动向上
- **三角对齐**：小三角水平中心对齐触发的图标/文本中心
- **单例**：全局同一时刻最多只显示一个气泡（`BubbleMenuManager`），打开新气泡自动关闭旧的
- **动画**：显示淡入 + 轻微缩放（`easeOutBack`），消失淡出，约 150ms
- **关闭**：点击气泡外、鼠标滚动、再次点击触发图标即关闭
- **菜单项**：`BubbleMenuItem`（文本 + 可选图标 + 颜色；删除项红色 `kDanger`，举报项默认文字色）
- **动态 / 收藏 / 历史 tab**：位于用户信息卡下方，胶囊切换（`_ProfileTab`）：**动态在左、历史在右**（动态/收藏/历史从左到右）。选中项 `primarySoft` 浅蓝底 + `kPrimary` 蓝字（w600）+ 计数；未选中 `textSecondary` 字（w400）；圆角 `kRadiusBtn`，切换动画 150ms。`_switchTab` 切换，**首次进入各 tab 按需加载**（未加载过才拉取）。
- **我的动态**：只显示当前用户发布的帖子（个人中心「动态」tab），小红书/抖音风格双列瀑布流：
  - 数据源：`GET /api/post/myPosts`（分页，page_size=12，按发布时间倒序），触底自动加载更多
  - 布局/状态/交互：复用首页瀑布流组件 `_MasonryGrid`/`_PostCard`，列数按窗口宽度 2/3/4 列；加载中骨架屏（`_SkeletonGrid`）、失败重试（`_FavRetry`）、空态（`_EmptyFavorites`，图标 +「还没有发布任何动态」文案）
  - 点击卡片进帖子详情（内容区覆盖，保留左侧导航栏）；从详情返回后自动刷新动态列表
  - **刷新时机**：同收藏，按需拉取——首次进入加载，每次从其他 tab 切回个人中心自动刷新（发帖/删帖后回来是最新数据）
- **我的收藏**：位于「动态 / 收藏」tab 的收藏分页下，小红书/抖音风格双列瀑布流：
  - 数据源：`GET /api/post/favorites`（分页，page_size=12），触底自动加载更多
  - 布局：复用首页瀑布流组件 `_MasonryGrid`/`_PostCard`，列数按窗口宽度 2/3/4 列
  - 封面高度：`_favCoverHeight`（150px 基准 + id 微调），贴合小红书 3:4 视觉
  - 状态：加载中骨架屏（`_SkeletonGrid`）、失败重试（`_FavRetry`）、空态（`_EmptyFavorites`，图标 + 引导文案）
  - 交互：点击卡片进帖子详情；从详情返回后自动刷新收藏列表（可能已取消收藏）
  - **刷新时机**：按需拉取（非定时轮询/非 WS 推送）——首次进入个人中心加载；之后**每次从其他 tab 切回个人中心**（`active` 由 false→true）自动刷新，保证「广场里收藏/取消收藏」后切回来是最新数据。收藏列表是当前用户私有数据、低频变更、单设备在线，无需轮询/推送开销
- **关注/粉丝入口**（信息卡下方、熊爪数**左侧**）：`关注 +N`、`粉丝 +N` 两项（`_CountEntry`：数字 14px/w700 + 标签 13px `textMutedColor`，hover 圆角）。计数来自 `followCounts`（切回个人中心时刷新）。
- **关系列表二级页**（`pages/relation_list_page.dart`，Navigator.push 打开）：标题栏二级页面规范（高48/返回按钮/15px标题「我的关注」）；**三个 tab**：互相关注/关注/粉丝（胶囊切换 `primarySoft` 选中），**默认 tab 由入口决定**（点关注→关注，点粉丝→粉丝，好友入口→互相关注）。列表项 = 头像 40px + 昵称 14px/w500 + 「互相关注」小徽标 + 关注/已关注胶囊按钮（同他人主页三态样式）；点击用户打开他人主页（内容区覆盖）。
- **我的动态**（「动态」tab）：**鼠标右键**动态卡片弹出上下文菜单（`BubbleMenu`）→「删除动态」（`kDanger`）→ 确认框 → `deletePost` → 成功后从列表移除 + 提示「动态已删除」
- **浏览历史**（「历史」tab，个人中心最右侧）：**服务端跨设备同步**（`user.browse_history` JSON 字段，**最多 120 条**，按浏览时间倒序）：
  - 数据源：`GET /api/user/browseHistory`（全量一次拉取，无分页）；记录：打开帖子详情时 `POST post_id`（静默上报，去重置顶限 120）
  - 布局：复用瀑布流 `_MasonryGrid`/`_PostCard`，同动态/收藏列数与封面高度算法
  - **按访问日期分组**：「今天 / 昨天 / 更早」三组（自然日判定与 `formatRelativeTime` 一致），每组标题 13px/w600 `textMutedColor` + 瀑布流；**重复访问以最新访问时间为准**（服务端去重置顶）
  - 状态：加载中骨架屏（`_SkeletonGrid`）、失败重试（`_FavRetry`）、空态（`_EmptyFavorites`，图标 `history_rounded` +「还没有浏览历史」）
  - **清空按钮**：历史列表非空时右上角「清空历史」文字按钮（`kDanger`），点击弹确认框 → `POST clear=1` 服务端清空 → 本地列表清空
  - 交互：点击卡片进帖子详情（内容区覆盖）；从详情返回后自动刷新浏览历史（新的浏览置顶）；**鼠标右键卡片**弹上下文菜单（`BubbleMenu`，锚定卡片右键位置）：
    - 收藏卡片右键 →「取消收藏」（走 `togglePostFavorite`，成功后从列表移除 + 提示）
    - 历史卡片右键 →「删除该记录」（走 `deleteBrowseHistory`，服务端+本地移除 + 提示）
  - 右键菜单样式：`BubbleMenu`（见 10.1 气泡菜单规范；内容对齐自动判断）
  - **刷新时机**：切到「历史」tab 首次加载；从其他 tab 切回个人中心时若历史 tab 未加载过则加载；清空/详情返回后即时刷新
- **导航**：个人中心（`_currentIndex=1`）仍在左侧导航栏，页面标题「个人中心」
