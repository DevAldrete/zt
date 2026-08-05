//! Thin compatibility shim over std.os.linux / std.c for APIs that Zig 0.16.0
//! removed from std.posix. Keeps zt on a familiar ergonomic surface while the
//! stdlib continues churning.
//!
//! All wrappers are `inline` so the codegen is identical to calling the raw
//! syscall/libc entry points directly. Surviving std.posix items are
//! re-exported as aliases to keep call sites uniform.
//!
//! Linux wrappers call std.os.linux.* directly (no libc). macOS wrappers call
//! std.c.* libc functions and map errno through darwin's E enum.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;

// Re-exports (unchanged in 0.16) --------------------------------------------
pub const fd_t = std.posix.fd_t;
pub const pid_t = std.posix.pid_t;
pub const mode_t = std.posix.mode_t;
pub const Kevent = std.posix.Kevent;
pub const timespec = std.posix.timespec;
pub const PROT = std.posix.PROT;
pub const SIG = std.posix.SIG;
pub const E = std.posix.E;
pub const O = std.posix.O;
pub const AF = std.posix.AF;
pub const F = std.posix.F;
pub const SOCK = std.posix.SOCK;
pub const SOL = std.posix.SOL;
pub const sockaddr = std.posix.sockaddr;
pub const iovec = std.posix.iovec;
pub const iovec_const = std.posix.iovec_const;
pub const mmap = std.posix.mmap;
pub const munmap = std.posix.munmap;
pub const read = std.posix.read;
pub const kill = std.posix.kill;
pub const unexpectedErrno = std.posix.unexpectedErrno;

// Missing-in-0.16 shims -----------------------------------------------------
//
// The Zig 0.16 stdlib no longer exposes these APIs on std.posix, so they are
// hand-rolled here. Each wrapper branches on the host OS:
//   Linux   → std.os.linux.* syscall wrappers (no libc)
//   macOS   → std.c.* libc functions, errno mapped via darwin.E
//
// The few wrappers still restricted to Linux (ftruncate, socket, connect)
// are only reachable from the Wayland/X11 backends, which never compile for
// macOS, so their bodies keep a Linux-only @compileError.
//
// Audit against /lib/std/posix.zig @ Zig 0.16.0 (1686 lines):
//   write        — verified absent in 0.16 stdlib; hand-rolled required
//   close        — verified absent in 0.16 stdlib; hand-rolled required
//   pipe/pipe2   — verified absent in 0.16 stdlib; hand-rolled required
//   fork         — verified absent in 0.16 stdlib; hand-rolled required
//   dup2         — verified absent in 0.16 stdlib; hand-rolled required
//   open/openZ   — verified absent in 0.16 stdlib (replaced by openat/openatZ); hand-rolled required
//   fcntl        — verified absent in 0.16 stdlib; hand-rolled required
//   ftruncate    — verified absent in 0.16 stdlib; hand-rolled required
//   socket       — verified absent in 0.16 stdlib; hand-rolled required
//   connect      — verified absent in 0.16 stdlib; hand-rolled required
//   execvpeZ     — verified absent in 0.16 stdlib; hand-rolled required
//   sleep        — verified absent in 0.16 stdlib (std.Thread.sleep also removed); hand-rolled required
//   waitpid      — verified absent in 0.16 stdlib; pty.zig uses raw syscall correctly
const linux_only_msg = "posix shim: this wrapper is Linux-only (macOS has no equivalent backend path)";

// Errno helper: comptime (errno → error) lookup table used by all switch-heavy
// wrappers. Each entry is .{ E tag, anyerror value }. The caller's declared
// return type constrains the visible set; @errorCast bridges anyerror at runtime.
const ErrnoEntry = struct { E, anyerror };

/// Raw syscall/libc result → platform errno enum (linux.E or darwin.E).
inline fn getErrno(rc: anytype) E {
    if (is_linux) return linux.errno(rc);
    return std.c.errno(rc);
}

