# ACGO 移动端（Android / iOS）UI 开发规范

> 适用范围：`lib/mobile/` 下所有移动端页面、组件、主题适配。
> 设计依据：桌面 `docs/UI规范.md`（设计语言沿用）+ `docs/移动端适配方案.md`（2.2 目录决策、3.5 主框架、3.9.1 iOS 26）。
> 核心原则（2026-08-20）：**单代码库、功能层共享、UI 层按平台分目录**。桌面 `pages/ widgets/` 不做移动端改造，移动端前端一律进 `lib/mobile/`。

---

## 1. 设计语言

移动端延续桌面基调 **正式、极简、扁平**，并按移动端习惯调整：

1. **双主题**：浅色 / 深色，取色统一走 `app_theme.dart` 常量，不硬编码颜色。
2. **主色**：沿用 `kPrimary`（系统主题蓝），成功 `kSuccess` / 警告 `kWarning` / 危险 `kDanger` / 信息 `kInfo`，文案层级用 `textMutedColor(b)`。
3. **圆角**：统一使用 `kRadius*` 常量（Card 大圆角 / Md / Btn / Sm），禁止散落魔法数值。
4. **形态**：页面全屏、无 hover、无右键；以**触摸**（轻点 / 长按 / 双指 / 滑动）为主要交互。
5. **材质（2026-08-20 决策）**：**所有页面内容**均模仿 iOS 26 Liquid Glass 风格（Flutter 实现：一级浮层优先 `liquid_glass_widgets` shader 真玻璃、其余自绘兜底；不写原生壳；Android / iOS 统一不按系统分叉；2026-08-20 更新：**放开「不引三方库」约束**）。分级玻璃控制性能，细则见 **§1.1**。

### 1.1 全页面 iOS 26 风格细则（2026-08-20 决策）

> 权威规格：`docs/UI规范.md` 第 11 章（玻璃材质 / 元素规格 / 标签栏），本小节只列移动端执行要点。

- **适用范围**：`lib/mobile/` 全部页面——主框架、列表、详情、发布、个人中心、设置、弹层、输入框、按钮、卡片。
- **分级玻璃（性能第一）**：
  - 一级浮层（导航栏 / 底部标签栏 / 搜索栏 / 底部 sheet / 弹窗）= 真玻璃：优先 `liquid_glass_widgets` shader 玻璃；自绘兜底用 `BackdropFilter` 模糊 sigma 10~12 + 半透明底 + 高光描边；
  - 二级浮层（卡片 / 分组列表 / 输入框 / 按钮底）= 弱玻璃或半透明底（sigma 4~6 或仅半透明 + 细描边）；
  - **滚动列表项不套 `BackdropFilter`**（滚动中禁用真模糊），用半透明底模拟；每屏 `BackdropFilter` 实例 ≤ 3。
- **页面元素**：背景用系统感 `LinearGradient`（浅色白→极浅蓝灰 / 深色深灰蓝）；列表用 **Inset grouped** 内嵌分组卡片；按钮胶囊化（`kRadiusFull`），次操作玻璃底；分段控件整条胶囊、选中段玻璃浮起；底部弹层用半屏玻璃 sheet（顶部圆角 20 + 下滑关闭 + 指示条）。
- **iOS 原生观感（2026-08-20 决策，不嵌真 UIKit）**：底部标签栏用 `liquid_glass_widgets` 的 `GlassTabBar.bottom`（shader 真玻璃 + Liquid Morph 动画引擎，见 §4.3）；搜索框用 Flutter 官方 `CupertinoSearchTextField`（放大镜 / 圆角胶囊 / 一键清空 / 键盘联动）；按钮用 `CupertinoButton` 观感。**不**通过 platform view 嵌入原生 `UITabBar` / `UISearchBar`（评估见 `docs/UI规范.md` 第 11.6 节）。
- **不做**：景深折射、动态光照、触摸形变、真实 SF Symbols（避免四不像）。
- 取色 / 透明度一律基于 `app_theme.dart` 常量，禁硬编码。

