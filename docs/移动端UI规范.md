# ACGO 移动端（Android / iOS）UI 开发规范

> 适用范围：`lib/mobile/` 下所有移动端页面、组件、主题适配。
> 设计依据：桌面 `docs/UI规范.md`（设计语言沿用）+ `docs/移动端适配方案.md`（2.2 目录决策、3.5 主框架、3.9.1 iOS 26）。
> 核心原则（2026-08-20）：**单代码库、功能层共享、UI 层按平台分目录**。桌面 `pages/ widgets/` 不做移动端改造，移动端前端一律进 `lib/mobile/`。
> **pad（平板）分流（2026-08-20 新增）**：Android/iOS 平板上**不使用本移动端 UI**，改走**桌面 PC 界面**（`AcgoPcApp`）——pad 判定 = 屏幕最短边 ≥ 600dp，由 `main.dart` `DeviceGate` 启动分流；pad 顶栏高度 0px、支持横竖屏切换（权威规格见 `docs/UI规范.md` §0）。**本规范仅适用于手机**（锁定竖屏，不支持横屏）。

---

## 1. 设计语言

移动端延续桌面基调 **正式、极简、扁平**，并按移动端习惯调整：

1. **双主题**：浅色 / 深色，取色统一走 `app_theme.dart` 常量，不硬编码颜色。
2. **主色**：沿用 `kPrimary`（系统主题蓝），成功 `kSuccess` / 警告 `kWarning` / 危险 `kDanger` / 信息 `kInfo`，文案层级用 `textMutedColor(b)`。
3. **圆角**：统一使用 `kRadius*` 常量（Card 大圆角 / Md / Btn / Sm），禁止散落魔法数值。
4. **形态**：页面全屏、无 hover、无右键；以**触摸**（轻点 / 长按 / 双指 / 滑动）为主要交互。
5. **材质（2026-08-20 决策）**：**所有页面内容**均模仿 iOS 26 Liquid Glass 风格（Flutter 实现：一级浮层用自绘 `BackdropFilter` 高斯模糊玻璃 + 细边框 + 圆角，参考 PC 探索页 `_GlassBlock`；不写原生壳、不引三方玻璃库；Android / iOS 统一不按系统分叉；2026-08-20 终弃 `liquid_glass_widgets` 插件）。分级玻璃控制性能，细则见 **§1.1**。

### 1.1 全页面 iOS 26 风格细则（2026-08-20 决策）

> 权威规格：`docs/UI规范.md` 第 11 章（玻璃材质 / 元素规格 / 标签栏），本小节只列移动端执行要点。

- **适用范围**：`lib/mobile/` 全部页面——主框架、列表、详情、发布、个人中心、设置、弹层、输入框、按钮、卡片。
- **分级玻璃（性能第一）**：
  - 一级浮层（导航栏 / 底部标签栏 / 搜索栏 / 底部 sheet / 弹窗）= 玻璃：自绘 `BackdropFilter` 高斯模糊（导航栏 / 标签栏 sigma 14~18 + 半透明底 + 细边框 + 圆角，参考 PC 探索页 `_GlassBlock` 风格）+ 高光描边；
  - 二级浮层（卡片 / 分组列表 / 输入框 / 按钮底）= 弱玻璃或半透明底（sigma 4~6 或仅半透明 + 细描边）；
  - **滚动列表项不套 `BackdropFilter`**（滚动中禁用真模糊），用半透明底模拟；每屏 `BackdropFilter` 实例 ≤ 3。
