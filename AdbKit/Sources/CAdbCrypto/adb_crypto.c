#include "adb_crypto.h"

#include <string.h>
#include <CNIOBoringSSL.h>

struct adb_key {
    EVP_PKEY *pkey;
};

struct adb_tls {
    SSL_CTX *ctx;
    SSL *ssl;
    BIO *in;   // network -> ssl
    BIO *out;  // ssl -> network
};

struct adb_pair {
    SPAKE2_CTX *spake;
    EVP_AEAD_CTX aead;
    int has_aead;
    uint64_t enc_seq;
    uint64_t dec_seq;
    uint8_t password[512];
    size_t password_len;
};

// MARK: Hashing

void adb_sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
    SHA256(data, len, out);
}

// MARK: Key

adb_key *adb_key_generate(void) {
    RSA *rsa = RSA_new();
    BIGNUM *e = BN_new();
    adb_key *key = NULL;
    if (!rsa || !e || !BN_set_word(e, RSA_F4) || !RSA_generate_key_ex(rsa, 2048, e, NULL)) {
        goto done;
    }
    key = calloc(1, sizeof(adb_key));
    key->pkey = EVP_PKEY_new();
    EVP_PKEY_assign_RSA(key->pkey, rsa);
    rsa = NULL;
done:
    RSA_free(rsa);
    BN_free(e);
    return key;
}

adb_key *adb_key_from_der(const uint8_t *der, size_t len) {
    const uint8_t *p = der;
    EVP_PKEY *pkey = d2i_AutoPrivateKey(NULL, &p, (long)len);
    if (!pkey) return NULL;
    if (EVP_PKEY_id(pkey) != EVP_PKEY_RSA) {
        EVP_PKEY_free(pkey);
        return NULL;
    }
    adb_key *key = calloc(1, sizeof(adb_key));
    key->pkey = pkey;
    return key;
}

size_t adb_key_to_der(const adb_key *key, uint8_t *out, size_t cap) {
    CBB cbb;
    uint8_t *der = NULL;
    size_t der_len = 0;
    if (!CBB_init(&cbb, 0) || !EVP_marshal_private_key(&cbb, key->pkey) ||
        !CBB_finish(&cbb, &der, &der_len)) {
        CBB_cleanup(&cbb);
        return 0;
    }
    if (der_len <= cap) memcpy(out, der, der_len);
    OPENSSL_free(der);
    return der_len;
}

void adb_key_free(adb_key *key) {
    if (!key) return;
    EVP_PKEY_free(key->pkey);
    free(key);
}

int adb_key_sign_token(const adb_key *key, const uint8_t *token, size_t token_len,
                       uint8_t *out, size_t *out_len) {
    const RSA *rsa = EVP_PKEY_get0_RSA(key->pkey);
    unsigned int len = 0;
    if (!RSA_sign(NID_sha1, token, token_len, out, &len, (RSA *)rsa)) return 0;
    *out_len = len;
    return 1;
}

static void put_le32(uint8_t *p, uint32_t v) {
    p[0] = v & 0xff;
    p[1] = (v >> 8) & 0xff;
    p[2] = (v >> 16) & 0xff;
    p[3] = (v >> 24) & 0xff;
}

int adb_key_android_pubkey(const adb_key *key, uint8_t *out) {
    // Layout from AOSP libcrypto_utils android_pubkey.cpp:
    // u32 modulus words, u32 n0inv, u8 modulus[256], u8 rr[256], u32 exponent (all LE).
    const RSA *rsa = EVP_PKEY_get0_RSA(key->pkey);
    const BIGNUM *n = RSA_get0_n(rsa);
    const BIGNUM *e = RSA_get0_e(rsa);
    BN_CTX *ctx = BN_CTX_new();
    BIGNUM *r32 = BN_new(), *n0inv = BN_new(), *rr = BN_new();
    int ok = 0;
    if (!ctx || !r32 || !n0inv || !rr) goto done;
    if (!BN_set_bit(r32, 32) || !BN_mod(n0inv, n, r32, ctx) ||
        !BN_mod_inverse(n0inv, n0inv, r32, ctx) || !BN_sub(n0inv, r32, n0inv)) {
        goto done;
    }
    if (!BN_set_bit(rr, 4096) || !BN_mod(rr, rr, n, ctx)) goto done;
    put_le32(out, 64);
    put_le32(out + 4, (uint32_t)BN_get_word(n0inv));
    if (!BN_bn2le_padded(out + 8, 256, n) || !BN_bn2le_padded(out + 264, 256, rr)) goto done;
    put_le32(out + 520, (uint32_t)BN_get_word(e));
    ok = 1;
done:
    BN_free(r32);
    BN_free(n0inv);
    BN_free(rr);
    BN_CTX_free(ctx);
    return ok;
}

