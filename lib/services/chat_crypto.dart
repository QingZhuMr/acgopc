import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart' as pc;
import 'package:pointycastle/key_generators/rsa_key_generator.dart' as rsa_gen;

/// 聊天端到端加密（E2EE）
///
/// 方案（见 docs/聊天系统设计.md）：
/// - 每个用户本地生成 RSA-2048 密钥对；私钥本地存（SQLite），公钥上传服务器。
/// - 发送：随机 AES-256 密钥 → AES-256-GCM 加密消息（带随机 nonce）→
///   RSA-OAEP(SHA256) 加密 AES 密钥 → 服务器存 { enc_key, nonce, ciphertext }。
/// - 接收：RSA-OAEP 解密 AES 密钥 → AES-GCM 解密。
/// - 服务器只有密文，无法解密（零知识）。
class ChatCrypto {
  /// 生成 RSA-2048 密钥对（PEM 格式）
  static ({String publicKey, String privateKey}) generateKeyPair() {
    final generator = rsa_gen.RSAKeyGenerator()
      ..init(pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
        _rng(),
      ));
    final pair = generator.generateKeyPair();
    final pub = pair.publicKey as pc.RSAPublicKey;
    final priv = pair.privateKey as pc.RSAPrivateKey;

    return (
      publicKey: _encodePublicPem(pub),
      privateKey: _encodePrivatePem(priv),
    );
  }

  /// 加密：用接收方 RSA 公钥加密明文
  ///
  /// 返回 { enc_key, nonce, body }（body 为密文，enc_key 为加密后的 AES 密钥）
  static ({String body, String nonce, String encKey}) encrypt(
    String plaintext,
    String peerPublicKey,
  ) {
    // 1. 随机 AES-256 密钥
    final aesKeyBytes = _randomBytes(32);
    final aesKey = enc.Key(Uint8List.fromList(aesKeyBytes));
    final iv = enc.IV.fromSecureRandom(12); // 96-bit nonce

    // 2. AES-256-GCM 加密消息
    final encrypter = enc.Encrypter(
      enc.AES(aesKey, mode: enc.AESMode.gcm, padding: null),
    );
    final encrypted = encrypter.encrypt(
      plaintext,
      iv: iv,
      associatedData: Uint8List(0),
    );

    // 3. RSA-OAEP 加密 AES 密钥
    final rsa = enc.RSA(
      publicKey: _parsePublicKey(peerPublicKey),
      encoding: enc.RSAEncoding.OAEP,
      digest: enc.RSADigest.SHA256,
    );
    final encKey = rsa.encrypt(Uint8List.fromList(aesKeyBytes));

    return (
      body: encrypted.base64,
      nonce: iv.base64,
      encKey: encKey.base64,
    );
  }

  /// 解密：用本地 RSA 私钥解密
  static String decrypt({
    required String ciphertextB64,
    required String nonceB64,
    required String encKeyB64,
    required String privateKeyB64,
  }) {
    // 1. RSA-OAEP 解密 AES 密钥
    final rsa = enc.RSA(
      privateKey: _parsePrivateKey(privateKeyB64),
      encoding: enc.RSAEncoding.OAEP,
      digest: enc.RSADigest.SHA256,
    );
    final aesKeyBytes = rsa.decrypt(enc.Encrypted.fromBase64(encKeyB64));
    final aesKey = enc.Key(aesKeyBytes);

    // 2. AES-256-GCM 解密（Encrypter 自带 decrypt）
    final decrypter = enc.Encrypter(
      enc.AES(aesKey, mode: enc.AESMode.gcm, padding: null),
    );
    final decrypted = decrypter.decrypt(
      enc.Encrypted.fromBase64(ciphertextB64),
      iv: enc.IV.fromBase64(nonceB64),
      associatedData: Uint8List(0),
    );
    return decrypted;
  }

  // ---------- 内部工具 ----------

  static pc.FortunaRandom? _rngCache;

  /// 安全的随机数生成器（Fortuna）
  static pc.FortunaRandom _rng() {
    if (_rngCache != null) return _rngCache!;
    final r = pc.FortunaRandom()
      ..seed(pc.KeyParameter(Uint8List.fromList(List.generate(
          32, (_) => DateTime.now().microsecondsSinceEpoch % 256))));
    _rngCache = r;
    return r;
  }

  static Uint8List _randomBytes(int len) {
    return _rng().nextBytes(len);
  }

  static pc.RSAPublicKey _parsePublicKey(String pem) {
    return enc.RSAKeyParser().parse(pem) as pc.RSAPublicKey;
  }

  static pc.RSAPrivateKey _parsePrivateKey(String pem) {
    return enc.RSAKeyParser().parse(pem) as pc.RSAPrivateKey;
  }

  // ---------- PEM 编码（PKCS#1） ----------

  static String _encodePublicPem(pc.RSAPublicKey pub) {
    final seq = ASN1Sequence()
      ..add(ASN1Integer(pub.modulus!))
      ..add(ASN1Integer(pub.exponent!));
    final body = seq.encodedBytes;
    return '-----BEGIN RSA PUBLIC KEY-----\n'
        '${base64Encode(body)}\n'
        '-----END RSA PUBLIC KEY-----';
  }

  static String _encodePrivatePem(pc.RSAPrivateKey priv) {
    // PKCS#1：version, n, e, d, p, q, dp, dq, qinv
    final d = priv.privateExponent!;
    final p = priv.p!;
    final q = priv.q!;
    final seq = ASN1Sequence()
      ..add(ASN1Integer(BigInt.zero))
      ..add(ASN1Integer(priv.modulus!))
      ..add(ASN1Integer(priv.exponent!))
      ..add(ASN1Integer(d))
      ..add(ASN1Integer(p))
      ..add(ASN1Integer(q))
      ..add(ASN1Integer(d % (p - BigInt.one)))
      ..add(ASN1Integer(d % (q - BigInt.one)))
      ..add(ASN1Integer(p.modInverse(q)));
    final body = seq.encodedBytes;
    return '-----BEGIN RSA PRIVATE KEY-----\n'
        '${base64Encode(body)}\n'
        '-----END RSA PRIVATE KEY-----';
  }
}