- **页面元素**：**所有页面背景统一用移动端主背景色 `MobileTheme.pageBackground(b)`**（白天纯白 / 夜间**纯黑** `#000000`，2026-08-20 决策：登录 / 注册 / 消息 / 广场 / 探索 / 我的及系统通知页一致；与桌面端夜间 `#23232A` 区分，移动端禁用 `bgColor(b)`）；列表用 **Inset grouped** 内嵌分组卡片；按钮胶囊化（`kRadiusFull`），次操作玻璃底；分段控件整条胶囊、选中段玻璃浮起；底部弹层用半屏玻璃 sheet（顶部圆角 20 + 下滑关闭 + 指示条）。
- **iOS 原生观感（2026-08-20 决策，不嵌真 UIKit）**：底部标签栏用**自绘高斯模糊玻璃导航栏**（`_GlassBottomNav`，BackdropFilter + 细边框 + 圆角 + 切换动画，见 §4.3，2026-08-20 终弃插件）；搜索框用 Flutter 官方 `CupertinoSearchTextField`（放大镜 / 圆角胶囊 / 一键清空 / 键盘联动）；按钮用 `CupertinoButton` 观感。**不**通过 platform view 嵌入原生 `UITabBar` / `UISearchBar`（评估见 `docs/UI规范.md` 第 11.6 节）。
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
   ├─ widgets/             # mobile_app_bar / long_press_menu / mobile_pick_images / pc_style_back_button …（底部标签栏自绘 `_GlassBottomNav`，内联 home_page.dart）
   └─ theme/               # 移动端主题适配（系统字体、字号阶梯、组件默认样式）
```

### 2.2 import 边界（强制）

移动端文件**只允许 import**：

- ✅ `core/`、`services/`、`controllers/`、`utils/`、`models/`（共享功能层，可任意引用）
- ✅ `mobile/` 内自身文件（`mobile/widgets/`、`mobile/theme/`）
- ✅ `widgets/` **共享白名单**：`cached_avatar`、`user_avatar`、`emoji_data`、`notify`（`NotifyStack` / `AppDialog`）、`bubble_menu`（`BubbleMenu`，支持 `wechatStyle` 微信风格，移动端聊天气泡长按菜单在用），均无平台依赖
- ✅ 无平台依赖的三方包（`silky_scroll` 滚动、图片加载等）
- ❌ **禁止** `pages/` 及 `widgets/` 下桌面实现：`title_bar`、`secondary_title_bar`、`pick_images`、`planet_globe`、`starfield`、`find_form_dialog`、`match_dialog`、`report_dialog`、`sticker_panel`、`text_input_menu`、`page_scaffold` 等

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
| 主框架 | `mobile/pages/home_page.dart`：`Scaffold`（background = 移动端主背景色 `pageBackground(b)`，夜间纯黑，2026-08-20 决策）+ 内容区 `PageView`（4 tab：消息 / 广场 / 探索 / 我的，左右滑动切换，`AutomaticKeepAliveClientMixin` 保状态）+ 自绘玻璃标签栏 `_GlassBottomNav`（§4.3，2026-08-20 终弃插件后自绘） |
| 二级页 | `Navigator.push`（`MaterialPageRoute`）全屏页；顶部用**纯透明顶栏**（2026-08-21 定案）：**无圆角、无边框、无背景色**，直接叠在页面背景上；**顶栏行固定高 44**，**标题字号 15 不加粗**（`SizedBox(height:44)`，`leading` 返回按钮位置任何模式下纹丝不动）；顶栏距 SafeArea 顶部留白 12px；**底部加 0.5px 分割线**（距右侧 4px 与顶栏对齐，夜间 `0x22FFFFFF` / 白天 `0x19000000`）；`leading` 放 `PcStyleBackButton`（`mobile/widgets/pc_style_back_button.dart`，PC 客户端同款：40×40 / **圆形 hover 胶囊**（圆角 20，2026-08-20 定案）/ `arrow_back_ios_new_rounded` 16px / hover 底色），`title` 显式 `textColor(b)`，`actions` 放右侧操作；**顶栏统一封装为 `MobileTopBar` 组件**（`mobile/widgets/mobile_top_bar.dart`，参数 title / onBack / actions，含 `totalHeight=64` 常量供列表占位，2026-08-20 封装；通知页 / 注册页 / 聊天页已接入） |
| 列表页 | 单列为主；瀑布流按宽度自适应列数（见 4.4）；滚动统一 `silky_scroll` |
| 弹层 | `showModalBottomSheet` / `showDialog`（Material），禁止复用桌面自绘弹层 |

### 4.3 底部标签栏（自绘高斯模糊玻璃 + 切换动画，2026-08-20 终弃插件）

- 权威规格见 `docs/UI规范.md` 第 11.4 节；实现内联于 **`mobile/pages/home_page.dart`**（`Scaffold.bottomNavigationBar` 注入自绘 `_GlassBottomNav`），原 `mobile/widgets/mobile_bottom_nav.dart` 已删除。
- **玻璃（2026-08-20 终弃插件后自绘）**：`SafeArea` → 外层留白（`fromLTRB(12,0,12,10)`）→ `ClipRRect`(**完全胶囊 `kRadiusFull`**，与选中胶囊圆角弧度一致，iOS 设计理念) + `BackdropFilter`(高斯模糊 `blur(sigmaX:18, sigmaY:18)`) + 半透明底 + 0.8px 细边框 + 高 64。**样式参考 PC 探索页 `_GlassBlock`**（高斯模糊 + 边框 + 圆角）。页面背景 = `Scaffold` **移动端主背景色 `pageBackground(b)`**（夜间纯黑 `#000000`，2026-08-20 决策：四个 tab 页统一移动端主背景色，不再用渐变）。
- **配色（跟随主题亮度 `b`）**：夜间底 `0xCC23232A`（主背景色高不透明度玻璃）+ 白 12% 边框；白天白 85% 玻璃底 + 黑 8% 边框。选中色统一主题蓝 `kPrimary`（0xFF0A84FF）。
- **选中态动画（平滑变换，2026-08-20 修复 overshoot 越界后定稿）**：`AnimatedContainer` 背景胶囊浮起（**2026-08-20 增补：选中胶囊上下各外扩 2px（总高 52）居中覆盖——内容区 `SizedBox(height: 48)` 固定 48 高 + `Stack(clipBehavior: none)` + `Positioned(top/bottom: -2)` 承载背景，图标文字位置不变**；`kPrimary` 透明底 10%~22%、`BorderRadius.circular(kRadiusFull)` 完全胶囊两侧大圆角、200ms `easeOutCubic`）+ 图标 `AnimatedScale`（选中 1.12、220ms `easeOutBack` 回弹放大——scale 无 [0,1] 约束，可安全 overshoot）+ `AnimatedSwitcher`（220ms，`switchInCurve`/`switchOutCurve` 用 `easeOutCubic`/`easeInCubic`；**严禁 `easeOutBack`**：overshoot >1 会直接传进 `FadeTransition` 的 opacity（须 [0,1]）触发 `parametric value is outside of [0,1] range` 断言刷屏；`transitionBuilder` = `FadeTransition` 淡入淡出 × `ScaleTransition` 0.6→1.0 `easeOutCubic` 缩放）实现 outline→filled 图标平滑变换 + 文字 `AnimatedDefaultTextStyle`（200ms `easeOutCubic`）颜色 / 字重（w500→w600）过渡。
- **角标**：暂不叠加。
- **滑动切换（2026-08-20 定案）**：内容区 **`PageView`**（横向滑动 + `BouncingScrollPhysics` iOS 回弹，替代 `IndexedStack`）；各 tab 页 `AutomaticKeepAliveClientMixin`（`wantKeepAlive => true`）保状态、切回不重建。`selectedIndex` 与 `onTabSelected` 直接驱动 `PageView`，`onPageChanged` 同步回选中。
- **形态**：图标 24px + 文字 11px（选中 w600 / 未选中 w500）。
- **不做**额外自绘特效；**不嵌真 `UITabBar`**（原因见 `docs/UI规范.md` 第 11.6 节）。
- 标签栏是「全页面 iOS 26 风格」（§1.1）中一级浮层的一部分，非孤立元素。

