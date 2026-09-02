// KasSee Web — QR frame generation and decoder
// Copyright (C) 2025-2026 KasSigner Project (kassigner@proton.me)
// License: GPL-3.0
//
// qr.rs — Generate QR frames as SVG strings, decode multi-frame protocol.
// Versioned multi-frame QR format shared with KasSigner firmware. Every frame
// is bound to one complete payload by its transfer id, length and SHA-256.

//! Animated-QR frame encoding and decoding for air-gapped transfer between
//! KasSee and KasSigner.

use serde::Serialize;
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::fmt::Write;

pub(crate) const MAX_FRAME_DATA: usize = 96;

/// Maximum number of frames for a multi-frame QR payload. Standard PSKB
/// transactions are converted to compact KSPT before reaching this encoder.
pub(crate) const MAX_FRAMES: usize = 64;
const MAGIC: [u8; 2] = *b"KQ";
const VERSION: u8 = 2;
const DIGEST_LEN: usize = 16;
const SESSION_LEN: usize = 8;
const HEADER_LEN: usize = 33;

fn payload_kind(data: &[u8]) -> u8 {
    if data.starts_with(b"KSPT") {
        1
    } else if data.len() == 79 && data[0] == 1 {
        2
    } else {
        0
    }
}

fn metadata(data: &[u8]) -> Result<(u8, [u8; SESSION_LEN], [u8; DIGEST_LEN]), String> {
    if data.is_empty() || data.len() > u16::MAX as usize {
        return Err("QR payload exceeds protocol length limit".into());
    }
    let digest = Sha256::digest(data);
    let mut session = [0u8; SESSION_LEN];
    session.copy_from_slice(&digest[16..24]);
    let mut payload_digest = [0u8; DIGEST_LEN];
    payload_digest.copy_from_slice(&digest[..DIGEST_LEN]);
    Ok((payload_kind(data), session, payload_digest))
}

fn encode_frame_payload(data: &[u8], frame_num: u8, total: u8) -> Result<Vec<u8>, String> {
    if total < 2 || frame_num >= total {
        return Err("Invalid QR frame index or total".into());
    }
    let balanced_size = data.len().div_ceil(total as usize);
    if balanced_size == 0 || balanced_size > MAX_FRAME_DATA {
        return Err("Invalid QR frame fragment size".into());
    }
    let start = frame_num as usize * balanced_size;
    let end = (start + balanced_size).min(data.len());
    if start >= end {
        return Err("QR frame has no payload fragment".into());
    }
    let frag = &data[start..end];
    let (kind, session, digest) = metadata(data)?;
    let mut payload = Vec::with_capacity(HEADER_LEN + frag.len().max(20));
    payload.extend_from_slice(&MAGIC);
    payload.push(VERSION);
    payload.push(kind);
    payload.extend_from_slice(&session);
    payload.extend_from_slice(&(data.len() as u16).to_be_bytes());
    payload.extend_from_slice(&digest);
    payload.push(frame_num);
    payload.push(total);
    payload.push(frag.len() as u8);
    payload.extend_from_slice(frag);
    if frag.len() < 20 {
        payload.resize(HEADER_LEN + 20, 0);
    }
    Ok(payload)
}

// ─── Frame generation ───

#[derive(Serialize)]
pub struct QrFrame {
    pub frame_num: u8,
    pub total_frames: u8,
    pub svg: String,
}

pub fn generate_frames(kspt_hex: &str) -> Result<Vec<QrFrame>, String> {
    let data = hex::decode(kspt_hex).map_err(|e| format!("Invalid hex: {}", e))?;

    if data.is_empty() {
        return Err("Empty data".into());
    }

    // Single frame if small enough
    if data.len() <= 134 {
        let svg = qr_to_svg(&data)?;
        return Ok(vec![QrFrame {
            frame_num: 0,
            total_frames: 1,
            svg,
        }]);
    }

    // Multi-frame
    let total_frames = data.len().div_ceil(MAX_FRAME_DATA);
    if total_frames > MAX_FRAMES {
        return Err(format!(
            "Too large: {} bytes ({} frames, max {})",
            data.len(),
            total_frames,
            MAX_FRAMES
        ));
    }

    let total = total_frames as u8;
    let mut frames = Vec::with_capacity(total_frames);

    for frame_num in 0..total_frames {
        let payload = encode_frame_payload(&data, frame_num as u8, total)?;
        let svg = qr_to_svg(&payload)?;
        frames.push(QrFrame {
            frame_num: frame_num as u8,
            total_frames: total,
            svg,
        });
    }

    Ok(frames)
}