inline fn mapErrno(e: E, comptime mapping: []const ErrnoEntry) anyerror {
    inline for (mapping) |entry| {
        if (e == entry[0]) return entry[1];
    }
    return std.posix.unexpectedErrno(e);
}

pub const WriteError = error{
    WouldBlock,
    BrokenPipe,
    InputOutput,
    NoSpaceLeft,
    DiskQuota,
    FileTooBig,
    ConnectionResetByPeer,
    Unexpected,
};

const write_map = [_]ErrnoEntry{
    .{ .AGAIN, error.WouldBlock },
    .{ .BADF, error.Unexpected },
    .{ .DESTADDRREQ, error.Unexpected },
    .{ .DQUOT, error.DiskQuota },
    .{ .FAULT, error.Unexpected },
    .{ .FBIG, error.FileTooBig },
    .{ .INVAL, error.Unexpected },
    .{ .IO, error.InputOutput },
    .{ .NOSPC, error.NoSpaceLeft },
    .{ .PERM, error.Unexpected },
    .{ .PIPE, error.BrokenPipe },
    .{ .CONNRESET, error.ConnectionResetByPeer },
};

pub inline fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (is_linux) {
        while (true) {
            const rc = linux.write(fd, bytes.ptr, bytes.len);
            const e = linux.errno(rc);
            if (e == .SUCCESS) return @intCast(rc);
            if (e == .INTR) continue; // retry transparently, std.posix.write semantics
            return @errorCast(mapErrno(e, &write_map));
        }
    }
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        const e = std.c.errno(rc);
        if (e == .SUCCESS) return @intCast(rc);
        if (e == .INTR) continue; // retry transparently
        return @errorCast(mapErrno(e, &write_map));
    }
}

pub inline fn close(fd: fd_t) void {
    if (is_linux) {
        _ = linux.close(fd);
        return;
    }
    _ = std.c.close(fd);
}

pub const PipeError = error{ SystemFdQuotaExceeded, ProcessFdQuotaExceeded, Unexpected };

const pipe_map = [_]ErrnoEntry{
    .{ .MFILE, error.ProcessFdQuotaExceeded },
    .{ .NFILE, error.SystemFdQuotaExceeded },
};

pub inline fn pipe() PipeError![2]fd_t {
    if (is_linux) {
        // Use pipe2(O_CLOEXEC) so the pipe fds are never leaked to a
        // future exec'd child (clipboard helper, etc.).  Previously this
        // called linux.pipe(), which created fds WITHOUT O_CLOEXEC; the
        // callers had to remember to set FD_CLOEXEC by hand, and any
        // early-return path in a forked child would leak the read/write
        // ends into the exec'd program.
        var fds: [2]i32 = undefined;
        const rc = linux.pipe2(&fds, .{ .CLOEXEC = true });
        const e = linux.errno(rc);
        if (e == .SUCCESS) return fds;
        return @errorCast(mapErrno(e, &pipe_map));
    }
    // macOS has no pipe2(2); emulate via pipe(2) + fcntl(F_SETFD, FD_CLOEXEC).
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) < 0) {
        return @errorCast(mapErrno(std.c.errno(-1), &pipe_map));
    }
    const fd_cloexec: c_int = 1; // FD_CLOEXEC
    _ = std.c.fcntl(fds[0], std.c.F.SETFD, fd_cloexec);
    _ = std.c.fcntl(fds[1], std.c.F.SETFD, fd_cloexec);
    return fds;
}

pub inline fn pipe2(flags: O) PipeError![2]fd_t {
    if (is_linux) {
        var fds: [2]i32 = undefined;
        const rc = linux.pipe2(&fds, flags);
        const e = linux.errno(rc);
        if (e == .SUCCESS) return fds;
        return @errorCast(mapErrno(e, &pipe_map));
    }
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) < 0) {
        return @errorCast(mapErrno(std.c.errno(-1), &pipe_map));
    }
    if (flags.CLOEXEC) {
        const fd_cloexec: c_int = 1; // FD_CLOEXEC
        _ = std.c.fcntl(fds[0], std.c.F.SETFD, fd_cloexec);
        _ = std.c.fcntl(fds[1], std.c.F.SETFD, fd_cloexec);
    }
    if (flags.NONBLOCK) {
        const o_nonblock: c_int = @intCast(@as(u32, @bitCast(O{ .NONBLOCK = true })));
        _ = std.c.fcntl(fds[0], std.c.F.SETFL, o_nonblock);
        _ = std.c.fcntl(fds[1], std.c.F.SETFL, o_nonblock);
    }
    return fds;
}

