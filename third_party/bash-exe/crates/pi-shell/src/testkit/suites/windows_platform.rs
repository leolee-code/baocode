//! The shell on a Windows engine (`EngineConfig::platform`), run on any
//! host: what `omp zsh` and the bash tool show a Windows user.

use bstr::BString;

use crate::{
	bash::{EngineConfig, ModeId, Platform, Script, ShellInit},
	testkit::{FakeHost, Fault, MemFs, Rig},
};

/// Run `src` as zsh on a Windows engine with `env`; stdout and stderr.
fn zsh_on_windows(env: &[(&str, &str)], src: &str) -> (String, String) {
	let init = ShellInit {
		mode: ModeId::Zsh,
		argv0: "zsh".into(),
		env: env
			.iter()
			.map(|(k, v)| (BString::from(*k), BString::from(*v)))
			.collect(),
		..ShellInit::default()
	};
	let cfg = EngineConfig { platform: Platform::Windows, ..EngineConfig::default() };
	let mut rig = Rig::with_config(FakeHost::new(), init, cfg);
	rig.run(Script::command(src.as_bytes().to_vec()), Fault::None);
	(
		String::from_utf8_lossy(&rig.host.stdout.bytes()).into_owned(),
		String::from_utf8_lossy(&rig.host.stderr.bytes()).into_owned(),
	)
}

/// Windows paths hold `:` (`C:\…`): `$path` splits `PATH` on `;`, and an
/// assignment to `path` joins with `;`, the separator child programs read.
/// Split on `:`, `${path[1]}` was `C`.
#[test]
fn path_tie_uses_the_windows_separator() {
	let (out, err) = zsh_on_windows(
		&[("PATH", "C:\\Windows;C:\\Program Files\\Git\\cmd")],
		"print -rl -- ${#path} ${path[1]}; path+=('D:\\tools'); print -r -- $PATH",
	);
	assert_eq!(out, "2\nC:\\Windows\nC:\\Windows;C:\\Program Files\\Git\\cmd;D:\\tools\n");
	assert_eq!(err, "");
}

/// Without an imported `PATH`, zsh's default list uses the Windows
/// separator too, so the tie sees its four directories.
#[test]
fn default_path_splits_into_its_directories() {
	let (out, _) = zsh_on_windows(&[], "print -r -- ${#path} ${path[1]}");
	assert_eq!(out, "4 /bin\n");
}

/// zsh on Windows reports MSYS2's `OSTYPE` (plugins branch on
/// `[[ $OSTYPE == msys* ]]`), not `linux-gnu`.
#[test]
fn ostype_is_msys() {
	let (out, _) = zsh_on_windows(&[], "print -r -- $OSTYPE");
	assert_eq!(out, "msys\n");
}

/// `PWD` and `HOME` start in the `/` spelling `cd` keeps, so `~`, `%~`
/// and `:t` agree with them from the first prompt, and `"$PWD/x"` stays
/// one spelling that Windows programs read too.
#[test]
fn pwd_and_home_start_with_slashes() {
	let start = |mode, src: &str| {
		let init = ShellInit {
			mode,
			argv0: if mode == ModeId::Zsh { "zsh" } else { "bash" }.into(),
			env: vec![(BString::from("HOME"), BString::from(r"C:\Users\b"))],
			cwd: BString::from(r"\\?\C:\Users\b\src"),
			..ShellInit::default()
		};
		let cfg = EngineConfig { platform: Platform::Windows, ..EngineConfig::default() };
		let mut rig = Rig::with_config(FakeHost::new(), init, cfg);
		rig.run(Script::command(src.as_bytes().to_vec()), Fault::None);
		String::from_utf8_lossy(&rig.host.stdout.bytes()).into_owned()
	};
	assert_eq!(
		start(ModeId::Zsh, "print -r -- $PWD $HOME ${PWD:t} ${(D)PWD}"),
		"C:/Users/b/src C:/Users/b src ~/src\n"
	);
	assert_eq!(
		start(ModeId::Bash, "echo $PWD $HOME ~ \"$PWD/x\" ${PWD##*/}; pwd"),
		"C:/Users/b/src C:/Users/b C:/Users/b C:/Users/b/src/x src\nC:/Users/b/src\n"
	);
}

/// A Windows `PATH` takes an entry added the POSIX way
/// (`PATH="$PATH:/dir"`), as Git Bash's does.
#[test]
fn path_takes_colon_appended_entries() {
	let fs = MemFs::new();
	fs.add_file("/tools/hello", b"#!/bin/sh\n", 0o755);
	let init = ShellInit {
		mode: ModeId::Bash,
		argv0: "bash".into(),
		env: vec![(BString::from("PATH"), BString::from(r"C:\Windows;C:\bin"))],
		..ShellInit::default()
	};
	let cfg = EngineConfig { platform: Platform::Windows, ..EngineConfig::default() };
	let mut rig = Rig::with_config(FakeHost::new().with_fs(fs), init, cfg);
	rig.run(
		Script::command(b"PATH=\"$PATH:/tools\"; command -v hello; type -t hello".to_vec()),
		Fault::None,
	);
	assert_eq!(String::from_utf8_lossy(&rig.host.stdout.bytes()), "/tools/hello\nfile\n");
}

/// Windows always exports `USERNAME`; reading it in zsh printed a lossy
/// emulation-mode-boundary warning ("bash variable … shadowed by the zsh
/// special") on every run.
#[test]
fn an_imported_username_is_no_lossy_crossing() {
	let (out, err) = zsh_on_windows(&[("USERNAME", "b")], "print -r -- ${+USERNAME}");
	assert_eq!(out, "1\n");
	assert_eq!(err, "");
}

/// Run `src` in `mode` on a `platform` engine; stdout.
fn run_on(mode: ModeId, platform: Platform, src: &str) -> String {
	let argv0 = if mode == ModeId::Zsh { "zsh" } else { "bash" };
	let init = ShellInit { mode, argv0: argv0.into(), ..ShellInit::default() };
	let cfg = EngineConfig { platform, ..EngineConfig::default() };
	let mut rig = Rig::with_config(FakeHost::new(), init, cfg);
	rig.run(Script::command(src.as_bytes().to_vec()), Fault::None);
	String::from_utf8_lossy(&rig.host.stdout.bytes()).into_owned()
}

/// On Windows an asynchronous command without job control ignores `INT`
/// (and in zsh `QUIT`), as zsh and bash have it, so the console's Ctrl-C
/// passes it by: it lists the ignore, zsh's may trap it, bash's (ignored
/// on entry) may not, and the shell's own traps stay unset. Elsewhere it
/// keeps the shell's dispositions.
#[test]
fn async_commands_ignore_interrupts_on_windows_only() {
	let zsh =
		"( trap; trap 'print own' INT; trap ) & wait; print -r -- $(< <(trap)); trap; print done";
	let bash = "( trap; trap 'echo own' INT; trap -p INT ) & wait; trap -p INT; echo done";
	assert_eq!(
		run_on(ModeId::Zsh, Platform::Windows, zsh),
		"trap -- '' INT\ntrap -- '' QUIT\ntrap -- 'print own' INT\ntrap -- '' QUIT\ntrap -- '' INT \
		 trap -- '' QUIT\ndone\n"
	);
	assert_eq!(
		run_on(ModeId::Bash, Platform::Windows, bash),
		"trap -- '' SIGINT\ntrap -- '' SIGINT\ndone\n"
	);
	assert_eq!(run_on(ModeId::Zsh, Platform::Linux, zsh), "trap -- 'print own' INT\n\ndone\n");
	assert_eq!(run_on(ModeId::Bash, Platform::Linux, bash), "trap -- 'echo own' SIGINT\ndone\n");
}

/// Asynchronous commands forked from the same state share its ignores; one
/// forked after the shell set a trap lists it beside the ignore.
#[test]
fn async_commands_list_traps_set_between_them_on_windows() {
	let bash = "( trap -p ) & wait; trap 'echo t' TERM; ( trap -p ) & wait; echo done";
	assert_eq!(
		run_on(ModeId::Bash, Platform::Windows, bash),
		"trap -- '' SIGINT\ntrap -- '' SIGINT\ntrap -- 'echo t' SIGTERM\ndone\n"
	);
}

/// Windows has no `/bin` or `/usr/bin`: those paths name the command
/// (`/usr/bin/env`, `/bin/bash`); a nested shell keeps the path as `$0`.
#[test]
fn unix_bin_paths_name_the_command_on_windows() {
	let src =
		"/bin/bash -c 'echo $0 ok'; /usr/bin/echo hi; /usr/local/bin/sh -c 'echo $0'; /bin/x/echo no";
	assert_eq!(
		run_on(ModeId::Bash, Platform::Windows, src),
		"/bin/bash ok\nhi\n/usr/local/bin/sh\n"
	);
}

/// Git Bash's `pwd -W`: the directory as Windows spells it.
#[test]
fn pwd_w_prints_the_windows_spelling() {
	for (cwd, want) in [(r"C:\Users\b\src", "C:/Users/b/src\n"), ("/d/work", "D:/work\n")] {
		let init = ShellInit {
			mode: ModeId::Bash,
			argv0: "bash".into(),
			cwd: BString::from(cwd),
			..ShellInit::default()
		};
		let cfg = EngineConfig { platform: Platform::Windows, ..EngineConfig::default() };
		let mut rig = Rig::with_config(FakeHost::new(), init, cfg);
		rig.run(Script::command(b"pwd -W".to_vec()), Fault::None);
		assert_eq!(String::from_utf8_lossy(&rig.host.stdout.bytes()), want);
	}
	assert_eq!(run_on(ModeId::Bash, Platform::Linux, "pwd -W || echo no"), "no\n");
}

/// `exec bash` and `exec env …` find this shell and the built-in tools, as
/// Git Bash's `exec` finds its `/usr/bin`, not `PATH`'s `bash` (WSL's); the
/// shell still ends with the command.
#[test]
fn exec_finds_this_shell_on_windows() {
	assert_eq!(
		run_on(ModeId::Bash, Platform::Windows, "(exec bash -c 'echo in $0'; echo after); echo $?"),
		"in bash\n0\n"
	);
	assert_eq!(run_on(ModeId::Bash, Platform::Windows, "(exec sh -c 'exit 3'); echo $?"), "3\n");
	// Elsewhere `exec` takes `PATH`'s programs only, as bash's does.
	assert_eq!(run_on(ModeId::Bash, Platform::Linux, "(exec bash -c 'echo in'); echo $?"), "127\n");
}
