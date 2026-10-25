// Thin C wrapper over the BoringSSL copy vendored by swift-nio-ssl.
// BoringSSL symbols are prefixed for Swift; C keeps the plain names via macros,
// so everything ADB needs from BoringSSL lives here behind a small API.
#ifndef ADB_CRYPTO_H
#define ADB_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ADB_ANDROID_PUBKEY_SIZE 524
#define ADB_RSA_SIGNATURE_SIZE 256

// MARK: RSA key (adbkey)

typedef struct adb_key adb_key;

adb_key *adb_key_generate(void);
// Accepts DER (PKCS#1 or PKCS#8) private key bytes.
adb_key *adb_key_from_der(const uint8_t *der, size_t len);
// Writes PKCS#8 DER. Returns the full length; copies only if it fits in cap.
size_t adb_key_to_der(const adb_key *key, uint8_t *out, size_t cap);
void adb_key_free(adb_key *key);
// Signs the 20-byte AUTH token the way adb does (PKCS#1 v1.5, SHA-1 DigestInfo).
int adb_key_sign_token(const adb_key *key, const uint8_t *token, size_t token_len,
                       uint8_t *out, size_t *out_len);
// Android "mincrypt" RSAPublicKey struct, 524 bytes.
int adb_key_android_pubkey(const adb_key *key, uint8_t *out);

// MARK: Hashing

void adb_sha256(const uint8_t *data, size_t len, uint8_t out[32]);

// MARK: TLS client over memory buffers

typedef struct adb_tls adb_tls;

adb_tls *adb_tls_new(const adb_key *key);
void adb_tls_free(adb_tls *tls);
// 1 = handshake complete, 0 = needs more network IO, -1 = error.
int adb_tls_handshake(adb_tls *tls);
// Returns bytes consumed, 0 when it needs network IO, -1 on error.
int adb_tls_write(adb_tls *tls, const uint8_t *buf, size_t len);
// Returns bytes read, 0 when it needs more network input, -1 on error or close.
int adb_tls_read(adb_tls *tls, uint8_t *buf, size_t cap);
// Ciphertext received from the network.
void adb_tls_feed(adb_tls *tls, const uint8_t *buf, size_t len);
// Ciphertext that must be sent to the network.
size_t adb_tls_take_output(adb_tls *tls, uint8_t *buf, size_t cap);
int adb_tls_export_keying_material(adb_tls *tls, uint8_t *out, size_t len,
                                   const char *label, size_t label_len);
// Copies the last BoringSSL error string into buf.
void adb_tls_last_error(char *buf, size_t cap);

// MARK: Pairing (SPAKE2 + AES-128-GCM), client role

#define ADB_PAIR_MAX_MSG_SIZE 32
#define ADB_PAIR_GCM_OVERHEAD 16

typedef struct adb_pair adb_pair;

adb_pair *adb_pair_new(const uint8_t *password, size_t len);
void adb_pair_free(adb_pair *pair);
int adb_pair_msg(adb_pair *pair, uint8_t *out, size_t *out_len);
int adb_pair_process(adb_pair *pair, const uint8_t *msg, size_t len);
int adb_pair_encrypt(adb_pair *pair, const uint8_t *in, size_t len,
                     uint8_t *out, size_t cap, size_t *out_len);
int adb_pair_decrypt(adb_pair *pair, const uint8_t *in, size_t len,
                     uint8_t *out, size_t cap, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif
