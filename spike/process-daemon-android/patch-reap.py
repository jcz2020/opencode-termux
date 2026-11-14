#!/usr/bin/env python3
"""给 process-daemon 打「安全回收 pipe 僵尸」补丁。

用法：patch-reap.py <packages/process-daemon 目录>

背景（改之前先读）：
  upstream 故意让 pipe 子进程在退出后保持僵尸，直到 `terminate`/eviction 才
  `reap`。目的是保留 PID 与进程组 ID，使之后对残留子孙进程的 `killpg` 不会
  误伤无关进程。问题在于：普通命令结束后没人 terminate，僵尸就常驻——
  opencode 侧 `EXITED_LIMIT = 25`，于是长会话稳定有 25 个 Z。

  `kill(-pgid, 0)` 不能作为「组已空」的判据：Linux/Android 上即使组内只剩僵尸
  它也返回 0（macOS 才返回 ESRCH）。所以这里在 Linux 上扫 `/proc` 找非僵尸组员，
  扫不到（读不了 /proc）就不 reap，保守优先。

  只在「退出消息已发出 + 组内没有活成员」时 reap：退出码、Exited 事件、输出文件、
  registry 全部不变；`cmd &` 这类故意留后台进程的场景仍保留僵尸，留给 eviction。

所有替换都是语义锚点 + 幂等；锚点漂移只告警，最终由构建门禁兜底。
"""
import pathlib
import sys

warnings = []


def warn(message):
    warnings.append(message)
    print(f"   WARN: {message}")


def patch(path, marker, edits, label):
    if not path.exists():
        warn(f"{path.name} 不存在，跳过 {label}")
        return
    text = path.read_text()
    if marker in text:
        print(f"   already patched {label}")
        return
    done = 0
    for old, new in edits:
        if old not in text:
            warn(f"{label}: 锚点未匹配（{old.strip().splitlines()[0][:70]}…）")
            continue
        text = text.replace(old, new, 1)
        done += 1
    if done:
        path.write_text(text)
        print(f"   patched {label} ({done}/{len(edits)} 处)")


ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
UNIX = ROOT / "src/service/pipe/unix.rs"
WINDOWS = ROOT / "src/service/pipe/windows.rs"
PIPE = ROOT / "src/service/pipe.rs"

if not UNIX.exists() or not PIPE.exists():
    sys.exit(f"ERROR: {ROOT} 不像 process-daemon 源码目录")

# ── 1. unix.rs：安全 reap ───────────────────────────────────────────────
METHODS = '''        *reaped = true;
    }

    /// Reaps the exited child once its process group has no live members.
    ///
    /// The zombie keeps the PID and process-group ID reserved so a later
    /// `killpg` can never hit an unrelated process. Once every member is gone
    /// there is nothing left to signal, so the reservation protects nothing.
    /// A group with live members keeps the zombie: the client may still kill
    /// the leftovers when it evicts or terminates the process.
    pub(super) fn reap_when_group_empty(&self) {
        let deadline = Instant::now() + REAP_WINDOW;
        loop {
            match group_has_live_members(self.pid) {
                // Reap only when we could actually prove the group is empty.
                Some(false) => {
                    self.reap();
                    return;
                }
                // Live leftovers, or a platform we cannot inspect: keep it.
                _ => {}
            }
            if Instant::now() >= deadline {
                return;
            }
            std::thread::sleep(REAP_POLL);
        }
    }
}
'''

HELPERS = '''/// How long an exited pipe child may keep its zombie while its group still has
/// live members, and how often that is re-checked.
const REAP_WINDOW: Duration = Duration::from_secs(2);
const REAP_POLL: Duration = Duration::from_millis(100);

/// Whether `group` still has a live (non-zombie) member other than the exited
/// child itself. `None` means the platform could not tell and callers must keep
/// the zombie.
#[cfg(target_os = "linux")]
fn group_has_live_members(group: u32) -> Option<bool> {
    let Ok(pid) = i32::try_from(group) else {
        return None;
    };
    let entries = std::fs::read_dir("/proc").ok()?;
    let mut scanned = false;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(member) = name.to_str().and_then(|value| value.parse::<i32>().ok()) else {
            continue;
        };
        // A member that exits between readdir and read leaves no stat file.
        let Ok(stat) = std::fs::read_to_string(entry.path().join("stat")) else {
            continue;
        };
        scanned = true;
        let Some((state, pgrp)) = parse_stat(&stat) else {
            continue;
        };
        if pgrp == pid && member != pid && state != 'Z' {
            return Some(true);
        }
    }
    // An unreadable /proc must not look like an empty group.
    if scanned { Some(false) } else { None }
}

/// macOS has no `/proc`, but its `killpg(pid, 0)` reports `ESRCH` for a group
/// that only holds zombies (the opposite of Linux), so it is a valid test.
#[cfg(not(target_os = "linux"))]
fn group_has_live_members(group: u32) -> Option<bool> {
    let Ok(pid) = i32::try_from(group) else {
        return None;
    };
    // SAFETY: signal 0 performs the permission/existence check only.
    let result = unsafe { libc::killpg(pid, 0) };
    if result == 0 {
        return Some(true);
    }
    match Errno::last() {
        Errno::ESRCH => Some(false),
        _ => None,
    }
}

/// Reads state and process-group id from `/proc/<pid>/stat`. The comm field can
/// contain spaces and parentheses, so split at the last `)`.
#[cfg(target_os = "linux")]
fn parse_stat(stat: &str) -> Option<(char, i32)> {
    let rest = stat.get(stat.rfind(')')? + 1..)?;
    let mut fields = rest.split_whitespace();
    let state = fields.next()?.chars().next()?;
    let _ppid = fields.next()?;
    let pgrp = fields.next()?.parse().ok()?;
    Some((state, pgrp))
}

'''