fn qr_to_svg(data: &[u8]) -> Result<String, String> {
    use qrcode::QrCode;

    let code = QrCode::new(data).map_err(|e| format!("QR failed: {:?}", e))?;

    let modules = code.to_colors();
    let size = code.width();
    let border = 2;
    let total = size + border * 2;

    let mut svg = String::with_capacity(total * total * 60);
    let _ = write!(svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {total} {total}\" shape-rendering=\"crispEdges\"><rect width=\"{total}\" height=\"{total}\" fill=\"white\"/>");

    for (i, color) in modules.iter().enumerate() {
        if *color == qrcode::types::Color::Dark {
            let x = (i % size) + border;
            let y = (i / size) + border;
            let _ = write!(
                svg,
                "<rect x=\"{}\" y=\"{}\" width=\"1\" height=\"1\" fill=\"black\"/>",
                x, y
            );
        }
    }

    svg.push_str("</svg>");
    Ok(svg)
}

// ─── Multi-frame decoder ───

thread_local! {
    static DECODER: RefCell<DecoderState> = RefCell::new(DecoderState::new());
}

struct DecoderState {
    kind: u8,
    session: [u8; SESSION_LEN],
    payload_len: u16,
    digest: [u8; DIGEST_LEN],
    total_frames: u8,
    received: [bool; MAX_FRAMES],
    fragments: [Vec<u8>; MAX_FRAMES],
}

impl DecoderState {
    fn new() -> Self {
        Self {
            kind: 0,
            session: [0; SESSION_LEN],
            payload_len: 0,
            digest: [0; DIGEST_LEN],
            total_frames: 0,
            received: [false; MAX_FRAMES],
            fragments: core::array::from_fn(|_| Vec::new()),
        }
    }

    fn reset(&mut self) {
        self.kind = 0;
        self.session = [0; SESSION_LEN];
        self.payload_len = 0;
        self.digest = [0; DIGEST_LEN];
        self.total_frames = 0;
        self.received = [false; MAX_FRAMES];
        for f in &mut self.fragments {
            f.clear();
        }
    }
}

pub fn decode_frame(frame_hex: &str) -> Result<Option<String>, String> {
    let payload = hex::decode(frame_hex).map_err(|e| format!("Invalid hex: {}", e))?;

    if payload.len() < HEADER_LEN {
        return Err("Frame too short".into());
    }

    if payload[..2] != MAGIC {
        return Err("Legacy or unknown multi-frame QR format".into());
    }
    if payload[2] != VERSION {
        return Err(format!("Unsupported QR frame version: {}", payload[2]));
    }
    let kind = payload[3];
    let mut session = [0u8; SESSION_LEN];
    session.copy_from_slice(&payload[4..12]);
    let payload_len = u16::from_be_bytes([payload[12], payload[13]]);
    let mut digest = [0u8; DIGEST_LEN];
    digest.copy_from_slice(&payload[14..30]);
    let frame_num = payload[30] as usize;
    let total = payload[31] as usize;
    let frag_len = payload[32] as usize;

    if total == 0 || total > MAX_FRAMES || frame_num >= total {
        return Err(format!("Invalid frame {}/{}", frame_num, total));
    }
    if payload_len == 0 || payload_len as usize > MAX_FRAMES * MAX_FRAME_DATA {
        return Err("Invalid total payload length".into());
    }
    if frag_len == 0 || frag_len > MAX_FRAME_DATA || payload.len() < HEADER_LEN + frag_len {
        return Err("Payload too short".into());
    }

    let frag_data = &payload[HEADER_LEN..HEADER_LEN + frag_len];

    DECODER.with(|cell| {
        let mut state = cell.borrow_mut();

        if state.total_frames == 0 {
            state.kind = kind;
            state.session = session;
            state.payload_len = payload_len;
            state.digest = digest;
            state.total_frames = total as u8;
        } else if state.kind != kind
            || state.session != session
            || state.payload_len != payload_len
            || state.digest != digest
            || state.total_frames != total as u8
        {
            return Err("QR frame belongs to a different transfer".into());
        }

        if state.received[frame_num] {
            if state.fragments[frame_num].as_slice() != frag_data {
                return Err("Conflicting duplicate QR frame".into());
            }
        } else {
            state.received[frame_num] = true;
            state.fragments[frame_num] = frag_data.to_vec();
        }

        // Check complete
        let all = (0..total).all(|i| state.received[i]);
        if all {
            let mut complete = Vec::new();
            for i in 0..total {
                complete.extend_from_slice(&state.fragments[i]);
            }
            if complete.len() != state.payload_len as usize {
                state.reset();
                return Err("Reassembled QR payload length mismatch".into());
            }
            let computed = Sha256::digest(&complete);
            if computed[..DIGEST_LEN] != state.digest {
                state.reset();
                return Err("Reassembled QR payload hash mismatch".into());
            }
            if payload_kind(&complete) != state.kind {
                state.reset();
                return Err("Reassembled QR payload type mismatch".into());
            }
            state.reset();
            Ok(Some(hex::encode(&complete)))
        } else {
            Ok(None)
        }
    })
}