pub const ForkError = error{ SystemResources, Unexpected };

const fork_map = [_]ErrnoEntry{
    .{ .AGAIN, error.SystemResources },
    .{ .NOMEM, error.SystemResources },
};

pub inline fn fork() ForkError!pid_t {
    if (is_linux) {
        const rc = linux.fork();
        const e = linux.errno(rc);
        if (e == .SUCCESS) return @intCast(@as(isize, @bitCast(rc)));
        return @errorCast(mapErrno(e, &fork_map));
    }
    const rc = std.c.fork();
    if (rc < 0) {
        return @errorCast(mapErrno(std.c.errno(-1), &fork_map));
    }
    return @intCast(rc);
}

pub const Dup2Error = error{Unexpected};

pub inline fn dup2(old_fd: fd_t, new_fd: fd_t) Dup2Error!void {
    if (is_linux) {
        const rc = linux.dup2(old_fd, new_fd);
        return switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
    if (std.c.dup2(old_fd, new_fd) < 0) {
        return std.posix.unexpectedErrno(std.c.errno(-1));
    }
}

pub inline fn exit(status: u8) noreturn {
    if (is_linux) {
        linux.exit_group(status);
    } else {
        std.c.exit(status);
    }
}

/// Caller (`main`) must call this once with `init.environ` before any
/// `getenv` invocation. Stored for later lookup since Zig 0.16 no longer
/// exposes a process-wide `std.os.environ`.
pub var environ: std.process.Environ = .empty;

/// Block the current thread for `nanoseconds`. Replacement for
/// `std.Thread.sleep` (removed in Zig 0.16).
pub inline fn sleep(nanoseconds: u64) void {
    if (is_linux) {
        var req: timespec = .{
            .sec = @intCast(nanoseconds / std.time.ns_per_s),
            .nsec = @intCast(nanoseconds % std.time.ns_per_s),
        };
        while (true) {
            const rc = linux.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = false }, &req, &req);
            if (linux.errno(rc) != .INTR) break;
        }
        return;
    }
    var req: timespec = .{
        .sec = @intCast(nanoseconds / std.time.ns_per_s),
        .nsec = @intCast(nanoseconds % std.time.ns_per_s),
    };
    while (true) {
        // rmtp aliases rqtp so an interrupted sleep continues with the
        // remaining time rather than restarting from scratch.
        if (std.c.nanosleep(&req, &req) == 0) break;
        if (std.c.errno(-1) != .INTR) break;
    }
}

/// Monotonic-clock nanoseconds since boot. Replacement for
/// `std.time.nanoTimestamp` (removed in Zig 0.16). Note: 0.15 used REALTIME;
/// MONOTONIC is preferable for the delta-only callers in zt and avoids
/// NTP/DST-jump artefacts.
pub inline fn nanoTimestamp() i128 {
    if (is_linux) {
        var ts: timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
    }
    var ts: timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

pub inline fn getenv(key: []const u8) ?[]const u8 {
    return environ.getPosix(key);
}

pub const ExecveError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    SystemResources,
    InvalidExe,
    FileBusy,
    IsDir,
    SymLinkLoop,
    Unexpected,
};

inline fn execveErrno(rc: anytype) ExecveError {
    return switch (getErrno(rc)) {
        .ACCES => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        .NOEXEC => error.InvalidExe,
        .TXTBSY => error.FileBusy,
        .ISDIR => error.IsDir,
        .LOOP => error.SymLinkLoop,
        else => error.Unexpected,
    };
}

