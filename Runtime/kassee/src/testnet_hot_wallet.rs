//! Testnet-10-only BIP39/Gen1 key derivation. The mnemonic is never persisted
//! in the WASM wallet data; iOS stores it in the Keychain.

use hmac::{Hmac, Mac};
use k256::{elliptic_curve::sec1::ToEncodedPoint, SecretKey};
use serde::Serialize;
use sha2::{Digest, Sha256, Sha512};

type HmacSha512 = Hmac<Sha512>;
const HARDENED: u32 = 0x8000_0000;

#[derive(Serialize)]
pub struct HotWalletImport {
    pub mnemonic: String,
    pub wallet: crate::bip32::WalletData,
}

fn words() -> Vec<&'static str> {
    include_str!("bip39_english.txt")
        .split_whitespace()
        .collect()
}

fn mnemonic_from_entropy(entropy: &[u8; 16]) -> String {
    let checksum = Sha256::digest(entropy);
    let dictionary = words();
    (0..12)
        .map(|word_index| {
            let mut index = 0usize;
            for bit_index in word_index * 11..word_index * 11 + 11 {
                let bit = if bit_index < 128 {
                    (entropy[bit_index / 8] >> (7 - bit_index % 8)) & 1
                } else {
                    (checksum[0] >> (7 - (bit_index - 128))) & 1
                };
                index = (index << 1) | bit as usize;
            }
            dictionary[index]
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn normalized_mnemonic(input: &str) -> Result<String, String> {
    let phrase = input
        .split_whitespace()
        .map(str::to_lowercase)
        .collect::<Vec<_>>()
        .join(" ");
    let parts = phrase.split(' ').collect::<Vec<_>>();
    if parts.len() != 12 {
        return Err("Enter exactly 12 recovery words.".into());
    }
    let dictionary = words();
    let mut bits = [0u8; 17];
    for (word_number, word) in parts.iter().enumerate() {
        let index = dictionary
            .binary_search(word)
            .map_err(|_| "A recovery word is not in the BIP39 English list.")?;
        for offset in 0..11 {
            let bit_position = word_number * 11 + offset;
            bits[bit_position / 8] |=
                (((index >> (10 - offset)) & 1) as u8) << (7 - bit_position % 8);
        }
    }
    let expected_checksum = Sha256::digest(&bits[..16])[0] >> 4;
    if bits[16] >> 4 != expected_checksum {
        return Err("The recovery words have an invalid checksum.".into());
    }
    Ok(phrase)
}

fn pbkdf2_seed(mnemonic: &str) -> Result<[u8; 64], String> {
    let mut seed = [0u8; 64];
    let mut mac = HmacSha512::new_from_slice(mnemonic.as_bytes())
        .map_err(|_| "HMAC initialization failed")?;
    mac.update(b"mnemonic\0\0\0\x01");
    let mut u = mac.finalize().into_bytes();
    seed.copy_from_slice(&u);
    for _ in 1..2048 {
        let mut mac = HmacSha512::new_from_slice(mnemonic.as_bytes())
            .map_err(|_| "HMAC initialization failed")?;
        mac.update(&u);
        u = mac.finalize().into_bytes();
        for (out, value) in seed.iter_mut().zip(u.iter()) {
            *out ^= value;
        }
    }
    Ok(seed)
}

struct ExtendedPrivateKey {
    secret: SecretKey,
    chain_code: [u8; 32],
}

impl ExtendedPrivateKey {
    fn master(seed: &[u8; 64]) -> Result<Self, String> {
        let mut mac = HmacSha512::new_from_slice(b"Bitcoin seed")
            .map_err(|_| "HMAC initialization failed")?;
        mac.update(seed);
        let result = mac.finalize().into_bytes();
        let secret = SecretKey::from_slice(&result[..32]).map_err(|_| "Invalid master key")?;
        let mut chain_code = [0; 32];
        chain_code.copy_from_slice(&result[32..]);
        Ok(Self { secret, chain_code })
    }

    fn derive(&self, index: u32) -> Result<Self, String> {
        let mut mac = HmacSha512::new_from_slice(&self.chain_code)
            .map_err(|_| "HMAC initialization failed")?;
        if index & HARDENED != 0 {
            mac.update(&[0]);
            mac.update(&self.secret.to_bytes());
        } else {
            mac.update(self.secret.public_key().to_encoded_point(true).as_bytes());
        }
        mac.update(&index.to_be_bytes());
        let result = mac.finalize().into_bytes();
        use k256::elliptic_curve::bigint::U256;
        use k256::elliptic_curve::ops::Reduce;
        let tweak = <k256::Scalar as Reduce<U256>>::reduce_bytes((&result[..32]).into());
        let parent = <k256::Scalar as Reduce<U256>>::reduce_bytes((&self.secret.to_bytes()).into());
        let child = tweak + parent;
        let secret = SecretKey::from_slice(&child.to_bytes()).map_err(|_| "Invalid child key")?;
        let mut chain_code = [0; 32];
        chain_code.copy_from_slice(&result[32..]);
        Ok(Self { secret, chain_code })
    }
}

pub fn import(mnemonic: &str) -> Result<HotWalletImport, String> {
    let mnemonic = normalized_mnemonic(mnemonic)?;
    let seed = pbkdf2_seed(&mnemonic)?;
    let account = ExtendedPrivateKey::master(&seed)?
        .derive(HARDENED + 44)?
        .derive(HARDENED + 111_111)?
        .derive(HARDENED)?;
    let parent = ExtendedPrivateKey::master(&seed)?
        .derive(HARDENED + 44)?
        .derive(HARDENED + 111_111)?;
    let parent_bytes = parent.secret.public_key().to_encoded_point(true);
    let fingerprint = ripemd::Ripemd160::digest(Sha256::digest(parent_bytes.as_bytes()));
    let mut payload = Vec::with_capacity(78);
    payload.extend_from_slice(&[0x03, 0x90, 0xa2, 0x41]); // KTUB
    payload.push(3);
    payload.extend_from_slice(&fingerprint[..4]);
    payload.extend_from_slice(&HARDENED.to_be_bytes());
    payload.extend_from_slice(&account.chain_code);
    payload.extend_from_slice(
        account
            .secret
            .public_key()
            .to_encoded_point(true)
            .as_bytes(),
    );
    let ktub = bs58::encode(payload).with_check().into_string();
    let wallet = crate::bip32::import_kpub(&ktub, "kaspatest")?;
    Ok(HotWalletImport { mnemonic, wallet })
}

pub fn generate() -> Result<HotWalletImport, String> {
    let mut entropy = [0u8; 16];
    getrandom::getrandom(&mut entropy).map_err(|_| "Secure random generation failed")?;
    import(&mnemonic_from_entropy(&entropy))
}

pub fn private_key_for(mnemonic: &str, chain: u32, index: u32) -> Result<[u8; 32], String> {
    if chain > 1 || index >= HARDENED {
        return Err("Invalid Testnet wallet derivation path".into());
    }
    let mnemonic = normalized_mnemonic(mnemonic)?;
    let seed = pbkdf2_seed(&mnemonic)?;
    let key = ExtendedPrivateKey::master(&seed)?
        .derive(HARDENED + 44)?
        .derive(HARDENED + 111_111)?
        .derive(HARDENED)?
        .derive(chain)?
        .derive(index)?;
    Ok(key.secret.to_bytes().into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bip39_zero_entropy_vector() {
        assert_eq!(mnemonic_from_entropy(&[0; 16]), "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about");
        assert_eq!(&hex::encode(pbkdf2_seed("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about").unwrap())[..64], "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1");
    }

    #[test]
    fn rejects_bad_checksum() {
        assert!(import("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon").is_err());
    }
}
