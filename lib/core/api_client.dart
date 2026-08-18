import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'app_config.dart';
import 'device_service.dart';

/// 统一 API 客户端：负责请求签名 + 密钥头组装。
///
/// 安全机制：
///   - 签名：signature = HMAC-SHA256(apiSecret, "timestamp|path")
///     请求头 X-Timestamp + X-Signature，服务端验签，时间戳防重放
///   - 业务接口额外携带 X-Device-Key（设备级密钥）
class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  /// 生成签名（与后端 ApiAuth 一致）
  ///
  /// 注意：后端用 `$request->pathinfo()`（不含前导斜杠、转小写）参与签名，
  /// 而 URL 拼接需要带斜杠。因此这里统一规范化 path：
  ///   去掉首尾斜杠 + 转小写，与服务端完全一致，避免"签名校验失败"。
  static String sign(String timestamp, String path) {
    final normalized = path.trim().replaceAll(RegExp(r'^/+|/+$'), '').toLowerCase();
    final key = utf8.encode(AppConfig.apiSecret);
    final data = utf8.encode('$timestamp|$normalized');
    final digest = Hmac(sha256, key).convert(data).toString();
    return digest;
  }

  /// 生成签名请求头（通用，不含 device_key）
  ///
  /// 时间戳使用"本地时间 + 时钟偏移"（由 user/domain 校时），
  /// 确保与服务端时间一致，避免时钟不准导致"签名已过期"。
  static Map<String, String> _signHeaders(String path, {String? deviceKey}) {
    final ts = AppConfig.nowTimestamp().toString();
    final headers = <String, String>{
      'X-Timestamp': ts,
      'X-Signature': sign(ts, path),
    };
    if (deviceKey != null && deviceKey.isNotEmpty) {
      headers['X-Device-Key'] = deviceKey;
    }
    return headers;
  }

  /// 登录请求（公开接口：仅签名，不带 device_key）
  ///
  /// [account] 支持手机号或 UID（服务端按 phone 或 id 匹配）。
  Future<http.Response> postLogin({
    required String account,
    required String password,
    required String platform,
    required String deviceId,
  }) {
    final path = '/user/login';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path),
      },
      body: {
        'account': account,
        'password': password,
        'platform': platform,
        'device_id': deviceId,
      },
    );
  }

  /// 获取域名 + 运行环境 + WebSocket 连接参数（公开接口：仅签名）
  ///
  /// 服务端根据 .env 的 APP_ENV 决定 ws_scheme：
  ///   开发环境 → 'ws'，生产环境 → 'wss'（服务端强制）
  Future<http.Response> getDomainConfig() {
    final path = '/user/domain';
    return http.get(
      Uri.parse(AppConfig.api(path)),
      headers: {
        ..._signHeaders(path),
      },
    );
  }

  /// 更新检查（业务接口：签名 + 设备密钥）
  Future<http.Response> getUpdateCheck({
    required String platform,
    required String clientVersion,
  }) {
    final path = '/update/check';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'platform': platform,
      'client_version': clientVersion,
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 账号状态检查（自动登录后确认账号状态，业务接口）
  Future<http.Response> getStatus() {
    final path = '/user/status';
    return http.get(
      Uri.parse(AppConfig.api(path)),
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 获取广场帖子列表（公开接口：仅签名，游客可浏览）
  ///
  /// [excludeIds] 可选，用于"加载更多"时排除已展示的帖子，避免随机重复。
  Future<http.Response> getPostList({
    int page = 1,
    int pageSize = 10,
    List<int>? excludeIds,
    String? keyword,
  }) {
    final path = '/post/list';
    final query = <String, String>{
      'page': '$page',
      'page_size': '$pageSize',
    };
    if (excludeIds != null && excludeIds.isNotEmpty) {
      query['exclude_ids'] = excludeIds.join(',');
    }
    if (keyword != null && keyword.isNotEmpty) {
      query['keyword'] = keyword;
    }
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: query);
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 发布动态（业务接口：签名 + 设备密钥，multipart/form-data）
  ///
  /// 参数：content（正文）、images[]（图片，可多张，可选）。
  /// 服务端按 device_key 识别用户，客户端无需额外传用户信息。
  Future<http.Response> publishPost({
    required String content,
    List<PostImage>? images,
  }) {
    final path = '/post/publish';
    final ts = AppConfig.nowTimestamp().toString();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse(AppConfig.api(path)),
    )..headers.addAll({
        'X-Timestamp': ts,
        'X-Signature': sign(ts, path),
        'X-Device-Key': DeviceService.instance.getDeviceKey(),
      });
    request.fields['content'] = content;
    if (images != null) {
      for (final img in images) {
        request.files.add(
          http.MultipartFile.fromBytes('images[]', img.bytes,
              filename: img.filename),
        );
      }
    }
    return request.send().then((resp) => http.Response.fromStream(resp));
  }

  /// 获取帖子详情（公开接口：仅签名，游客可浏览；携带 device_key 可返回 is_liked）
  ///
  /// 返回：post（含 images 数组、like_count、is_liked 等）+ comments（顶层分页，每条含 children 楼中楼）+ comment_total。
  Future<http.Response> getPostDetail({
    required int postId,
    int page = 1,
    int pageSize = 20,
  }) {
    final path = '/post/detail';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'post_id': '$postId',
      'page': '$page',
      'page_size': '$pageSize',
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 发表评论 / 回复（业务接口：签名 + 设备密钥，multipart/form-data）
  ///
  /// [parentId] > 0 时表示楼中楼回复，[replyToUid] 为被回复人（0 则由服务端取父评论作者）。
  /// [images] 可选评论图片（字节 + 文件名），最多 9 张。
  Future<http.Response> postComment({
    required int postId,
    required String content,
    int parentId = 0,
    int replyToUid = 0,
    List<PostImage>? images,
  }) {
    final path = '/post/comment';
    final ts = AppConfig.nowTimestamp().toString();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse(AppConfig.api(path)),
    )..headers.addAll({
        'X-Timestamp': ts,
        'X-Signature': sign(ts, path),
        'X-Device-Key': DeviceService.instance.getDeviceKey(),
      });
    request.fields['post_id'] = '$postId';
    request.fields['content'] = content;
    request.fields['parent_id'] = '$parentId';
    request.fields['reply_to_uid'] = '$replyToUid';
    if (images != null) {
      for (final img in images) {
        request.files.add(
          http.MultipartFile.fromBytes('images[]', img.bytes,
              filename: img.filename),
        );
      }
    }
    return request.send().then((resp) => http.Response.fromStream(resp));
  }

  /// 获取表情包列表（业务接口）：全局表情包 + 我上传的
  Future<http.Response> getStickerList() {
    final path = '/sticker/list';
    return http.get(
      Uri.parse(AppConfig.api(path)),
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 上传表情包（业务接口，raw body：`application/octet-stream`）
  ///
  /// 走 `php://input` 原始字节流，绕开 PHP 的 multipart 上传机制
  /// （不依赖 upload_tmp_dir，避免 Windows 上传临时目录配置导致的 Notice）。
  /// 文件名经 query 参数 `filename` 传递。客户端已压缩（240x240、≤256KB）。
  Future<http.Response> uploadSticker(Uint8List bytes,
      {String filename = 'sticker.png'}) {
    final path = '/sticker/upload';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'filename': filename,
    });
    return http.post(
      uri,
      headers: {
        'Content-Type': 'application/octet-stream',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: bytes,
    );
  }

  /// 删除表情包（业务接口）：只能删除自己上传的
  Future<http.Response> deleteSticker({required int stickerId}) {
    final path = '/sticker/delete';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'sticker_id': '$stickerId'},
    );
  }

  /// 帖子点赞 / 取消点赞（切换，业务接口）
  ///
  /// 返回：is_liked、like_count
  Future<http.Response> togglePostLike({required int postId}) {
    final path = '/post/like';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'post_id': '$postId'},
    );
  }

  /// 帖子收藏 / 取消收藏（切换，业务接口）
  ///
  /// 返回：is_favorited、favorite_count
  Future<http.Response> togglePostFavorite({required int postId}) {
    final path = '/post/favorite';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'post_id': '$postId'},
    );
  }

  /// 我的收藏列表（业务接口）：分页返回指定用户收藏的帖子
  ///
  /// targetUid 为空或等于当前用户：返回自己收藏（个人中心「收藏」tab）；
  /// targetUid 为他人：访问他人主页，按对方 privacy_favorites 校验
  /// （设为仅自己时返回空 list + visible=0）。
  /// 字段同广场列表：id, user_id, nickname, avatar, content, images[],
  /// comment_count, like_count, is_liked, is_favorited(恒 true), favorite_count,
  /// create_time, create_time_text, location
  Future<http.Response> getMyFavorites({
    int page = 1,
    int pageSize = 12,
    int? targetUid,
  }) {
    final path = '/post/favorites';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'page': '$page',
      'page_size': '$pageSize',
      if (targetUid != null) 'target_uid': '$targetUid',
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 我的动态列表（业务接口）：分页返回指定用户发布的帖子
  ///
  /// targetUid 为空或等于当前用户：返回自己动态（个人中心「动态」tab）；
  /// targetUid 为他人：访问他人主页，按对方 privacy_posts 校验
  /// （设为仅自己时返回空 list + visible=0）。
  /// 字段同广场列表：id, user_id, nickname, avatar, content, images[],
  /// comment_count, like_count, is_liked, is_favorited(恒 false——自己的帖子不能收藏),
  /// favorite_count, create_time, create_time_text, location
  Future<http.Response> getMyPosts({
    int page = 1,
    int pageSize = 12,
    int? targetUid,
  }) {
    final path = '/post/myPosts';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'page': '$page',
      'page_size': '$pageSize',
      if (targetUid != null) 'target_uid': '$targetUid',
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 浏览历史列表（业务接口）：GET 拉取当前用户浏览历史（最多 120 条）
  ///
  /// 字段同广场列表，另含 browse_at / browse_time_text（浏览时间）。
  Future<http.Response> getBrowseHistory() {
    final path = '/user/browseHistory';
    return http.get(
      Uri.parse(AppConfig.api(path)),
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 记录浏览历史（业务接口）：POST post_id，服务端去重置顶 + 限 120 条
  Future<http.Response> addBrowseHistory(int postId) {
    final path = '/user/browseHistory';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'post_id': '$postId'},
    );
  }

  /// 清空浏览历史（业务接口）：POST clear=1
  Future<http.Response> clearBrowseHistory() {
    final path = '/user/browseHistory';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'clear': '1'},
    );
  }

  /// 删除单条浏览历史（业务接口）：POST delete_post_id
  Future<http.Response> deleteBrowseHistory(int postId) {
    final path = '/user/browseHistory';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'delete_post_id': '$postId'},
    );
  }

  /// 关注 / 取消关注（切换，业务接口）
  ///
  /// 返回 data：{ is_following, is_mutual }
  Future<http.Response> toggleFollow(int targetUid) {
    final path = '/user/follow';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'target_uid': '$targetUid'},
    );
  }

  /// 好友列表（互相关注，业务接口）
  ///
  /// 返回 data：{ list[], page, total, has_more }，
  /// list[] = { user_id, nickname, avatar, follow_time }
  Future<http.Response> getFriends({int page = 1, int pageSize = 20}) {
    final path = '/user/friends';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'page': '$page',
      'page_size': '$pageSize',
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 关注状态（业务接口）
  ///
  /// 返回 data：{ is_following, is_mutual }
  Future<http.Response> getFollowStatus(int targetUid) {
    final path = '/user/followStatus';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'target_uid': '$targetUid',
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 我关注的列表（业务接口）
  ///
  /// 返回 data：{ list[]{ user_id, nickname, avatar, follow_time, is_mutual }, page, total, has_more }
  Future<http.Response> getFollowing({int page = 1, int pageSize = 20}) {
    final path = '/user/following';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'page': '$page',
      'page_size': '$pageSize',
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 我的粉丝列表（业务接口）
  ///
  /// 返回 data：{ list[]{ user_id, nickname, avatar, follow_time, is_mutual }, page, total, has_more }
  Future<http.Response> getFollowers({int page = 1, int pageSize = 20}) {
    final path = '/user/followers';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'page': '$page',
      'page_size': '$pageSize',
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 关注统计（业务接口）
  ///
  /// 返回 data：{ following, followers, friends }
  Future<http.Response> getFollowCounts() {
    final path = '/user/followCounts';
    return http.get(
      Uri.parse(AppConfig.api(path)),
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  // ============ 聊天（第二期，E2EE 密文） ============

  /// 上传本人聊天公钥（业务接口）
  Future<http.Response> postChatKey(String publicKey) {
    final path = '/chat/key';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'public_key': publicKey},
    );
  }

  /// 批量获取用户聊天公钥（业务接口）
  Future<http.Response> getChatKeys(List<int> userIds) {
    final path = '/chat/keys';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'user_ids': userIds.join(',')},
    );
  }

  /// 发送聊天消息（密文，业务接口）
  Future<http.Response> sendChatMessage({
    required int receiverId,
    required String body,
    required String nonce,
    required String ephemeralPub,
    required String clientMsgId,
  }) {
    final path = '/chat/send';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {
        'receiver_id': '$receiverId',
        'msg_type': '1',
        'body': body,
        'nonce': nonce,
        'ephemeral_pub': ephemeralPub,
        'client_msg_id': clientMsgId,
      },
    );
  }

  /// 拉取会话历史（密文，业务接口）
  Future<http.Response> getChatHistory({
    required int peerId,
    int? beforeId,
    int pageSize = 50,
  }) {
    final path = '/chat/history';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'peer_id': '$peerId',
      'page_size': '$pageSize',
      if (beforeId != null) 'before_id': '$beforeId',
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 评论点赞 / 取消点赞（切换，业务接口）
  ///
  /// 返回：is_liked、like_count
  Future<http.Response> toggleCommentLike({required int commentId}) {
    // 注意：ThinkPHP 8 方法分发不做下划线转驼峰，URL 必须与控制器方法名一致
    final path = '/post/commentLike';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'comment_id': '$commentId'},
    );
  }

  /// 删除自己的帖子（业务接口）
  Future<http.Response> deletePost({required int postId}) {
    final path = '/post/deletePost';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'post_id': '$postId'},
    );
  }

  /// 删除自己的评论 / 楼中楼（业务接口）
  Future<http.Response> deleteComment({required int commentId}) {
    final path = '/post/deleteComment';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'comment_id': '$commentId'},
    );
  }

  /// 举报用户 / 帖子 / 评论（业务接口）
  ///
  /// 举报用户传 targetUid（>0）；举报帖子传 postId；举报评论传 postId + commentId。
  Future<http.Response> report({
    int targetUid = 0,
    int postId = 0,
    int commentId = 0,
    required String reason,
    String content = '',
  }) {
    final path = '/post/report';
    final body = <String, String>{
      'reason': reason,
      'content': content,
      if (targetUid > 0) 'target_uid': '$targetUid',
      if (postId > 0) 'post_id': '$postId',
      if (commentId > 0) 'comment_id': '$commentId',
    };
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: body,
    );
  }

  /// 修改昵称（业务接口）
  Future<http.Response> postProfile({required String nickname}) {
    final path = '/user/profile';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'nickname': nickname},
    );
  }

  /// 获取隐私设置（业务接口：签名 + 设备密钥）
  ///
  /// 返回 data：{ privacy_posts: 1|0, privacy_favorites: 1|0 }（1公开 0仅自己）
  Future<http.Response> getPrivacy() {
    final path = '/user/privacy';
    return http.get(
      Uri.parse(AppConfig.api(path)),
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 保存隐私设置（业务接口，POST x-www-form-urlencoded）
  ///
  /// privacyPosts / privacyFavorites 可只传其一（省略的保持原值），
  /// 传 true=公开、false=仅自己。返回保存后的完整配置。
  Future<http.Response> savePrivacy({
    bool? privacyPosts,
    bool? privacyFavorites,
  }) {
    final path = '/user/privacy';
    final body = <String, String>{};
    if (privacyPosts != null) body['privacy_posts'] = privacyPosts ? '1' : '0';
    if (privacyFavorites != null) {
      body['privacy_favorites'] = privacyFavorites ? '1' : '0';
    }
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: body,
    );
  }

  /// 上传头像（业务接口，multipart/form-data 文件字段 avatar）
  ///
  /// 服务端保存后返回可访问的相对路径 avatar（如 /static/avatar/u1_xxx.png）。
  Future<http.Response> uploadAvatar(File image) {
    return uploadAvatarBytes(image.readAsBytesSync(),
        filename: image.uri.pathSegments.isNotEmpty
            ? image.uri.pathSegments.last
            : 'avatar.png');
  }

  /// 上传头像（直接传 bytes，避免本地临时文件 IO）
  Future<http.Response> uploadAvatarBytes(Uint8List bytes,
      {String filename = 'avatar.png'}) {
    final path = '/user/uploadAvatar';
    final ts = AppConfig.nowTimestamp().toString();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse(AppConfig.api(path)),
    )..headers.addAll({
        'X-Timestamp': ts,
        'X-Signature': sign(ts, path),
        'X-Device-Key': DeviceService.instance.getDeviceKey(),
      });
    request.files.add(
      http.MultipartFile.fromBytes('avatar', bytes, filename: filename),
    );
    return request.send().then((resp) => http.Response.fromStream(resp));
  }

  /// 修改密码（业务接口）
  Future<http.Response> postChangePassword({
    required String oldPassword,
    required String newPassword,
  }) {
    final path = '/user/changePassword';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {
        'old_password': oldPassword,
        'new_password': newPassword,
      },
    );
  }

  /// 获取通知列表（业务接口）：分页 + 未读数
  Future<http.Response> getNotificationList({int page = 1, int pageSize = 20}) {
    final path = '/notification/list';
    final uri = Uri.parse(AppConfig.api(path)).replace(queryParameters: {
      'page': '$page',
      'page_size': '$pageSize',
    });
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 获取通知未读数（业务接口）：更新铃铛角标
  Future<http.Response> getNotificationUnreadCount() {
    final path = '/notification/unreadCount';
    return http.get(
      Uri.parse(AppConfig.api(path)),
      headers: {
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 标记单条通知已读（业务接口）
  Future<http.Response> readNotification({required int id}) {
    final path = '/notification/read';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
      body: {'id': '$id'},
    );
  }

  /// 一键全部已读（业务接口）
  Future<http.Response> readAllNotifications() {
    final path = '/notification/readAll';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path, deviceKey: DeviceService.instance.getDeviceKey()),
      },
    );
  }

  /// 获取图形验证码（公开接口：仅签名，不带 device_key）
  ///
  /// 客户端生成唯一 captcha_id（UUID），服务端返回验证码图片 base64。
  Future<http.Response> getCaptcha({required String captchaId}) {
    final path = '/captcha/image';
    final uri = Uri.parse(AppConfig.api(path))
        .replace(queryParameters: {'captcha_id': captchaId});
    return http.get(
      uri,
      headers: {
        ..._signHeaders(path),
      },
    );
  }

  /// 用户注册（公开接口：仅签名，需携带验证码；手机号作为登录标识）
  Future<http.Response> postRegister({
    required String nickname,
    required String password,
    required String phone,
    required String captcha,
    required String captchaId,
  }) {
    final path = '/user/register';
    return http.post(
      Uri.parse(AppConfig.api(path)),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        ..._signHeaders(path),
      },
      body: {
        'nickname': nickname,
        'password': password,
        'phone': phone,
        'captcha': captcha,
        'captcha_id': captchaId,
      },
    );
  }

  /// 安全解析响应 JSON：容忍后端响应体前部的 HTML/PHP Notice 杂质
  ///
  /// 后端 PHP 8 在 Windows 上传文件时，可能在响应体前输出 startup notice
  /// (例如 `<br /><b>Notice</b>: ...<br />{"code":0,...}`)，
  /// 这种情况下 `jsonDecode` 直接解析会 FormatException。
  /// 本方法按"由严到宽"的多级策略提取 JSON 块：
  ///   1) 直接 jsonDecode
  ///   2) 剥离 HTML 标签后取首个 `{` 到末尾
  ///   3) 按花括号配平截取首个完整 JSON 对象
  ///   4) 大括号不配平时，从末尾逐步丢弃不完整尾部再重试
  static Map<String, dynamic> safeJsonDecode(String body) {
    if (body.trim().isEmpty) return <String, dynamic>{};
    final trimmed = body.trim();
    // 1) 直接解析（最干净的情况）
    final direct = _tryJson(trimmed);
    if (direct != null) return direct;
    // 2) 剥离 HTML 标签后取首个 { 到末尾
    final stripped = trimmed.replaceAll(RegExp(r'<[^>]+>'), '');
    final firstBrace = stripped.indexOf('{');
    if (firstBrace >= 0) {
      final direct2 = _tryJson(stripped.substring(firstBrace));
      if (direct2 != null) return direct2;
      // 3) 按花括号配平截取完整 JSON 对象
      final balanced = _balancedObject(stripped, firstBrace);
      final direct3 = balanced != null ? _tryJson(balanced) : null;
      if (direct3 != null) return direct3;
    }
    // 4) 兜底：首 { 之后逐字符丢弃尾部，直到解析成功（容忍 Notice 里的杂散 "}"）
    if (firstBrace >= 0) {
      var s = stripped.substring(firstBrace);
      for (var i = s.length; i > 0; i--) {
        final r = _tryJson(s.substring(0, i));
        if (r != null) return r;
      }
    }
    return <String, dynamic>{};
  }

  static Map<String, dynamic>? _tryJson(String s) {
    try {
      final r = jsonDecode(s);
      return r is Map<String, dynamic> ? r : null;
    } catch (_) {
      return null;
    }
  }

  /// 从 [start]（必须是 '{'）开始，按花括号深度配平截取一个完整 JSON 对象
  static String? _balancedObject(String s, int start) {
    var depth = 0;
    var inString = false;
    var esc = false;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (inString) {
        if (esc) {
          esc = false;
        } else if (c == r'\') {
          esc = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return s.substring(start, i + 1);
      }
    }
    return null; // 不配平
  }

}

/// 发帖图片数据（字节 + 文件名）
class PostImage {
  final List<int> bytes;
  final String filename;

  const PostImage(this.bytes, this.filename);
}