/// Fork + exec replacement for `std.posix.execvpeZ` (removed in 0.16).
/// Mirrors std.posix.execvpeZ semantics: continue PATH walk only on
/// "could be elsewhere" errors (NOENT/NOTDIR/ACCES); preserve the most
/// specific error otherwise so callers see the real failure cause.
pub inline fn execvpeZ(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    const file_slice = std.mem.span(file);
    if (std.mem.indexOfScalar(u8, file_slice, '/') != null) {
        if (is_linux) return execveErrno(linux.execve(file, argv, envp));
        return execveErrno(std.c.execve(file, argv, envp));
    }
    const path = getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path, ':');
    var last_err: ExecveError = error.FileNotFound;
    while (it.next()) |dir| {
        if (dir.len == 0) continue; // skip empty PATH entries (hostile-CWD hardening)
        const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, file_slice }) catch {
            last_err = error.NameTooLong;
            continue;
        };
        const err = if (is_linux)
            execveErrno(linux.execve(full.ptr, argv, envp))
        else
            execveErrno(std.c.execve(full.ptr, argv, envp));
        switch (err) {
            error.FileNotFound, error.NotDir => continue,
            error.AccessDenied => {
                last_err = err;
                continue;
            },
            else => return err,
        }
    }
    return last_err;
}

pub inline fn kqueue() !i32 {
    if (builtin.os.tag == .macos) return @intCast(std.c.kqueue());
    @compileError("kqueue is macOS-only");
}

pub inline fn kevent(
    kq: i32,
    changelist: []const Kevent,
    eventlist: []Kevent,
    timeout: ?*const timespec,
) !usize {
    if (builtin.os.tag == .macos) {
        const rc = std.c.kevent(
            kq,
            changelist.ptr,
            @intCast(changelist.len),
            eventlist.ptr,
            @intCast(eventlist.len),
            timeout,
        );
        if (rc < 0) return error.Unexpected;
        return @intCast(rc);
    }
    @compileError("kevent is macOS-only");
}

pub const OpenError = error{
    FileNotFound,
    AccessDenied,
    IsDir,
    NotDir,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    NameTooLong,
    SystemResources,
    NoSpaceLeft,
    FileTooBig,
    WouldBlock,
    BadPathName,
    Unexpected,
};

const open_map = [_]ErrnoEntry{
    .{ .ACCES, error.AccessDenied },
    .{ .EXIST, error.Unexpected },
    .{ .FBIG, error.FileTooBig },
    .{ .OVERFLOW, error.FileTooBig },
    .{ .ISDIR, error.IsDir },
    .{ .LOOP, error.SymLinkLoop },
    .{ .MFILE, error.ProcessFdQuotaExceeded },
    .{ .NFILE, error.SystemFdQuotaExceeded },
    .{ .NAMETOOLONG, error.NameTooLong },
    .{ .NODEV, error.NoDevice },
    .{ .NOENT, error.FileNotFound },
    .{ .NOMEM, error.SystemResources },
    .{ .NOSPC, error.NoSpaceLeft },
    .{ .NOTDIR, error.NotDir },
    .{ .PERM, error.AccessDenied },
    .{ .AGAIN, error.WouldBlock },
};

pub inline fn open(path: []const u8, flags: O, mode: mode_t) OpenError!fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return openZ(@ptrCast(buf[0..path.len :0]), flags, mode);
}

pub inline fn openZ(path: [*:0]const u8, flags: O, mode: mode_t) OpenError!fd_t {
    if (is_linux) {
        const rc = linux.open(path, flags, mode);
        const e = linux.errno(rc);
        if (e == .SUCCESS) return @intCast(rc);
        return @errorCast(mapErrno(e, &open_map));
    }
    const rc = std.c.open(path, flags, mode);
    const e = std.c.errno(rc);
    if (e == .SUCCESS) return @intCast(rc);
    return @errorCast(mapErrno(e, &open_map));
}

pub const FcntlError = error{ Locked, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, Unexpected };

