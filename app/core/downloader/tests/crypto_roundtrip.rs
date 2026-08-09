// ============================================================
// §10 MVP0 对拍单测：Kugou/Netease 签名 Rust ↔ Dart 字节级一致
//
// 本文件由 app/tool/gen_crypto_vectors.dart 自动生成，请勿手改！
// 重新生成：dart run tool/gen_crypto_vectors.dart > tests/crypto_roundtrip.rs
// ============================================================

#[cfg(test)]
mod kugou_roundtrip {
    use archoera_downloader::crypto::kugou;

    /// kg_md5：与 Dart kgMd5 逐字符一致
    #[test]
    fn test_kg_md5() {
        assert_eq!(kugou::kg_md5("hello world"), "5eb63bbbe01eeed093cb22bb8f5acdc3");
        assert_eq!(kugou::kg_md5(""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(kugou::kg_md5("8744B6EACB2AE3BF1A987886609AAE5B7557C3D0"), "a3f551537847ac6c3ecc5cb917ca6e23");
        assert_eq!(kugou::kg_md5("晴天"), "cbbe546304037478ce0c36437d036711");
        assert_eq!(kugou::kg_md5("LnT6xpN3khm36zse0QzvmgTZ3waWdRSAa=1b=2c=3"), "689310fa8d1c5aae68ac43235743a112");
    }

    /// kg_calc_mid：md5(guid) hex → BigInt 十进制字符串
    #[test]
    fn test_kg_calc_mid() {
        assert_eq!(kugou::kg_calc_mid("8744B6EACB2AE3BF1A987886609AAE5B7557C3D0"), "217937925531622553677117436551481683491");
        assert_eq!(kugou::kg_calc_mid("abc123"), "310510239053275183010661291244328726019");
        assert_eq!(kugou::kg_calc_mid("晴天测试"), "33288407262625112535681369506697612001");
        assert_eq!(kugou::kg_calc_mid("5EB63BBBE01EEED093CB22BB8F5ACDC3"), "3372171152723205480540366785626181099");
        assert_eq!(kugou::kg_calc_mid("KG_LITE_REGISTER_GUID_20260809"), "67335327532616628214903915326283364120");
    }

    /// kg_aes_encrypt_base64：AES-128-CBC + PKCS7，key/iv 派生自 md5(secretKey)
    #[test]
    fn test_kg_aes_encrypt_base64() {
        assert_eq!(kugou::kg_aes_encrypt_base64("{\"appid\":3116,\"dfid\":\"-\",\"mid\":\"1000\",\"part\":1}", "a1b2c3"), "o5+1S0JS4VdaYRf9mqD+fsQB8aA7W4bnmbw8ZMNu98U5H6IiP8EKv4M2cDM/hZbV");
        assert_eq!(kugou::kg_aes_encrypt_base64("{\"availableRamSize\":4983533568,\"brand\":\"Redmi\"}", "123456"), "r/hh0FFSidBPrivUNKHpFvAO0bm8x4UAFRRpvkos9N0HPgUdCJ5ZiwMpkJJ+znPt");
        assert_eq!(kugou::kg_aes_encrypt_base64("{\"uid\":0,\"token\":\"\",\"aes\":\"a1b2c3\"}", "AbCdEf"), "FHFMoe/5rK3HXRseFE+gAGQMKZzGLVNmeCQgHevi9/H0obt6bcmnVu9I+UZWeAf2");
    }

    /// kg_aes 解密回环：Rust 侧 encrypt → decrypt == 原文（自洽性）
    #[test]
    fn test_kg_aes_roundtrip() {
        let cipher = kugou::kg_aes_encrypt_base64("{\"appid\":3116,\"dfid\":\"-\",\"mid\":\"1000\",\"part\":1}", "a1b2c3");
        assert_eq!(cipher, "o5+1S0JS4VdaYRf9mqD+fsQB8aA7W4bnmbw8ZMNu98U5H6IiP8EKv4M2cDM/hZbV");
        assert_eq!(kugou::kg_aes_decrypt_string(&cipher, "a1b2c3").unwrap(), "{\"appid\":3116,\"dfid\":\"-\",\"mid\":\"1000\",\"part\":1}");
        let cipher = kugou::kg_aes_encrypt_base64("{\"availableRamSize\":4983533568,\"brand\":\"Redmi\"}", "123456");
        assert_eq!(cipher, "r/hh0FFSidBPrivUNKHpFvAO0bm8x4UAFRRpvkos9N0HPgUdCJ5ZiwMpkJJ+znPt");
        assert_eq!(kugou::kg_aes_decrypt_string(&cipher, "123456").unwrap(), "{\"availableRamSize\":4983533568,\"brand\":\"Redmi\"}");
        let cipher = kugou::kg_aes_encrypt_base64("{\"uid\":0,\"token\":\"\",\"aes\":\"a1b2c3\"}", "AbCdEf");
        assert_eq!(cipher, "FHFMoe/5rK3HXRseFE+gAGQMKZzGLVNmeCQgHevi9/H0obt6bcmnVu9I+UZWeAf2");
        assert_eq!(kugou::kg_aes_decrypt_string(&cipher, "AbCdEf").unwrap(), "{\"uid\":0,\"token\":\"\",\"aes\":\"a1b2c3\"}");
    }

    /// kg_signature：md5(salt + 排序 k=v 串 + data + salt)
    #[test]
    fn test_kg_signature() {
    {
        let mut params = std::collections::BTreeMap::new();
        params.insert("appid".into(), "3116".into());
        params.insert("clienttime".into(), "1723200000".into());
        params.insert("clientver".into(), "11440".into());
        params.insert("dfid".into(), "-".into());
        params.insert("mid".into(), "1234567890".into());
        params.insert("part".into(), "1".into());
        params.insert("p".into(), "abc".into());
        params.insert("platid".into(), "1".into());
        params.insert("uuid".into(), "-".into());
        let expected = "55a170bb6cac6443c7f2bf81a1d7fb6c";
        assert_eq!(kugou::kg_signature(&params, "AES_CIPHER_BODY", "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"), expected);
    }
    {
        let mut params = std::collections::BTreeMap::new();
        params.insert("appid".into(), "3116".into());
        params.insert("clienttime".into(), "1723200001".into());
        params.insert("clientver".into(), "11440".into());
        params.insert("cmd".into(), "26".into());
        params.insert("dfid".into(), "DFID_REAL".into());
        params.insert("hash".into(), "8744b6eacb2ae3bf1a987886609aae5b7557c3d0".into());
        params.insert("key".into(), "KEY_MD5".into());
        params.insert("mid".into(), "1234567890".into());
        params.insert("quality".into(), "320".into());
        params.insert("signature".into(), "SIG_PLACEHOLDER".into());
        params.insert("uuid".into(), "-".into());
        let expected = "72e933be06de7bd7a359ced59c4e8feb";
        assert_eq!(kugou::kg_signature(&params, "", "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"), expected);
    }
    {
        let mut params = std::collections::BTreeMap::new();
        params.insert("album_audio_id".into(), "0".into());
        params.insert("album_id".into(), "0".into());
        params.insert("behavior".into(), "play".into());
        params.insert("pid".into(), "411".into());
        let expected = "439c0233c4bc11c95d772f3f4859fccf";
        assert_eq!(kugou::kg_signature(&params, "BODY_STD", "OIlwieks28dk2k092lksi2UIkp"), expected);
    }
    }

    /// kg_sign_key：md5(hash + salt + appid + mid + userid)
    #[test]
    fn test_kg_sign_key() {
        assert_eq!(kugou::kg_sign_key("8744b6eacb2ae3bf1a987886609aae5b7557c3d0", "1234567890", 0, 3116, "185672dd44712f60bb1736df5a377e82"), "8e3f750f42966125994aba2ac71f5beb");
        assert_eq!(kugou::kg_sign_key("e5c2a1b7f6d3e4f5a6b7c8d9e0f1a2b3", "999888777", 2919, 3116, "57ae12eb6890223e355ccfcb74edf70d"), "fb26fa88aa2efed69eb5210bfe930f36");
        assert_eq!(kugou::kg_sign_key("abc", "mid-001", 100, 3116, "185672dd44712f60bb1736df5a377e82"), "ca954110f38fabd9f18093fe21f8d781");
    }

    /// kg_rsa_raw_encrypt_hex：零填充 raw RSA → 大写 hex（确定性）
    #[test]
    fn test_kg_rsa_raw_encrypt_hex() {
        assert_eq!(kugou::kg_rsa_raw_encrypt_hex("{\"aes\":\"a1b2c3\",\"uid\":0,\"token\":\"\"}", kugou::KG_LITE_PUBLIC_KEY_PEM), "060AB395C19988166E050F354E54E72D2F4EDCF636C506B670BBBE52577F920D311083665B15F363B788AF0FD239CF822446C10702D9A6F7472BD63F79DCE8F62195E3DB3451809D3B31448FF473B6DFC6B3213F777E32560D7949F3DB9EDB561DCADF5CEDABFA0CBC92359C7C39CDD2CB36B1DD18ABC3C029733EC978913399");
        assert_eq!(kugou::kg_rsa_raw_encrypt_hex("{\"uid\":123456,\"token\":\"tok_xyz\",\"aes\":\"secret\"}", kugou::KG_LITE_PUBLIC_KEY_PEM), "305FB1B62296121ABFC65EF0D5389C348B54793D42E44394907F3B566F7CEE3209B2CA75F91B06A32CD53E366AFDCA0D3D3E34CB3562B72EE17065FD9290E5D89959B29F5BED0436F0045AE8CFBA5F4F3C767F0640EDBE9188E451671E064BDBFFE24E7A000DE1EAD3895A7FBAB1F7B634BA7A6855F77045BD559515719085E8");
    }

    /// kg_rsa_pkcs1_encrypt_hex：带随机填充，不可跨语言对拍 → 只做结构断言
    /// （1024bit 模长 → 密文恰为 128 字节 / 256 位 hex，且两次调用结果不同）
    #[test]
    fn test_kg_rsa_pkcs1_structure() {
        let plain = r#"{"aes":"a1b2c3","uid":0,"token":""}"#;
        let a = kugou::kg_rsa_pkcs1_encrypt_hex(plain, kugou::KG_LITE_PUBLIC_KEY_PEM);
        let b = kugou::kg_rsa_pkcs1_encrypt_hex(plain, kugou::KG_LITE_PUBLIC_KEY_PEM);
        assert_eq!(a.len(), 256, "RSA PKCS1 输出应为 256 位 hex");
        assert!(hex::decode(&a).is_ok(), "RSA PKCS1 输出应为合法 hex");
        assert_ne!(a, b, "PKCS1v1.5 随机填充：两次加密应不同");
    }
}

#[cfg(test)]
mod netease_roundtrip {
    use archoera_downloader::crypto::netease;

    /// nm_aes_cbc_base64：AES-128-CBC + PKCS7，固定 IV
    #[test]
    fn test_nm_aes_cbc_base64() {
        assert_eq!(netease::nm_aes_cbc_base64("{\"id\":\"28948791\",\"level\":\"standard\"}", "0CoJUm6Qyw8W8jud"), "w6DACJ5qUV/LT7vAsb//1BnTHOEVYW/ADqDzdD7WNUTVZzLpLj+CX6/E3Jp9BHex");
        assert_eq!(netease::nm_aes_cbc_base64("{\"csrf_token\":\"\",\"e_r\":false}", "0CoJUm6Qyw8W8jud"), "eHhjXckqrtZkqcwCalCMx/y+g/OeeFJ5wtpy5UUCzxE=");
        assert_eq!(netease::nm_aes_cbc_base64("{\"ids\":\"[12345]\",\"level\":\"exhigh\"}", "secretKey16bytes"), "9Y1WevgvLg1n2mrrJBdJXmISVOOHVNQZJUp7jC3Md7H4zrKONnd4rqFL6mX22pIB");
    }

    /// nm_rsa_encrypt：RSA_NO_PADDING（右对齐补 0）→ 256 位小写 hex（确定性）
    #[test]
    fn test_nm_rsa_encrypt() {
        assert_eq!(netease::nm_rsa_encrypt("abcdefghijklmnop"), "9df4b31c1c8a9336bae7b12d17bef2aaebff40f867b875935d4a5c4324593c87e63ee2489e2f463432ce71e5667a73ca3e26bad55eff852c86182cf4047933b257c6785254936cf2b7518a7067cf4d55aa1e48cd119db0c9dbd2d3adec41c94a711eae94578cea17a3d32e0005b4372b5d09d5700f23c5727a6a6fe89a03c869");
        assert_eq!(netease::nm_rsa_encrypt("0CoJUm6Qyw8W8jud"), "0346440ff4249e431e0aaf6633bdf4bb31ef63563d2103932b053cf3875711da78617966fe383d80ecbbbc81dc8edbeefa095fb47024fdd7b472e4b2b8e919c2fbb9961721d9d12c92c6f037641dd5c2cfb76903707df3364024bf3f6498ad9b1877f9196a08e1ce277039af0e4aecf804016d9b39d700034ce1b964e7574413");
        assert_eq!(netease::nm_rsa_encrypt("a0b1c2d3e4f5"), "8676afe55fd64722665423e6cdee4c9196cab9c9e5912c267e34e2ad77fc3dde229df47f5071abc1d931608ac830e024f771e6ef6e16536413389c3eab3eaca51553a656de43b5ed429825cf9114172b122d3a7b5464a793cbda3f6b020a9cef1289b0eb4be6490da6fa57500f1f39a5534c1061bbcf33fe42bdf1173f7691ff");
    }

    /// weapi_encrypt_with_secret：固定 secretKey 时 params/encSecKey 与 Dart 逐字符一致
    #[test]
    fn test_weapi_encrypt_with_secret() {
        let obj = serde_json::json!({"id": "28948791", "level": "standard", "csrf_token": "", "e_r": false});
        let (params, enc_sec_key) = netease::weapi_encrypt_with_secret(&obj, "abcdefghijklmnop");
        assert_eq!(params, "1XfDKpiIRZpKSeF/6DHeYxBD8A9IKZF9nDQanQgoJZJmBzIYyAsN2KYxBfZ/kctY9BRBPEy69oalU9HQ5Koc7zTv6H7DJPdp74kPDbVlSWcEnccW0/7ghCqEeOWxAmmsEeZGbFKLBsHraDh9Aek9NQ==");
        assert_eq!(enc_sec_key, "d15a1683c992095d0c234c19966605c5c5964911268bbeda8cb8d08d834913e59d53b32358903a121b5fca784c1f5ae44951fd02524df58ecc98e52cc7cf8689b42c2e93ddf05b0592512d87f5960467e2f086c018849d76014d323500e30f13ef4cafbb0cf5a66731a3f1776c75ca35d0062dac70a3e33245afabcf47938487");
        let obj = serde_json::json!({"id": "28948791", "level": "lossless", "csrf_token": "", "e_r": false});
        let (params, enc_sec_key) = netease::weapi_encrypt_with_secret(&obj, "0123456789abcdef");
        assert_eq!(params, "EaYSuebZissLhDQTOG+MOKD1Bcts6ODTK/5+MqOGUZI5mTBKAKecGzqtzvGP9FGKMjZ8Q1O69Fbnb34w8pQdsd9kbCkq3fRWhXMX3uDmguRFA27PSyWWlONSZYvq/P814ws28jLZ3f2DtwSNBHyf6w==");
        assert_eq!(enc_sec_key, "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52");
    }
}