### 4.4 搜索控件（iOS 原生观感）

- 所有涉及搜索的页面（好友/群聊/帖子/通知/消息搜索等），搜索框统一用 Flutter 官方 **`CupertinoSearchTextField`**：自动带放大镜图标、圆角胶囊、一键清空、键盘联动（`TextInputAction.search`）。
- 搜索按钮用 `CupertinoButton` 观感（胶囊 + `kPrimary` / 玻璃底），**不嵌原生 `UISearchBar`**（评估见 `docs/UI规范.md` 第 11.6 节）。
- 搜索栏属一级玻璃浮层（§1.1）：自绘 `BackdropFilter` 模糊 + 半透明底 + 细描边。搜索框本身**不引三方搜索组件**（官方 `CupertinoSearchTextField` 观感已足够）。
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
| `home_page.dart` | 登录后主界面：`Scaffold`（background = 移动端主背景色 `pageBackground(b)`，夜间纯黑）+ 内容区 `PageView`（左右滑动 + 回弹）+ 自绘玻璃底部标签栏 `_GlassBottomNav`（高斯模糊 + 边框 + 完全胶囊圆角 + 切换动画），4 入口「消息 / 广场 / 探索 / 我的」，各页 `AutomaticKeepAliveClientMixin` 保状态；平板下内容列限宽 560 居中；「我的」页含资料卡 + 退出登录（2026-08-20 已实现） |
| `message_page.dart` | 消息 tab（会话列表）：共享 `ChatStore` 会话 + 拉好友列表按 `peer_id` 补真实昵称/头像/在线状态（`getFriends` 分页缓存），会话项头像带加载占位/失败首字兜底 + **右下角在线状态圆点**（参考 PC `_avatarWithStatus`：11px / 绿 `kSuccess`=在线 / 灰 `textFaintColor`=离线 / 1.5px 描边与 `pageBackground(b)` 同色切进头像，`online` 字段从好友列表合并；**在线状态走 WS presence 实时推送**——好友上线/下线即时刷新圆点，WS 断线重连后自动重拉好友列表补状态，2026-08-21 修复）；「系统通知」为一条特殊会话（铃铛渐变圆底头像，与其他会话卡片样式一致，**不显示在线圆点**），标题下显示最近通知内容预览，未读角标 99+ 封顶；不置顶，与普通会话一起按 `last_msg_time` 倒序排列（有新通知自然浮到最上行），点击 push 通知列表页；**平滑加载：本地会话秒出（不阻塞在拉好友/拉通知的网络上），好友昵称/头像与系统通知后台异步补全后再重建列表（2026-08-20 已实现）；**监听 `conversationTick` + `chatUnreadTick` 实时刷新**（自己发消息/收到消息/摘要变化即时重载，2026-08-21 修复）** |
| `notification_page.dart` | 系统通知列表页（`MobileNotificationPage`）：**纯透明顶栏**（`Stack` overlay：底层列表顶部占位 64px，上层 **`MobileTopBar` 通用组件**悬浮，**无圆角 / 无边框 / 无背景色**（2026-08-21 定案），行固定高 44，标题 15 不加粗；返回按钮 + "通知 (未读数)" 标题 + 右侧全部已读 `CupertinoButton`，多选时变「已选 N 项」+ 取消 + 删除，**位置恒定不受列表滚动/多选切换影响**，2026-08-20 定案）；分页 20 条 + 下拉刷新 + 触底自动加载；每条 = 触发者头像（加载占位）+ type 文案标题 + 未读红点 + 评论内容 + 帖子内容块 + 时间；点击标记已读即时减未读，关闭后 onChanged 回写外层角标；移动端帖子详情未做前点击不跳转；**平滑加载：网络请求期间以脉动骨架屏（`_SkeletonList` 灰条占位，替代转圈菊花）平滑过渡（2026-08-20 已实现）**；**左滑删除 + 长按多选（2026-08-20 新增，自绘不引三方库）**：左滑露出右侧红色**胶囊圆形删除按钮**（40×40，仅垃圾桶图标、无文字；滑动区 72px，`GestureDetector` 水平拖拽 + `AnimationController` 220ms easeOutCubic 平移，松手 >45% 阈值展开、互斥展开——一次只开一条、点击内容收回）；**内容层 Material 必须不透明**（已读=页面背景色、未读=`Color.alphaBlend(primarySoftColor, pageBackground)`、多选高亮同理叠加在背景色上），否则未滑动时底层删除按钮会从透明内容层透出（2026-08-20 修复）；长按进入多选模式（顶栏变「已选 N 项」+ 取消 + 删除，返回按钮=退出多选），每条左侧 20px 勾选圈（未选空心圆描边 / 选中实心 `kPrimary` + 白勾，`AnimatedContainer` 180ms，选中项背景 `kPrimary` 10% 高亮），点击切换勾选，删除按钮批量删（统计被删未读数递减，先本地移除再异步删服务端 + `NotificationStore.deleteByIds` 同步缓存） |
| `chat_page.dart` | **聊天详情页** `MobileChatPage`（2026-08-20 已实现）：`MobileTopBar` 纯透明顶栏（返回按钮 + 会话昵称，无圆角/边框/背景色，2026-08-21 定案）；消息列表用**原生 `ListView.builder(reverse:true)`**（触顶 `NotificationListener` 自动加载更早历史；聊天列表不用 silky——`SilkyScroll` 无 reverse 概念会反向操作 offset 导致滑动方向反，原生 ListView 滚轮/触摸/惯性方向由 Flutter 正确计算，2026-08-21 修复）；本地消息秒出（`ChatStore.getMessages` DESC 200 条 + **倒序列表 `reverse:true`**——index 0 = 最新渲染在底部、进入页面天然定位最新无需滚动定位，2026-08-21 重构根治二次定位跳动），后台 `init` + 拉对方公钥 + `pullHistory` 补远端 + `markChatRead` / `_reportReadUpTo` 已读上报，`ChatNotifier.setCurrentChat` 置顶会话；微信式气泡分组（相邻同发件人纯文本 <5 分钟合并、时间线 5 分钟阈值）；发送=乐观入队 `clientMsgId` 幂等 → `ChatService.sendMessage` → `updateSendStatus` 更新；文本 / 图片（`pickImages` + `ImageTranscoder.toJpeg` → `uploadChatImage` → msg_type=2）/ 表情（`StickerPanel` msg_type=3）；引用（`reply_to` JSON body + 输入区引用预览条）、撤回（2 分钟时限 `ChatService.serverTimeOffsetSec` 校准）、失败重发（长按菜单）；**长按气泡统一弹微信式菜单**（文本「复制/转发/引用/撤回/删除」，图片/表情「转发/引用/撤回/删除」，表情额外「添加到表情」仅对方发的显示，2026-08-21 统一）；**表情包长按：转发（微信式底部卡片 `_ForwardSheet`：从下往上滑出、下滑/点遮罩收起；顶部「最近聊天」横向滚动头像多选 + 下方「好友」列表多选（勾选圈）+ 底部附言输入框（**键盘 `TextInputAction.send` 发送键触发发送，无文字发送按钮**）+ 右侧**表情按钮**（点击展开通用 `EmojiPanel` 仅内置 emoji、不含表情包，emoji 插入附言光标处；面板展开时收起键盘、表情按钮切为键盘图标，并临时显示发送图标按钮作为键盘收起后的发送入口），文本消息预填原文本可编辑、图片/表情附言非空时先发文字再发媒体，批量发送，2026-08-21 重构）/ 添加到表情（`ApiClient.addSticker`，仅对方发的表情显示）/ 删除（`ChatStore.deleteMessageByClientMsgId` 仅本设备删库 + 刷新会话摘要，2026-08-21 新增）**；`WsService.onChatMessage/onChatRead/onChatReadSync/onChatRecall/onChatClear` 实时收发与回执；**`_onWsMessage` 复用 `ChatService.onIncomingMessage`（返回解密消息）直接增量 append，不再每条消息全量重载（2026-08-21 性能优化）**；**`_markAllRead` 内置 `clearUnread` 清本机未读角标（在对话页看过的消息回列表不再残留红点，2026-08-21 修复）**；**`_scrollToBottom` 收敛滚动（SilkyListView 惰性布局首帧 `maxScrollExtent` 偏小，jumpTo 后延迟重跳直至收敛，进入页面可靠定位最新消息，2026-08-21 修复）**；输入区 = 图片按钮 + 表情/贴纸面板开关 + 文本域（`contentPadding vertical: 4`，2026-08-21 调低）+ 胶囊发送按钮；**WS 实时链路由 `mobile_app.dart` 登录后全局启动**（拉 `user/domain` 的 `ws_url` → `WsService.start` + `onChatMessage` 全局解密入库驱动会话列表 tick 实时刷新，2026-08-21 修复移动端聊天实时性/在线状态）；**`_onWsMessage` 复用 `ChatService.onIncomingMessage` 统一解密入库后全量重载**（修复收到消息显示红色感叹号+空气泡，2026-08-21）；`ChatBubble` 气泡组件独立文件 |
| `chat_bubble.dart` | 聊天消息气泡共享组件 `ChatBubble`（2026-08-20 新增）：文本（引用块 `reply_to` 解析：左侧 3px `kPrimary` 竖条 + 回复昵称 + 预览）/ 图片（**本地缓存文件 `Image.file` 优先，其次云端 `ChatImageCache.parseUrl` + `NetImage`**，点击全屏预览（**无关闭按钮，点击图片以外区域关闭**，图片区域 `InteractiveViewer` 双指缩放/拖拽、点击不关闭，2026-08-21 修改）；2026-08-21 修复本地路径被当网络 URL 崩溃「No host specified in URI」）/ 表情（方形 ≤120 圆角，长按/失败重发同文本，同样本地文件优先）；已撤回灰字；发送状态（0=排队转圈 / 1=已读未读（对端已读 `read_status` 变蓝色小勾）/ 2=失败红色叹号可点击重发）；头像（对端 `NetImage` 圆形 + 我方无头像），同发件人连续消息仅首条带头像；`textBodyColor` 取 `app_theme` 顶层函数按明暗切换；**非文本气泡长按菜单走 `BubbleMenu` 微信风格（`wechatStyle:true`，2026-08-21 定案）**：深色半透明圆角面板（`Color(0xF01C1C1E)`，白天夜晚一致）、无小三角箭头、白字白图标（危险项 `kDanger` 红）、整行 hover 高亮（白 8%）、项间 0.5px 细分割线、项高 48 左对齐；**气泡 `preferUp:true` 优先在按压点上方弹出**（上方空间不足回落下方，2026-08-21 修改）；**长按菜单统一 `_buildBubbleMenu`**（2026-08-21 统一）：所有气泡类型复用，菜单项——文本「复制（纯文本不含引用结构）/ 转发 / 引用 / 撤回 / 删除」，图片「转发 / 引用 / 撤回 / 删除」，表情「转发 / 添加到表情（仅对方发的显示）/ 引用 / 撤回 / 删除」；文本气泡由 `SelectableText`（长按只进文字选择）改为普通 `Text` + 长按弹菜单 |

