use std::ffi::{c_char, c_int, c_uchar, c_uint};
use std::io;
use std::os::fd::RawFd;

pub const LISTEN_FDS_START: RawFd = 3;

#[repr(C)]
pub struct sd_id128_t {
    pub bytes: [u8; 16],
}

pub unsafe fn sd_journal_stream_fd(
    identifier: *const c_uchar,
    priority: c_int,
    level_prefix: c_int,
) -> c_int {
    let _ = identifier;
    let _ = priority;
    let _ = level_prefix;
    unsafe { libc::dup(2) }
}

pub unsafe fn sd_notify(unset_environment: c_int, state: *const c_char) -> c_int {
    let _ = unset_environment;
    let _ = state;
    0
}

pub unsafe fn sd_notify_barrier(unset_environment: c_int, timeout: u64) -> c_int {
    let _ = unset_environment;
    let _ = timeout;
    0
}

pub unsafe fn sd_pid_notify_with_fds(
    pid: libc::pid_t,
    unset_environment: c_int,
    state: *const c_char,
    fds: *const c_int,
    n_fds: c_uint,
) -> c_int {
    let _ = pid;
    let _ = unset_environment;
    let _ = state;
    let _ = fds;
    let _ = n_fds;
    0
}

pub unsafe fn sd_listen_fds_with_names(
    unset_environment: c_int,
    names: *mut *mut *mut c_char,
) -> c_int {
    let _ = unset_environment;
    if !names.is_null() {
        unsafe { *names = std::ptr::null::<*mut *mut c_char>() as *mut *mut c_char };
    }
    0
}

pub unsafe fn sd_id128_get_machine_app_specific(
    app_id: sd_id128_t,
    ret: *mut sd_id128_t,
) -> c_int {
    use crate::sha256;

    // Same derivation as libsystemd: HMAC-SHA256 keyed with the 16 machine-id bytes over the app id.
    let machine_id = match read_machine_id() {
        Ok(id) => id,
        Err(err) => return err,
    };
    let digest = sha256::hmac_sha256(&machine_id, &app_id.bytes);
    let mut result = [0u8; 16];
    for i in 0..16 {
        result[i] = digest[i];
    }
    result[6] = (result[6] & 0x0f) | 0x40;
    result[8] = (result[8] & 0x3f) | 0x80;

    if ret.is_null() {
        return -libc::EINVAL;
    }
    unsafe { (*ret).bytes = result };
    0
}

/// The machine id as 16 bytes, decoded from the 32 hex characters in /etc/machine-id
/// (or /var/lib/dbus/machine-id). Errors are negative errno values, as libsystemd returns.
fn read_machine_id() -> Result<[u8; 16], c_int> {
    let text = std::fs::read_to_string("/etc/machine-id")
        .or_else(|_| std::fs::read_to_string("/var/lib/dbus/machine-id"))
        .map_err(|_| -libc::ENOENT)?;
    parse_machine_id(text.trim()).ok_or(-libc::EINVAL)
}

fn parse_machine_id(hex: &str) -> Option<[u8; 16]> {
    if hex.len() != 32 {
        return None;
    }
    let mut id = [0u8; 16];
    for (i, byte) in id.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(id)
}

#[test]
fn test_parse_machine_id() {
    let id = parse_machine_id("0123456789abcdef0123456789ABCDEF").unwrap();
    assert_eq!(id[0], 0x01);
    assert_eq!(id[15], 0xef);
    assert!(parse_machine_id("0123").is_none());
    assert!(parse_machine_id("zz23456789abcdef0123456789abcdef").is_none());
}

pub fn check_call(ret: c_int) -> Result<c_int, io::Error> {
    if ret < 0 {
        Err(io::Error::from_raw_os_error(-ret))
    } else {
        Ok(ret)
    }
}
