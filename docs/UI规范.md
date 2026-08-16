# ACGO PC 客户端（Flutter Windows）UI 设计规范

> 整体风格为 **正式、极简、扁平** 的桌面应用设计语言：
> 白色/深色双主题、无边框分区、二层背景层次、系统主题蓝、克制动效。
> 所有颜色统一取自 `lib/app_theme.dart`，**禁止在业务代码中硬编码颜色**。
> 主题偏好统一由 `lib/theme_controller.dart` 管理。

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

### 2.3 侧边导航
- `NavigationRail`，顶部 Logo，中间为功能项，**底部固定设置图标**（无文字，`tooltip` 提示）
- 选中态：图标 `primary` 蓝，指示器 `primarySoft` 浅蓝底
- 未选中：图标 `textMuted`

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

## 4. 卡片规范

- 卡片：`elevation: 0`（无阴影）、8px 圆角、背景 `bgHover`
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
- **托盘驻留**：`tray_manager` + 托盘图标 `assets/images/app_icon.ico`（Windows 需 .ico）。点关闭按钮 → `_WindowCloseListener.onWindowClose` 拦截为 `windowManager.hide()`（隐藏到托盘而非退出）；托盘左键显示窗口、右键弹菜单（显示主窗口 / 退出）
- **单实例**：`AppService` 用 `File.create(exclusive: true)` 锁文件（`~/acgo_pc/single_instance.lock`）实现。重复启动则检测失败直接退出

**托盘图标**：Windows 用 `.ico`，`setIcon` 需要文件路径（asset 需 `rootBundle.load` 后写入临时目录再传 `File`）。

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
- **评论/楼中楼 hover 胶囊**（`_ReplyArea`）：评论内容区（顶层+楼中楼）鼠标悬停时次色调胶囊背景 180ms 平滑渐显/渐隐（仅 alpha 渐变、RGB 恒定不变暗）。**内容区本身不响应点击**——发起回复只能点「回复」文字按钮（`_ReplyTextButton`，hover 变蓝加粗），杜绝误触整区误发回复；评论点赞仍走独立的 `_CommentLikeButton`
- **纯文本帖子假封面**（`_TextCover`）：取正文前 30 字 + 中文双引号 `"…"`，溢出用 `...`，字号 18-20

> **新增页面/组件时**：颜色一律用 `app_theme.dart` 的函数/常量 → 文字用对应层级（text/textBody/textMuted...）→ 卡片 `elevation:0` + 8px 圆角 → 图标用 Material Icons → 主题用 `Theme.of(context).brightness` 分流 → **禁硬编码颜色** → 可滚动区域用 silky_scroll → 时间用 `formatRelativeTime`。