---

## 2. 目录与引用边界

### 2.1 目录结构（目标形态）

```text
lib/
├─ app/                    # 共享：AcgoPcApp（MaterialApp）
├─ core/                   # 共享：app_config / api_client / app_theme / device_service
├─ services/               # 共享：theme_controller / ws_service / chat_* / notification_center / secure_storage …
├─ controllers/ utils/ models/
├─ widgets/                # 共享通用组件（白名单见 2.2）
├─ pages/                  # 桌面端页面（保留，移动端不引用）
└─ mobile/                 # ★ 移动端前端（新建）
   ├─ mobile_app.dart      # 移动端根组件（主题 / 路由，main.dart 按 AppConfig.isDesktop 分流进入）
   ├─ pages/               # splash / login / register / home / message / planet / profile / settings / post_detail / publish / notification …
   ├─ widgets/             # mobile_app_bar / long_press_menu / mobile_pick_images …（底部标签栏用插件 GlassTabBar.bottom，内联 home_page.dart）
   └─ theme/               # 移动端主题适配（系统字体、字号阶梯、组件默认样式）
```

### 2.2 import 边界（强制）

移动端文件**只允许 import**：

- ✅ `core/`、`services/`、`controllers/`、`utils/`、`models/`（共享功能层，可任意引用）
- ✅ `mobile/` 内自身文件（`mobile/widgets/`、`mobile/theme/`）
- ✅ `widgets/` **共享白名单**：`cached_avatar`、`user_avatar`、`emoji_data`、`notify`（`NotifyStack` / `AppDialog`，无平台依赖）
- ✅ 无平台依赖的三方包（`silky_scroll` 滚动、图片加载等）
- ❌ **禁止** `pages/` 及 `widgets/` 下桌面实现：`title_bar`、`secondary_title_bar`、`bubble_menu`、`pick_images`、`planet_globe`、`starfield`、`find_form_dialog`、`match_dialog`、`report_dialog`、`sticker_panel`、`text_input_menu`、`page_scaffold` 等

> 桌面 UI 依赖（window_manager / tray_manager / local_notifier / 自绘标题栏 / 右键菜单）会通过共享白名单之外的引用被自然排除，从而保证**桌面零回归、移动端产物干净**。

### 2.3 新增代码规则

- 新增**页面**：移动端 → `mobile/pages/`，桌面 → `pages/`，禁止互相引用。
- 新增**通用组件**：先判断平台依赖——无平台依赖（可被桌面复用）进 `widgets/`；仅移动端用（底部导航 / 长按菜单 / 移动端弹层）进 `mobile/widgets/`。
- **业务逻辑不双写**：同一逻辑只进 `services/ core/`，页面只做展示与交互。
- 新增组件若被移动端复用，需检查并移入共享层（`services/` 或 `widgets/` 白名单）。

---

## 3. 主题体系

### 3.1 主题模式

- 明暗切换沿用共享 `services/theme_controller.dart`（`ThemeController`），移动端不做第二套状态管理。
- `mobile/theme/` 只负责**移动端适配**：系统字体、字号阶梯、组件默认样式（`NavigationBar` / `AppBar` / `FilledButton` 等主题），颜色一律取自 `app_theme.dart`。

### 3.2 取色

- 颜色唯一来源：`core/app_theme.dart` 常量与 `textMutedColor(b)` 函数。
- 禁止在页面里硬编码颜色 / 圆角 / 阴影数值；透明度变化用 `withOpacity` 基于主题常量。

### 3.3 字体

- `fontFamily` 用系统默认（`null`），由 iOS（PingFang SC / SF）与 Android（Roboto / 小米兰亭）系统字体渲染，自动适配动态字号。
- **禁止**硬编码 `Segoe UI Variable` / 微软雅黑等桌面字体。
- 不引入自绘数字/图标字体（表情包 emoji 走 `emoji_data` 共享）。

---

## 4. 布局规范

### 4.1 安全区