pub fn reset_decoder() {
    DECODER.with(|cell| {
        cell.borrow_mut().reset();
    });
}

/// Returns "received/total" string, e.g. "3/6" or "0/0" if no frames yet
pub fn decoder_progress() -> String {
    DECODER.with(|cell| {
        let state = cell.borrow();
        let total = state.total_frames as usize;
        if total == 0 {
            return "0/0".into();
        }
        let received = (0..total).filter(|&i| state.received[i]).count();
        let bits: Vec<String> = (0..total)
            .map(|i| {
                if state.received[i] {
                    "1".into()
                } else {
                    "0".into()
                }
            })
            .collect();
        format!(
            "{{\"total\":{},\"count\":{},\"bits\":[{}]}}",
            total,
            received,
            bits.join(",")
        )
    })
}

/// Generate a single QR code SVG from a plain UTF-8 string (no framing, no hex encoding).
/// Used for swap invites and other non-KSPT data exchange.
pub fn generate_svg_from_text(text: &str) -> Result<String, String> {
    qr_to_svg(text.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clear() {
        reset_decoder();
    }

    fn frames(data: &[u8], total: u8) -> Vec<String> {
        (0..total)
            .map(|index| hex::encode(encode_frame_payload(data, index, total).unwrap()))
            .collect()
    }

    #[test]
    fn versioned_frames_reassemble_out_of_order() {
        clear();
        let mut payload = b"KSPT".to_vec();
        payload.extend(0u8..=220);
        let encoded = frames(&payload, 3);
        assert_eq!(decode_frame(&encoded[2]).unwrap(), None);
        assert_eq!(decode_frame(&encoded[0]).unwrap(), None);
        assert_eq!(
            decode_frame(&encoded[1]).unwrap(),
            Some(hex::encode(payload))
        );
    }

    #[test]
    fn duplicate_rules_are_enforced() {
        clear();
        let payload = [b"KSPT".as_slice(), &[7u8; 180]].concat();
        let encoded = frames(&payload, 2);
        assert_eq!(decode_frame(&encoded[0]).unwrap(), None);
        assert_eq!(decode_frame(&encoded[0]).unwrap(), None);
        let mut conflicting = hex::decode(&encoded[0]).unwrap();
        conflicting[HEADER_LEN] ^= 1;
        assert!(decode_frame(&hex::encode(conflicting))
            .unwrap_err()
            .contains("Conflicting duplicate"));
        clear();
    }

    #[test]
    fn different_transfers_cannot_mix() {
        clear();
        let a = [b"KSPT".as_slice(), &[1u8; 180]].concat();
        let b = [b"KSPT".as_slice(), &[2u8; 180]].concat();
        let a_frames = frames(&a, 2);
        let b_frames = frames(&b, 2);
        assert_eq!(decode_frame(&a_frames[0]).unwrap(), None);
        assert!(decode_frame(&b_frames[1])
            .unwrap_err()
            .contains("different transfer"));
        clear();
    }

    #[test]
    fn tampered_payload_and_length_are_rejected() {
        clear();
        let payload = [b"KSPT".as_slice(), &[3u8; 180]].concat();
        let encoded = frames(&payload, 2);
        assert_eq!(decode_frame(&encoded[0]).unwrap(), None);
        let mut tampered = hex::decode(&encoded[1]).unwrap();
        tampered[HEADER_LEN] ^= 1;
        assert!(decode_frame(&hex::encode(tampered))
            .unwrap_err()
            .contains("hash mismatch"));

        clear();
        let new_len = ((payload.len() + 1) as u16).to_be_bytes();
        let mut first = hex::decode(&encoded[0]).unwrap();
        let mut second = hex::decode(&encoded[1]).unwrap();
        first[12..14].copy_from_slice(&new_len);
        second[12..14].copy_from_slice(&new_len);
        assert_eq!(decode_frame(&hex::encode(first)).unwrap(), None);
        assert!(decode_frame(&hex::encode(second))
            .unwrap_err()
            .contains("length mismatch"));
    }

    #[test]
    fn legacy_and_unknown_versions_are_rejected() {
        clear();
        assert!(decode_frame("00020401020304")
            .unwrap_err()
            .contains("too short"));
        let payload = [b"KSPT".as_slice(), &[4u8; 180]].concat();
        let mut frame = hex::decode(&frames(&payload, 2)[0]).unwrap();
        frame[2] = VERSION + 1;
        assert!(decode_frame(&hex::encode(frame))
            .unwrap_err()
            .contains("Unsupported"));
    }
}