// MARK: Certificate (mirrors AOSP adb/crypto/x509_generator.cpp)

static int add_ext(X509 *cert, int nid, const char *value) {
    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, cert, cert, NULL, NULL, 0);
    X509_EXTENSION *ext = X509V3_EXT_nconf_nid(NULL, &ctx, nid, value);
    if (!ext) return 0;
    int ok = X509_add_ext(cert, ext, -1);
    X509_EXTENSION_free(ext);
    return ok;
}

static X509 *make_certificate(EVP_PKEY *pkey) {
    X509 *cert = X509_new();
    if (!cert) return NULL;
    X509_set_version(cert, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(cert), 1);
    X509_gmtime_adj(X509_get_notBefore(cert), 0);
    X509_gmtime_adj(X509_get_notAfter(cert), 10L * 365 * 24 * 60 * 60);
    X509_set_pubkey(cert, pkey);
    X509_NAME *name = X509_get_subject_name(cert);
    X509_NAME_add_entry_by_txt(name, "C", MBSTRING_ASC, (const uint8_t *)"US", -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, (const uint8_t *)"Android", -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const uint8_t *)"Adb", -1, -1, 0);
    X509_set_issuer_name(cert, name);
    add_ext(cert, NID_basic_constraints, "critical,CA:TRUE");
    add_ext(cert, NID_key_usage, "critical,keyCertSign,cRLSign,digitalSignature");
    add_ext(cert, NID_subject_key_identifier, "hash");
    if (!X509_sign(cert, pkey, EVP_sha256())) {
        X509_free(cert);
        return NULL;
    }
    return cert;
}

// MARK: TLS

static enum ssl_verify_result_t accept_any_cert(SSL *ssl, uint8_t *out_alert) {
    // adb does not verify the device certificate; trust comes from the
    // pairing step or the RSA key store on the device.
    (void)ssl;
    (void)out_alert;
    return ssl_verify_ok;
}

adb_tls *adb_tls_new(const adb_key *key) {
    adb_tls *tls = calloc(1, sizeof(adb_tls));
    X509 *cert = make_certificate(key->pkey);
    if (!cert) goto fail;
    tls->ctx = SSL_CTX_new(TLS_method());
    if (!tls->ctx) goto fail;
    SSL_CTX_set_min_proto_version(tls->ctx, TLS1_3_VERSION);
    SSL_CTX_set_max_proto_version(tls->ctx, TLS1_3_VERSION);
    SSL_CTX_set_custom_verify(tls->ctx, SSL_VERIFY_PEER, accept_any_cert);
    if (!SSL_CTX_use_certificate(tls->ctx, cert) || !SSL_CTX_use_PrivateKey(tls->ctx, key->pkey)) {
        goto fail;
    }
    X509_free(cert);
    cert = NULL;
    tls->ssl = SSL_new(tls->ctx);
    if (!tls->ssl) goto fail;
    tls->in = BIO_new(BIO_s_mem());
    tls->out = BIO_new(BIO_s_mem());
    BIO_set_mem_eof_return(tls->in, -1);
    BIO_set_mem_eof_return(tls->out, -1);
    // SSL_set_bio takes ownership of one reference each; keep our own too.
    BIO_up_ref(tls->in);
    BIO_up_ref(tls->out);
    SSL_set_bio(tls->ssl, tls->in, tls->out);
    SSL_set_connect_state(tls->ssl);
    return tls;
fail:
    X509_free(cert);
    adb_tls_free(tls);
    return NULL;
}

void adb_tls_free(adb_tls *tls) {
    if (!tls) return;
    SSL_free(tls->ssl);
    BIO_free(tls->in);
    BIO_free(tls->out);
    SSL_CTX_free(tls->ctx);
    free(tls);
}

static int io_result(adb_tls *tls, int ret) {
    if (ret > 0) return ret;
    int err = SSL_get_error(tls->ssl, ret);
    if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) return 0;
    return -1;
}

int adb_tls_handshake(adb_tls *tls) {
    int ret = SSL_do_handshake(tls->ssl);
    if (ret == 1) return 1;
    return io_result(tls, ret) == 0 ? 0 : -1;
}

int adb_tls_write(adb_tls *tls, const uint8_t *buf, size_t len) {
    return io_result(tls, SSL_write(tls->ssl, buf, (int)len));
}

