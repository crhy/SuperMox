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
    libc::dup(2)
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
        *names = std::ptr::null();
    }
    0
}

pub unsafe fn sd_id128_get_machine_app_specific(
    app_id: sd_id128_t,
    ret: *mut sd_id128_t,
) -> c_int {
    use crate::sha256;

    let machine_id_raw = match std::fs::read("/etc/machine-id") {
        Err(_) => return -libc::ENOENT,
        Ok(v) => v,
    };
    let machine_id = trim_ascii_ws(machine_id_raw);
    if machine_id.is_empty() {
        return -libc::ENOENT;
    }

    let digest = sha256::hmac_sha256(app_id.bytes, machine_id);
    let mut result = [0u8; 16];
    for i in 0..16 {
        result[i] = digest[i];
    }
    result[6] = (result[6] & 0x0f) | 0x40;
    result[8] = (result[8] & 0x3f) | 0x80;

    if ret.is_null() {
        return -libc::EINVAL;
    }
    (*ret).bytes = result;
    0
}

fn trim_ascii_ws(data: Vec<u8>) -> Vec<u8> {
    let is_ws = |b: u8| -> bool { b == b' ' || b == b'\t' || b == b'\n' || b == b'\r' };
    let start = data.iter().take_while(|b| is_ws(*b)).count();
    let end = data.iter().rev().take_while(|b| is_ws(*b)).count();
    data[start..data.len() - end].to_vec();
}

pub fn check_call(ret: c_int) -> Result<c_int, io::Error> {
    if ret < 0 {
        Err(io::Error::from_raw_os_error(-ret))
    } else {
        Ok(ret)
    }
}