- 所有页面根节点包 `SafeArea`（刘海 / 挖孔 / 底部手势条）。
- 底部标签栏悬浮容器同样受 `SafeArea` 约束，避开手势条区域。
- 键盘弹出时（`resizeToAvoidBottomInset` 默认 true）输入框不被遮挡，必要时用 `viewInsets` 计算。

### 4.2 页面骨架

| 类型 | 规范 |
|---|---|
| 主框架 | `mobile/pages/home_page.dart`：`GlassScaffold`（background 渐变）+ body 外层透明 `Material`（防黄下划线）+ 内容区 `PageView`（4 tab：消息 / 广场 / 探索 / 我的，左右滑动切换，`AutomaticKeepAliveClientMixin` 保状态）+ `GlassTabBar.bottom` 标签栏（§4.3，2026-08-20 已实现） |
| 二级页 | `Navigator.push`（`MaterialPageRoute`）全屏页；顶部用 `Scaffold.appBar`（Material 原生）或轻量页头 `mobile/widgets/mobile_app_bar.dart` |
| 列表页 | 单列为主；瀑布流按宽度自适应列数（见 4.4）；滚动统一 `silky_scroll` |
| 弹层 | `showModalBottomSheet` / `showDialog`（Material），禁止复用桌面自绘弹层 |

### 4.3 底部标签栏（`GlassTabBar.bottom` shader 玻璃 + 滑动切换动画）

- 权威规格见 `docs/UI规范.md` 第 11.4 节；实现内联于 **`mobile/pages/home_page.dart`**（`GlassScaffold.bottomBar` 注入 `GlassTabBar.bottom`），原 `mobile/widgets/mobile_bottom_nav.dart` 已删除。
- **玻璃（2026-08-20 恢复插件）**：底部标签栏 = `liquid_glass_widgets`（^0.30.1）`GlassTabBar.bottom` shader 真玻璃 + Liquid Morph 动画；页面背景 = `GlassScaffold.background` 渐变。**完全照插件官方示例 `example/example.dart` 写法，只把 tab 入口换成我们自己的**（消息 / 广场 / 探索 / 我的）。渲染质量 `quality: GlassQuality.premium`（高精管线，2026-08-20 反馈圆角锯齿后采用）。
- **黄色双下划线防护（关键）**：`GlassScaffold` 底层为 `CupertinoPageScaffold`（**无 Material 上下文**），body **和 bottomBar（`GlassTabBar`）**都必须包 `Material(type: MaterialType.transparency)` 提供 Material 祖先，否则 Text 渲染黄色双下划线伪影（2026-08-20 实测：只包 body 时 tab label 仍会有）——**当初「弃用」根因即此（Material 上下文缺失），非 shader 异常**。
- **角标**：暂不叠加（官方示例无角标；`GlassTab` 直接传 `Icon`，不做自绘）。
- **滑动切换（2026-08-20 定案）**：内容区 **`PageView`**（横向滑动 + `BouncingScrollPhysics` iOS 回弹，替代 `IndexedStack`）；各 tab 页 `AutomaticKeepAliveClientMixin`（`wantKeepAlive => true`）保状态、切回不重建。`selectedIndex` 与 `onTabSelected` 直接驱动 `PageView`，`onPageChanged` 同步回选中。
- **选中态**：`selectedIconColor` / `selectedLabelColor` = 主题蓝 `kPrimary`（0xFF0A84FF，用户 2026-08-20 要求），未选中走插件默认；图标 24px + 文字 11~12px。
- **夜间模式（2026-08-20 接入）**：`GlassTabBar.bottom` 传 `adaptiveBrightness: true` + `brightnessOverride`（`ValueNotifier<Brightness>`，同步客户端通用判断 `Theme.of(context).brightness`），夜间自动渲染深色玻璃 / 阴影（详见 `docs/UI规范.md` 11.4）。
- **不做**额外自绘特效；**不嵌真 `UITabBar`**（原因见 `docs/UI规范.md` 第 11.6 节）。
- 标签栏是「全页面 iOS 26 风格」（§1.1）中一级浮层的一部分，非孤立元素。

