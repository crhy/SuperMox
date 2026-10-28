const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const H0: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

fn big_sigma0(x: u32) -> u32 { x.rotate_left(30) ^ x.rotate_left(19) ^ x.rotate_left(10) }
fn big_sigma1(x: u32) -> u32 { x.rotate_left(26) ^ x.rotate_left(21) ^ x.rotate_left(7) }
fn small_sigma0(x: u32) -> u32 { x.rotate_left(25) ^ x.rotate_left(14) ^ (x >> 3) }
fn small_sigma1(x: u32) -> u32 { x.rotate_left(15) ^ x.rotate_left(13) ^ (x >> 10) }
fn ch(x: u32, y: u32, z: u32) -> u32 { (x & y) ^ (!x & z) }
fn maj(x: u32, y: u32, z: u32) -> u32 { (x & y) ^ (x & z) ^ (y & z) }

fn compress(h: [u32; 8], block: &[u8]) -> [u32; 8] {
    assert!(block.len() == 64);
    let mut a = h[0];
    let mut b = h[1];
    let mut c = h[2];
    let mut d = h[3];
    let mut e = h[4];
    let mut f = h[5];
    let mut g = h[6];
    let mut hh = h[7];

    let mut x = [0u32; 16];
    for i in 0..16 {
        x[i] = (u32::from(block[i * 4]) << 24)
            | (u32::from(block[i * 4 + 1]) << 16)
            | (u32::from(block[i * 4 + 2]) << 8)
            | u32::from(block[i * 4 + 3]);
    }

    for i in 0..16 {
        let t1 = x[i]
            .wrapping_add(hh)
            .wrapping_add(big_sigma1(e))
            .wrapping_add(ch(e, f, g))
            .wrapping_add(K[i]);
        let t2 = big_sigma0(a).wrapping_add(maj(a, b, c));
        hh = g;
        g = f;
        f = e;
        e = d.wrapping_add(t1);
        d = c;
        c = b;
        b = a;
        a = t1.wrapping_add(t2);
    }

    for i in 16..64 {
        let s0 = small_sigma0(x[(i + 1) & 0xf]);
        let s1 = small_sigma1(x[(i + 14) & 0xf]);
        x[i & 0xf] = x[i & 0xf]
            .wrapping_add(s0)
            .wrapping_add(s1)
            .wrapping_add(x[(i + 9) & 0xf]);
        let t1 = x[i & 0xf]
            .wrapping_add(hh)
            .wrapping_add(big_sigma1(e))
            .wrapping_add(ch(e, f, g))
            .wrapping_add(K[i]);
        let t2 = big_sigma0(a).wrapping_add(maj(a, b, c));
        hh = g;
        g = f;
        f = e;
        e = d.wrapping_add(t1);
        d = c;
        c = b;
        b = a;
        a = t1.wrapping_add(t2);
    }

    [
        h[0].wrapping_add(a),
        h[1].wrapping_add(b),
        h[2].wrapping_add(c),
        h[3].wrapping_add(d),
        h[4].wrapping_add(e),
        h[5].wrapping_add(f),
        h[6].wrapping_add(g),
        h[7].wrapping_add(hh),
    ]
}

pub fn sha256(msg: &[u8]) -> [u8; 32] {
    let mut h = H0;
    let ml = (msg.len() as u64) * 8;
    let mut data = msg.to_vec();
    data.push(0x80);
    while data.len() % 64 != 56 {
        data.push(0);
    }
    data.extend(ml.to_be_bytes());

    let mut i = 0;
    while i < data.len() {
        h = compress(h, &data[i..i + 64]);
        i += 64;
    }

    let mut out = [0u8; 32];
    for j in 0..8 {
        out[j * 4] = (h[j] >> 24) as u8;
        out[j * 4 + 1] = (h[j] >> 16) as u8;
        out[j * 4 + 2] = (h[j] >> 8) as u8;
        out[j * 4 + 3] = h[j] as u8;
    }
    out
}

/// HMAC-SHA256 (RFC 2104) with a key of any length.
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        k[..32].copy_from_slice(&sha256(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }

    let mut inner_data: Vec<u8> = k.iter().map(|b| b ^ 0x36).collect();
    inner_data.extend_from_slice(msg);
    let inner = sha256(&inner_data);

    let mut outer_data: Vec<u8> = k.iter().map(|b| b ^ 0x5c).collect();
    outer_data.extend_from_slice(&inner);
    sha256(&outer_data)
}

#[test]
fn test_sha256_abc() {
    let digest = sha256(b"abc");
    let hex = digest.iter().map(|b| format!("{:02x}", *b)).collect::<Vec<String>>().join("");
    assert_eq!(
        hex,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
}

#[test]
fn test_sha256_empty() {
    let digest = sha256(b"");
    let hex = digest.iter().map(|b| format!("{:02x}", *b)).collect::<Vec<String>>().join("");
    assert_eq!(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
}

#[test]
fn test_hmac_rfc4231_case2() {
    let digest = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
    let hex = digest.iter().map(|b| format!("{:02x}", *b)).collect::<Vec<String>>().join("");
    assert_eq!(hex, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
}