const fcntl_map = [_]ErrnoEntry{
    .{ .ACCES, error.Locked },
    .{ .AGAIN, error.Locked },
    .{ .MFILE, error.ProcessFdQuotaExceeded },
};

/// Returns the cmd-specific result on success (e.g. `F_GETFL` flags word).
/// Truncates the raw `usize` return to `i32` to match the kernel fcntl ABI
/// and avoid leaking sign-extended errno-encoded values into flag-masking callers.
pub inline fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!i32 {
    if (is_linux) {
        const rc = linux.fcntl(fd, cmd, arg);
        const e = linux.errno(rc);
        if (e == .SUCCESS) return @bitCast(@as(u32, @truncate(rc)));
        return @errorCast(mapErrno(e, &fcntl_map));
    }
    const rc = std.c.fcntl(fd, cmd, arg);
    const e = std.c.errno(rc);
    if (e == .SUCCESS) return rc;
    return @errorCast(mapErrno(e, &fcntl_map));
}

pub const TruncateError = error{ FileTooBig, InputOutput, AccessDenied, Unexpected };

const ftruncate_map = [_]ErrnoEntry{
    .{ .FBIG, error.FileTooBig },
    .{ .IO, error.InputOutput },
    .{ .PERM, error.AccessDenied },
    .{ .ACCES, error.AccessDenied },
};

pub inline fn ftruncate(fd: fd_t, length: u64) TruncateError!void {
    if (builtin.os.tag != .linux) @compileError(linux_only_msg);
    const rc = linux.ftruncate(fd, @intCast(length));
    const e = linux.errno(rc);
    if (e == .SUCCESS) return;
    return @errorCast(mapErrno(e, &ftruncate_map));
}

pub const SocketError = error{
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    PermissionDenied,
    Unexpected,
};

const socket_map = [_]ErrnoEntry{
    .{ .AFNOSUPPORT, error.AddressFamilyNotSupported },
    .{ .MFILE, error.ProcessFdQuotaExceeded },
    .{ .NFILE, error.SystemFdQuotaExceeded },
    .{ .NOBUFS, error.SystemResources },
    .{ .NOMEM, error.SystemResources },
    .{ .PROTONOSUPPORT, error.ProtocolNotSupported },
    .{ .PROTOTYPE, error.SocketTypeNotSupported },
    .{ .ACCES, error.PermissionDenied },
};

pub inline fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!fd_t {
    if (builtin.os.tag != .linux) @compileError(linux_only_msg);
    const rc = linux.socket(domain, socket_type, protocol);
    const e = linux.errno(rc);
    if (e == .SUCCESS) return @intCast(rc);
    return @errorCast(mapErrno(e, &socket_map));
}

pub const ConnectError = error{
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    AlreadyConnected,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NetworkUnreachable,
    FileNotFound,
    WouldBlock,
    Unexpected,
};

const connect_map = [_]ErrnoEntry{
    .{ .ACCES, error.PermissionDenied },
    .{ .PERM, error.PermissionDenied },
    .{ .ADDRINUSE, error.AddressInUse },
    .{ .ADDRNOTAVAIL, error.AddressNotAvailable },
    .{ .AFNOSUPPORT, error.AddressFamilyNotSupported },
    .{ .ISCONN, error.AlreadyConnected },
    .{ .CONNREFUSED, error.ConnectionRefused },
    .{ .CONNRESET, error.ConnectionResetByPeer },
    .{ .TIMEDOUT, error.ConnectionTimedOut },
    .{ .NETUNREACH, error.NetworkUnreachable },
    .{ .NOENT, error.FileNotFound },
    .{ .AGAIN, error.WouldBlock },
    .{ .INPROGRESS, error.WouldBlock },
};

pub inline fn connect(sockfd: fd_t, sock_addr: *const anyopaque, len: u32) ConnectError!void {
    if (builtin.os.tag != .linux) @compileError(linux_only_msg);
    const rc = linux.connect(sockfd, sock_addr, len);
    const e = linux.errno(rc);
    if (e == .SUCCESS) return;
    return @errorCast(mapErrno(e, &connect_map));
}