#### 主题（`mobile/theme/`）

| 文件 | 说明 |
|---|---|
| `mobile_theme.dart` | 移动端主题：系统字体（null）、字号阶梯、胶囊 FilledButton、二级玻璃输入框、`pageBackground(b)` 移动端主背景（夜间纯黑，2026-08-20 起全部页面统一使用；`background()` 渐变已弃用）、Cupertino 页面转场（2026-08-20 已实现；登录/注册与 4 tab 及通知页背景统一 `pageBackground(b)`） |

#### 组件（`mobile/widgets/`）

| 组件 | 说明 |
|---|---|
| ~~`mobile_bottom_nav.dart`~~ | 已删除（2026-08-20）：自绘封装几经迭代，最终内联为 `home_page.dart` 的 `_GlassBottomNav`（自绘高斯模糊玻璃，§4.3） |
| `mobile_top_bar.dart` | 二级页通用**纯透明顶栏** `MobileTopBar`（2026-08-20 封装，2026-08-21 改纯透明）：参数 `title` / `onBack`（空走 maybePop）/ `actions`；**无圆角、无边框、无背景色**（2026-08-21 定案）；行固定高 44（返回按钮位置恒定）、标题 15 号不加粗、上留白 12；**底部 0.5px 分割线**（距右侧 4px，夜间 `0x22FFFFFF` / 白天 `0x19000000`）；静态常量 `totalHeight=64` 供列表顶部占位；用方以 `Stack` 置于内容上层。通知页 / 注册页 / 聊天页已接入 |
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
- 大图预览：点击全屏，双指缩放 + 左右滑动切换；无关闭按钮，点击图片以外区域关闭（2026-08-21 修改）。

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
- **动画**：页面转场 Material 默认；底部标签栏选中项用自绘平滑过渡动画（背景胶囊 `AnimatedContainer` + 图标 `AnimatedScale`/`AnimatedSwitcher`（淡入淡出 × 缩放）+ 文字 `AnimatedDefaultTextStyle`，§4.3），不自造复杂动效；禁开全屏动画。

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
- [ ] 页面视觉符合 iOS 26 风格（§1.1：玻璃分级 / 圆角 / 控件；主界面 4 tab 用主背景色，独立页用背景渐变）
- [ ] 标签栏滑动切换与动画符合 §4.3（PageView 联动 / Liquid Morph / 状态保持）
- [ ] 本文件已同步（新增页面 / 决策变化时）