### 4.4 搜索控件（iOS 原生观感）

- 所有涉及搜索的页面（好友/群聊/帖子/通知/消息搜索等），搜索框统一用 Flutter 官方 **`CupertinoSearchTextField`**：自动带放大镜图标、圆角胶囊、一键清空、键盘联动（`TextInputAction.search`）。
- 搜索按钮用 `CupertinoButton` 观感（胶囊 + `kPrimary` / 玻璃底），**不嵌原生 `UISearchBar`**（评估见 `docs/UI规范.md` 第 11.6 节）。
- 搜索栏属一级玻璃浮层（§1.1）：优先 `liquid_glass_widgets` shader 玻璃；自绘兜底用 `BackdropFilter` 模糊 + 半透明底 + 高光描边。搜索框本身**不引三方搜索组件**（官方 `CupertinoSearchTextField` 观感已足够）。
- 搜索功能页：建议聚焦即 `Navigator.push` 全屏搜索页（原生 iOS 习惯），或列表页内嵌搜索栏二选一，全 App 统一。

### 4.5 尺寸与断点

- **触摸目标**：最小可点击区域 44×44dp（iOS 建议）~ 48×48dp（Material），按钮 / 列表项 / 图标满足此下限。
- **页面留白**：左右 16dp，卡片间 12dp，分组标题 16dp。
- **表单限宽（适配平板强约束，2026-08-20 决策）**：登录 / 注册等表单列统一套 `MobileFormPane`（`mobile/widgets/mobile_form_pane.dart`），居中 + `maxWidth: MobileTheme.formMaxWidth`（480），避免 iPad / 平板横屏下输入框、主按钮被 `stretch` 拉成全宽过度拉伸；`GlassButton.expanded` 内置同样的 `maxWidth` 兜底。手机竖屏（< 480dp）不受影响。
- **内容列限宽（适配平板强约束）**：主界面各 tab 内容列统一 `Center` + `ConstrainedBox(maxWidth: 560)`（`home_page.dart` 内 `_ContentPane`），列表 / 卡片 / 表单在平板横屏下不被拉成全宽；手机竖屏不受影响。
- **瀑布流列数**：`< 400` 宽 2 列；`≥ 400`（平板）3 列；列宽下限沿用桌面 `minCardWidth` 思路，逻辑抽到共享层复用。
- **列表分隔**：1px 分隔线或 `kSurfaceBorder` 色边距留白，二选一全 App 统一。

---

## 5. 字体与字号阶梯

| 用途 | 字号 | 字重 |
|---|---|---|
| 页面大标题 | 20 | w600 |
| 卡片标题 / 主操作按钮 | 16 | w600 |
| 正文 / 输入 | 15 | w400 |
| 次要说明 | 13 | w400 |
| 时间 / 角标 / 标签 | 12 / 11 | w400 / w600 |
| 底部标签栏文字 | 11~12 | w600(选中) |

> 正文一律使用系统字体的普通字重（w400），加粗仅用于标题与强调；禁止用 `FontWeight.bold` 泛滥。

---

## 6. 组件规范

### 6.1 移动端页面与组件清单（`mobile/`）

#### 页面（`mobile/pages/`）

| 页面 | 说明 |
|---|---|
| `login_page.dart` | 登录页：玻璃表单、记住密码 / 保持登录联动（自动登录强制记住、取消记住则取消自动登录）、胶囊按钮、维护 503 禁止登录（2026-08-20 已实现） |
| `register_page.dart` | 注册页：昵称 / 手机号 / 密码 / 确认 / 图形验证码（点击刷新），注册成功自动登录保持登录（2026-08-20 已实现） |
| `home_page.dart` | 登录后主界面：`GlassScaffold` + 内容区 `PageView`（左右滑动 + 回弹）+ 底部玻璃标签栏，4 入口「消息 / 广场 / 探索 / 我的」，各页 `AutomaticKeepAliveClientMixin` 保状态；平板下内容列限宽 560 居中；「我的」页含资料卡 + 退出登录（2026-08-20 已实现） |