TESTS = '''
#[cfg(all(test, target_os = "linux"))]
mod reap_tests {
    use super::*;
    use std::os::unix::process::CommandExt;
    use std::process::Command;

    fn spawn_child(script: &str) -> Process {
        let child = Command::new("/bin/sh")
            .arg("-c")
            .arg(script)
            .process_group(0)
            .spawn()
            .expect("spawn test child");
        let pid = child.id();
        // Dropping `Child` neither waits nor kills; the daemon owns reaping.
        drop(child);
        Process {
            pid,
            reaped: Mutex::new(false),
        }
    }

    fn wait_without_reaping(pid: u32) -> Exit {
        wait_exit(pid).expect("wait for test child")
    }

    fn state_of(pid: u32) -> Option<char> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        parse_stat(&stat).map(|(state, _)| state)
    }

    fn exists(pid: u32) -> bool {
        std::path::Path::new(&format!("/proc/{pid}")).exists()
    }

    #[test]
    fn reaps_an_exited_child_whose_group_is_empty() {
        let process = spawn_child("true");
        wait_without_reaping(process.pid());
        assert_eq!(state_of(process.pid()), Some('Z'));
        process.reap_when_group_empty();
        assert!(!exists(process.pid()), "the zombie must be gone");
    }

    #[test]
    fn keeps_the_zombie_while_the_group_still_has_members() {
        let process = spawn_child("sleep 5 & exit 0");
        wait_without_reaping(process.pid());
        // Polls for REAP_WINDOW, but a live `sleep` in the group must stop it.
        process.reap_when_group_empty();
        assert_eq!(state_of(process.pid()), Some('Z'), "a live member needs the group reserved");
        process.kill();
        process.reap();
        assert!(!exists(process.pid()), "explicit kill + reap must still work");
    }

    #[test]
    fn an_unknown_group_state_keeps_the_zombie() {
        // A pid that is not a child can be observed but never reaped; the
        // conservative branch must leave it alone rather than block.
        assert_eq!(group_has_live_members(u32::MAX), None);
    }
}
'''

patch(
    UNIX,
    "reap_when_group_empty",
    [
        ("use std::time::Instant;", "use std::time::{Duration, Instant};"),
        (
            "use crate::service::{CreatePipe, ProcessSignal, TerminalHandle, TerminalId};",
            "use crate::service::{CreatePipe, ProcessSignal, TerminalHandle, TerminalId};\n\n" + HELPERS.rstrip(),
        ),
        (
            "        *reaped = true;\n    }\n}\n",
            METHODS,
        ),
    ],
    "unix.rs",
)

# 测试模块单独追加
if '#[cfg(all(test, target_os = "linux"))]\nmod reap_tests' not in UNIX.read_text():
    UNIX.write_text(UNIX.read_text() + TESTS)
    print("   appended reap_tests to unix.rs")

# ── 2. windows.rs：Windows 没有僵尸，保持空实现 ─────────────────────────
patch(
    WINDOWS,
    "reap_when_group_empty",
    [
        (
            """    pub(super) fn reap(&self) {
        self.lock().handles.take();
    }""",
            """    pub(super) fn reap(&self) {
        self.lock().handles.take();
    }

    /// Windows has no zombies: an exited process keeps nothing reserved, and
    /// the handle is closed by `reap` at shutdown. Nothing to do.
    pub(super) fn reap_when_group_empty(&self) {}""",
        )
    ],
    "windows.rs",
)

# ── 3. pipe.rs：waiter 在报到退出后尝试安全回收 ─────────────────────────
patch(
    PIPE,
    "reap_after_exit",
    [
        (
            """    let wait_actor_tx = actor_tx.clone();
    let waiter = thread::Builder::new()
        .name(format!("opencode-pty-wait-{id}"))
        .spawn(move || {
            let Waiter { exit, after } = waiter();
            let _ = wait_actor_tx.send(exit_message(exit));
            drop(after);
        })""",
            """    let wait_actor_tx = actor_tx.clone();
    let reap_after_exit = Arc::clone(&process);
    let waiter = thread::Builder::new()
        .name(format!("opencode-pty-wait-{id}"))
        .spawn(move || {
            let Waiter { exit, after } = waiter();
            let _ = wait_actor_tx.send(exit_message(exit));
            drop(after);
            // The exit status is already reported, so the zombie's only job is
            // keeping the process group reserved for signalling. With every
            // member gone there is nothing left to signal, and the PID can be
            // released; groups with live members keep the zombie for eviction.
            reap_after_exit.reap_when_group_empty();
        })""",
        )
    ],
    "pipe.rs",
)

print("process-daemon 僵尸回收补丁完成" + (f"（{len(warnings)} 个锚点告警）" if warnings else ""))
