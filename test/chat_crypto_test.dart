import 'package:flutter_test/flutter_test.dart';
import 'package:acgopc/services/chat_crypto.dart';

void main() {
  test('ChatCrypto 加解密往返', () {
    // A 生成密钥对
    final a = ChatCrypto.generateKeyPair();
    // B 生成密钥对
    final b = ChatCrypto.generateKeyPair();

    // A 用 B 的公钥加密
    const plaintext = '你好，这是测试消息 hello world!';
    final encrypted = ChatCrypto.encrypt(plaintext, b.publicKey);

    // B 用自己的私钥解密
    final decrypted = ChatCrypto.decrypt(
      ciphertextB64: encrypted.body,
      nonceB64: encrypted.nonce,
      encKeyB64: encrypted.encKey,
      privateKeyB64: b.privateKey,
    );

    expect(decrypted, plaintext);
  });

  test('密钥格式为 PEM', () {
    final kp = ChatCrypto.generateKeyPair();
    expect(kp.publicKey, contains('BEGIN RSA PUBLIC KEY'));
    expect(kp.privateKey, contains('BEGIN RSA PRIVATE KEY'));
  });

  test('错误私钥无法解密', () {
    final a = ChatCrypto.generateKeyPair();
    final b = ChatCrypto.generateKeyPair();
    final encrypted = ChatCrypto.encrypt('secret', b.publicKey);
    // 用 A 的私钥解密 B 的消息 → 应抛异常
    expect(
      () => ChatCrypto.decrypt(
        ciphertextB64: encrypted.body,
        nonceB64: encrypted.nonce,
        encKeyB64: encrypted.encKey,
        privateKeyB64: a.privateKey,
      ),
      throwsA(anything),
    );
  });
}