#### 主题（`mobile/theme/`）

| 文件 | 说明 |
|---|---|
| `mobile_theme.dart` | 移动端主题：系统字体（null）、字号阶梯、胶囊 FilledButton、二级玻璃输入框、页面背景渐变、Cupertino 页面转场（2026-08-20 已实现） |

#### 组件（`mobile/widgets/`）

| 组件 | 说明 |
|---|---|
| ~~`mobile_bottom_nav.dart`~~ | 已删除（2026-08-20）：自绘封装被插件 `GlassTabBar.bottom` 替代，改内联于 `home_page.dart`（§4.3） |
| `mobile_search_field.dart` | 搜索框：`CupertinoSearchTextField` 封装（放大镜 / 一键清空 / 键盘联动，§4.4） |
| `mobile_app_bar.dart` | 轻量页头（48 高 embedded，样式对齐桌面 `SecondaryTitleBar` 但独立实现） |
| `long_press_menu.dart` | 长按菜单（替代桌面 `BubbleMenuOverlay` 右键） |
| `mobile_pick_images.dart` | 图片选择（相册 / 相机 / 长图压缩，替代桌面 `pick_images`） |
| `glass_button.dart` | iOS 26 按钮 `GlassButton`：primary（`kPrimary` 实底胶囊，高 48）/ secondary（半透明玻璃底 + 细描边，高 44）/ link（纯文字），`CupertinoButton` 观感，支持 loading 与禁用态；`expanded` 时内置 `maxWidth`（默认 `MobileTheme.formMaxWidth` 480）限宽，适配平板（§6.4，2026-08-20 新增） |
| `mobile_form_pane.dart` | 移动端表单容器 `MobileFormPane`：`Center` + `ConstrainedBox(maxWidth: formMaxWidth=480)` 限宽居中，登录 / 注册表单统一套用，平板下输入框 / 按钮不被拉成全宽（§4.5，2026-08-20 新增） |
| 移动端卡片 / 弹层 | 列表卡片、底部弹层、确认弹窗，Material 风格 + 主题常量 |

### 6.2 提示与反馈

- 全局提示复用共享 `widgets/notify.dart`（`NotifyStack`：info / success / warning；`AppDialog`：确认框），移动端**不另造** SnackBar/Toast 体系。
- 表单校验错误就地提示（输入框下方），不弹全局。
- 提交类操作要有 loading 态，成功后清空/返回。

### 6.3 图片与媒体

- 网络图统一 `utils/net_image.dart`（`NetImage`），自带占位/失败态。
- 头像用共享 `CachedAvatar` / `UserAvatar`，禁止 GIF。
- 压缩逻辑复用 `utils/image_transcoder.dart`（`ImageTranscoder`）与 `widgets/image_compressor.dart`（`StickerCompressor` 表情包），移动端不重复实现。
- 大图预览：点击全屏，双指缩放 + 左右滑动切换。

### 6.4 按钮 / 图标 / 圆角

- **按钮（iOS 26 风格为强约束，2026-08-20 决策）**：统一用 `mobile/widgets/glass_button.dart` 的 `GlassButton`（`CupertinoButton` 观感，禁止直接用 Material 按钮）：
  - `GlassButton.primary`：主操作，`kPrimary` 实底胶囊 + 白字 + 高 48，通常撑满宽度（`expanded`）；
  - `GlassButton.secondary`：次操作，半透明玻璃底（`primarySoft`）+ 细描边 + `kPrimary` 文字 + 高 44；
  - `GlassButton.link`：纯文字 `kPrimary` 胶囊（辅助跳转，如"去登录 / 去注册"）；
  - 支持 `loading`（菊花替代文字）与禁用态（半透明）；按压反馈为按压半透明（无 Material 水波）。
  - `expanded=true` 时内置 `maxWidth` 限宽（默认 `MobileTheme.formMaxWidth` 480，可传参覆盖），平板下不会被 `stretch` 列拉成全宽（适配 pad 强约束）。
  - 权威规格见 `docs/UI规范.md` §11.3（按钮 = `CupertinoButton` 观感，胶囊化 `kRadiusFull`）。