int adb_tls_read(adb_tls *tls, uint8_t *buf, size_t cap) {
    return io_result(tls, SSL_read(tls->ssl, buf, (int)cap));
}

void adb_tls_feed(adb_tls *tls, const uint8_t *buf, size_t len) {
    BIO_write(tls->in, buf, (int)len);
}

size_t adb_tls_take_output(adb_tls *tls, uint8_t *buf, size_t cap) {
    int n = BIO_read(tls->out, buf, (int)cap);
    return n > 0 ? (size_t)n : 0;
}

int adb_tls_export_keying_material(adb_tls *tls, uint8_t *out, size_t len,
                                   const char *label, size_t label_len) {
    return SSL_export_keying_material(tls->ssl, out, len, label, label_len, NULL, 0, 0);
}

void adb_tls_last_error(char *buf, size_t cap) {
    uint32_t err = ERR_get_error();
    if (err == 0) {
        snprintf(buf, cap, "unknown TLS error");
    } else {
        ERR_error_string_n(err, buf, cap);
    }
}

// MARK: Pairing (mirrors AOSP adb/pairing_auth)

static const uint8_t kClientName[] = "adb pair client";
static const uint8_t kServerName[] = "adb pair server";

adb_pair *adb_pair_new(const uint8_t *password, size_t len) {
    if (len > sizeof(((adb_pair *)0)->password)) return NULL;
    adb_pair *pair = calloc(1, sizeof(adb_pair));
    pair->spake = SPAKE2_CTX_new(spake2_role_alice, kClientName, sizeof(kClientName),
                                 kServerName, sizeof(kServerName));
    if (!pair->spake) {
        free(pair);
        return NULL;
    }
    memcpy(pair->password, password, len);
    pair->password_len = len;
    return pair;
}

void adb_pair_free(adb_pair *pair) {
    if (!pair) return;
    SPAKE2_CTX_free(pair->spake);
    if (pair->has_aead) EVP_AEAD_CTX_cleanup(&pair->aead);
    OPENSSL_cleanse(pair->password, sizeof(pair->password));
    free(pair);
}

int adb_pair_msg(adb_pair *pair, uint8_t *out, size_t *out_len) {
    return SPAKE2_generate_msg(pair->spake, out, out_len, SPAKE2_MAX_MSG_SIZE,
                               pair->password, pair->password_len);
}

int adb_pair_process(adb_pair *pair, const uint8_t *msg, size_t len) {
    uint8_t material[SPAKE2_MAX_KEY_SIZE];
    size_t material_len = 0;
    if (!SPAKE2_process_msg(pair->spake, material, &material_len, sizeof(material), msg, len)) {
        return 0;
    }
    static const uint8_t info[] = "adb pairing_auth aes-128-gcm key";
    uint8_t key[16];
    if (!HKDF(key, sizeof(key), EVP_sha256(), material, material_len, NULL, 0, info,
              sizeof(info) - 1)) {
        return 0;
    }
    if (!EVP_AEAD_CTX_init(&pair->aead, EVP_aead_aes_128_gcm(), key, sizeof(key),
                           EVP_AEAD_DEFAULT_TAG_LENGTH, NULL)) {
        return 0;
    }
    pair->has_aead = 1;
    return 1;
}

static void make_nonce(uint8_t nonce[12], uint64_t seq) {
    memset(nonce, 0, 12);
    memcpy(nonce, &seq, sizeof(seq));
}

int adb_pair_encrypt(adb_pair *pair, const uint8_t *in, size_t len,
                     uint8_t *out, size_t cap, size_t *out_len) {
    if (!pair->has_aead) return 0;
    uint8_t nonce[12];
    make_nonce(nonce, pair->enc_seq);
    if (!EVP_AEAD_CTX_seal(&pair->aead, out, out_len, cap, nonce, sizeof(nonce), in, len, NULL, 0)) {
        return 0;
    }
    pair->enc_seq++;
    return 1;
}

int adb_pair_decrypt(adb_pair *pair, const uint8_t *in, size_t len,
                     uint8_t *out, size_t cap, size_t *out_len) {
    if (!pair->has_aead) return 0;
    uint8_t nonce[12];
    make_nonce(nonce, pair->dec_seq);
    if (!EVP_AEAD_CTX_open(&pair->aead, out, out_len, cap, nonce, sizeof(nonce), in, len, NULL, 0)) {
        return 0;
    }
    pair->dec_seq++;
    return 1;
}