- 图标：Material Icons，导航类 24px，列表项 24px，辅助 18px；文字按钮不配大图标。
- 圆角：卡片 18（`kRadiusMax` 系）、组件 12、按钮 999（胶囊，`kRadiusFull`）、小标签 6，统一从 `app_theme.dart` 取。

---

## 7. 交互规范（桌面 → 移动平移）

| 桌面 | 移动端 |
|---|---|
| `MouseRegion` hover 高亮 | 点击态（`InkWell` 水波纹） |
| 右键菜单（`BubbleMenuOverlay`） | 长按弹出（`long_press_menu`） |
| `Tooltip` | 长按辅助说明 / 引导气泡 |
| `SystemMouseCursors.click` | 忽略 |
| 键盘 Enter 发送 | 软键盘 send 动作（`TextInputAction.send`） |
| 滚轮缩放头像 / 图片 | 双指缩放（`InteractiveViewer`） |
| 窗口拖拽 / 标题栏按钮 | 无（系统返回键 / 手势返回） |

其他：

- **返回**：Android 返回键 `Navigator.maybePop`；根页退后台；iOS 左滑返回默认开启，勿手动禁用。
- **聊天发送**：输入框 `TextInputAction.send`，空内容禁发。
- **图片选择**：长图/多图选择后走统一压缩，禁止直传原图。

---

## 8. 明暗主题与可访问性

1. **深色模式**：所有页面/组件必须适配，取色走 `textMutedColor(b)` 等主题函数；新写样式先确认深色可读。
2. **动态字体**：依赖系统字号，布局用弹性（无固定高度文本），测试最大字号下不截断。
3. **对比度**：正文对比度 ≥ 4.5:1；图标态对比度 ≥ 3:1。
4. **点击反馈**：可点元素必须有可见反馈（水波纹 / 透明度变化）。

---

## 9. 状态与性能

- **三态统一**：加载中（骨架屏）/ 空态（图标 + 文案 + 可操作按钮）/ 错误态（重试）全 App 一致。
- **列表**：分页懒加载；图片设置 `cacheWidth`/`cacheHeight` 防 OOM；长列表复用 `silky_scroll`。
- **动画**：页面转场 Material 默认；底部标签栏用 `liquid_glass_widgets` Liquid Morph 动画引擎（滑动切换 + 果冻过冲，§4.3），不自造复杂动效；禁开全屏动画。

---

## 10. 文档联动

- **移动端 UI 改动**（页面 / 组件 / 主题 / 布局决策）→ 同步更新**本文件**。
- **桌面 UI 改动** → 更新 `docs/UI规范.md`。
- **后端接口新增/修改** → 同步 `docs/API接口文档.md`。
- 液态玻璃标签栏规格以 `docs/UI规范.md` 第 11 章为准，本文件 §4.3 引用不重复维护细节。

---

## 11. 评审自查清单

- [ ] 页面在 `mobile/pages/`，未 import 桌面 `pages/ widgets/`
- [ ] 颜色 / 圆角全部来自 `app_theme.dart` 常量，无魔法数值
- [ ] 深色模式下可读性验证过
- [ ] 触摸目标 ≥ 44dp，留白 16dp
- [ ] 有加载 / 空 / 错三态
- [ ] 图片走了 `NetImage` + 统一压缩，未直传原图
- [ ] 业务逻辑未双写，在共享层 `services/ core/`
- [ ] 页面视觉符合 iOS 26 风格（§1.1：玻璃分级 / 圆角 / 控件 / 背景渐变）
- [ ] 标签栏滑动切换与动画符合 §4.3（PageView 联动 / Liquid Morph / 状态保持）
- [ ] 本文件已同步（新增页面 / 决策变化时）
