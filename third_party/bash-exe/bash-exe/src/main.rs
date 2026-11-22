//! BaoCode Bash (`bash.exe`): pi-shell's bash 5.3 for Windows, where an
//! agent's commands otherwise meet neither a bash nor the Unix tools it
//! expects.
//!
//! `bash -c COMMAND [NAME [ARGS]]`, what an agent's shell tool runs, runs
//! COMMAND as omp's bash tool does ([`pi_shell::execute_shell_stdio`]): the
//! GNU-style utilities built in (`rg`, `grep`, `sed`, `awk`, `find`, `xargs`,
//! `jq`, `tar`, …) ahead of `PATH`; a command line written for the Windows
//! program one of them shadows (`find /c "x"`, `sort /r`) going to that
//! program; `/c/…` and `C:\…` alike; Windows programs given paths as Git
//! Bash gives them and writing UTF-8 ([`prepare_windows`]). Its fds 0, 1 and
//! 2 are the process's own. `-e`, `-u`, `-x` and `-l` may come with `-c`;
//! the last does nothing, there being no profile to read.
//!
//! A script (`bash [OPTION]… script.sh [ARGS]`) or a `-c` with options of
//! its own (`-o pipefail`) runs the same way, as `bash ARGS…` there: a shell
//! the engine starts, with the utilities ahead of `PATH` as well, where a
//! process shell would find System32's `sort` and Git's `xargs` first.
//!
//! Anything else (commands on stdin, an interactive shell, `--version`) is
//! the engine as a process shell, the utilities standing in for the commands
//! `PATH` lacks; `--version` ends with this build's.

use std::{env, ffi::OsString, fs, io::Write as _, process::ExitCode};

use bstr::BString;
use pi_shell::{
	ShellExecuteOptions,
	cancel::{AbortReason, CancelToken},
	execute_shell_stdio,
	process::{self, ProcessOptions},
};

fn main() -> ExitCode {
	let args: Vec<OsString> = env::args_os().collect();
	#[cfg(windows)]
	{
		if pi_shell::sys::set_console_code_page_if_asked(&args) {
			return ExitCode::SUCCESS;
		}
		prepare_windows();
	}
	let rest = args.get(1..).unwrap_or_default();
	let status = match CommandLine::parse(rest).or_else(|| CommandLine::nested(rest)) {
		Some(line) => run(&line),
		None => process::main(
			args
				.iter()
				.map(|arg| BString::from(arg.to_string_lossy().into_owned())),
			ProcessOptions { extras: true, ..ProcessOptions::default() },
		),
	};
	// After bash's own lines (what scripts read the first of), which build
	// this is.
	if status == 0 && args.len() == 2 && args[1] == "--version" {
		println!("BaoCode Bash {} <{}>", env!("CARGO_PKG_VERSION"), env!("CARGO_PKG_REPOSITORY"));
	}
	ExitCode::from((status & 0xff) as u8)
}

/// What the programs an agent's commands start on Windows should do, set
/// before anything else runs:
///
/// - Console programs (`cmd`, PowerShell, .NET) write UTF-8: each runs on a
///   console of its own, which starts with the system's OEM code page (GBK on
///   Simplified Chinese), and is given UTF-8 first (by this program, run on it
///   as `bash.exe --pi-set-console-code-page 65001`).
/// - Python reads and writes UTF-8 (`PYTHONUTF8=1`), not the ANSI code page,
///   unless `PYTHONUTF8` or `PYTHONIOENCODING` says otherwise.
/// - `SHELL` is this bash, unless set: what `"$SHELL" -c …` runs.
#[cfg(windows)]
fn prepare_windows() {
	let Ok(exe) = env::current_exe() else { return };
	pi_shell::sys::use_console_code_page(&exe, 65001);
	// SAFETY: no other thread runs yet.
	unsafe {
		if env::var_os("PYTHONUTF8").is_none() && env::var_os("PYTHONIOENCODING").is_none() {
			env::set_var("PYTHONUTF8", "1");
		}
		if env::var_os("SHELL").is_none() {
			env::set_var("SHELL", exe.to_string_lossy().replace('\\', "/"));
		}
	}
}

/// `bash [-c] [-e] [-u] [-x] [-l] [--login|--norc|--noprofile] [--] COMMAND
/// [NAME [ARGS]]`: a `-c` command line this runs itself.
#[derive(Debug, PartialEq, Eq)]
struct CommandLine {
	command: String,
	/// The `set` options given with it (`e`, `u`, `x`).
	options: String,
	/// `$0`.
	name:    Option<String>,
	/// `$1`, `$2`, ….
	args:    Vec<String>,
}

impl CommandLine {
	/// None for any other command line, or one not in Unicode: the process
	/// shell's.
	fn parse(args: &[OsString]) -> Option<Self> {
		let mut command = false;
		let mut options = String::new();
		let mut operands = Vec::new();
		let mut args = args.iter();
		while let Some(arg) = args.next() {
			let arg = arg.to_str()?;
			match arg {
				"--" => {
					operands.extend(args.by_ref().map(|a| a.to_str().map(str::to_owned)));
					break;
				},
				"--login" | "--norc" | "--noprofile" => {},
				_ if arg.len() > 1 && arg.starts_with('-') && !arg.starts_with("--") => {
					for flag in arg[1..].chars() {
						match flag {
							'c' => command = true,
							'l' => {},
							'e' | 'u' | 'x' => options.push(flag),
							_ => return None,
						}
					}
				},
				_ if arg.starts_with('-') && arg != "-" => return None,
				_ => {
					operands.push(Some(arg.to_owned()));
					operands.extend(args.by_ref().map(|a| a.to_str().map(str::to_owned)));
					break;
				},
			}
		}
		if !command {
			return None;
		}
		let mut operands = operands
			.into_iter()
			.collect::<Option<Vec<_>>>()?
			.into_iter();
		Some(Self {
			command: operands.next()?,
			options,
			name: operands.next(),
			args: operands.collect(),
		})
	}

	/// `bash ARGS…` as a command line, for a script or a `-c` with options
	/// [`CommandLine::parse`] leaves to the process shell; None for anything
	/// else (no script, `-s`, `-i`, `--version`, `--help`) or arguments not
	/// in Unicode.
	fn nested(args: &[OsString]) -> Option<Self> {
		let mut runs = false;
		let mut args_iter = args.iter();
		while let Some(arg) = args_iter.next() {
			let arg = arg.to_str()?;
			match arg {
				"--" => {
					runs = args_iter.next().is_some();
					break;
				},
				"--version" | "--help" => return None,
				"--rcfile" | "--init-file" | "-o" | "+o" | "-O" | "+O" => {
					args_iter.next()?;
				},
				_ if arg.starts_with("--") => {},
				_ if arg.len() > 1 && (arg.starts_with('-') || arg.starts_with('+')) => {
					if arg[1..].contains(['s', 'i']) {
						return None;
					}
					if arg.starts_with('-') && arg[1..].contains('c') {
						runs = true;
						break;
					}
				},
				_ if arg == "-" => return None,
				_ => {
					runs = true;
					break;
				},
			}
		}
		if !runs {
			return None;
		}
		let mut command = String::from("bash");
		for arg in args {
			command.push(' ');
			command.push_str(&quote(arg.to_str()?));
		}
		Some(Self { command, options: String::new(), name: None, args: Vec::new() })
	}

	/// The command with its options, `$0` and positional parameters set
	/// before it, on its first line (so that its line numbers stay its own).
	fn script(&self) -> String {
		let mut script = String::new();
		if !self.options.is_empty() {
			script.push_str("set -");
			script.push_str(&self.options);
			script.push_str("; ");
		}
		if let Some(name) = &self.name {
			script.push_str("BASH_ARGV0=");
			script.push_str(&quote(name));
			script.push_str("; ");
		}
		if !self.args.is_empty() {
			script.push_str("set --");
			for arg in &self.args {
				script.push(' ');
				script.push_str(&quote(arg));
			}
			script.push_str("; ");
		}
		script.push_str(&self.command);
		script
	}
}

/// [text] in single quotes, for the shell to read back as it is.
fn quote(text: &str) -> String {
	format!("'{}'", text.replace('\'', r"'\''"))
}

/// What goes before the command, on its first line: `SHELL` exported, as
/// the shell takes no `SHELL` from the environment (it would be the
/// caller's shell) and has no login shell to set it from on Windows; and
/// the [`python_stand_ins`].
#[cfg(windows)]
fn prelude() -> String {
	let mut prelude = match env::var("SHELL") {
		Ok(shell) if !shell.is_empty() => format!("export SHELL={}; ", quote(&shell)),
		_ => String::new(),
	};
	prelude.push_str(&python_stand_ins());
	prelude
}

#[cfg(not(windows))]
const fn prelude() -> String {
	String::new()
}

/// Functions for `python3` and `python` where `PATH` finds only the App
/// Installer's alias of that name, which runs no Python but says to get
/// one from the Microsoft Store (status 9009): `python3` runs `python`,
/// `python` runs `python3`, or either runs `py -3`, whichever is real.
/// Exported, for the shells started in-engine. Agents write `python3`; a
/// python.org install has `python` and `py`.
#[cfg(windows)]
fn python_stand_ins() -> String {
	use std::path::PathBuf;

	let Some(apps) =
		env::var_os("LOCALAPPDATA").map(|dir| PathBuf::from(dir).join(r"Microsoft\WindowsApps"))
	else {
		return String::new();
	};
	// Without the aliases, nothing to stand in for (and no `PATH` search).
	if !store_python_alias(&apps.join("python3.exe"))
		&& !store_python_alias(&apps.join("python.exe"))
	{
		return String::new();
	}
	let extensions: Vec<String> = env::var("PATHEXT")
		.unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_owned())
		.split(';')
		.filter(|ext| !ext.is_empty())
		.map(str::to_ascii_lowercase)
		.collect();
	// What `PATH` finds for each, `dir\name.ext` for each `PATHEXT`
	// extension in each directory in turn: one listing a directory.
	let names = ["python3", "python", "py"];
	let mut found: [Option<PathBuf>; 3] = Default::default();
	for dir in env::split_paths(&env::var_os("PATH").unwrap_or_default()) {
		if found.iter().all(Option::is_some) {
			break;
		}
		if dir.as_os_str().is_empty() {
			continue;
		}
		let files = files_starting_with_py(&dir);
		for (name, found) in names.iter().zip(&mut found) {
			if found.is_none() {
				*found = extensions
					.iter()
					.map(|ext| format!("{name}{ext}"))
					.find(|file| files.contains(file))
					.map(|file| dir.join(file));
			}
		}
	}
	let [python3, python, py] =
		found.map(|program| program.is_some_and(|program| !store_python_alias(&program)));
	let mut functions = Vec::new();
	for (name, ok, other) in
		[("python3", python3, ("python", python)), ("python", python, ("python3", python3))]
	{
		if ok {
			continue;
		}
		if other.1 {
			functions.push((name, other.0.to_owned()));
		} else if py {
			functions.push((name, "py -3".to_owned()));
		}
	}
	functions
		.iter()
		.map(|(name, runs)| format!("{name}() {{ {runs} \"$@\"; }}; export -f {name}; "))
		.collect()
}

/// The names, lowercase, of the files in `dir` that start with `py`.
#[cfg(windows)]
fn files_starting_with_py(dir: &std::path::Path) -> Vec<String> {
	use std::os::windows::ffi::OsStrExt as _;

	use windows_sys::Win32::{
		Foundation::INVALID_HANDLE_VALUE,
		Storage::FileSystem::{
			FILE_ATTRIBUTE_DIRECTORY, FindClose, FindExInfoBasic, FindExSearchNameMatch,
			FindFirstFileExW, FindNextFileW, WIN32_FIND_DATAW,
		},
	};

	let pattern: Vec<u16> = dir
		.join("py*")
		.as_os_str()
		.encode_wide()
		.chain(std::iter::once(0))
		.collect();
	// SAFETY: plain data.
	let mut data: WIN32_FIND_DATAW = unsafe { std::mem::zeroed() };
	// SAFETY: `pattern` is NUL-terminated; `data` is a WIN32_FIND_DATAW.
	let find = unsafe {
		FindFirstFileExW(
			pattern.as_ptr(),
			FindExInfoBasic,
			(&raw mut data).cast(),
			FindExSearchNameMatch,
			std::ptr::null(),
			0,
		)
	};
	if find == INVALID_HANDLE_VALUE {
		return Vec::new();
	}
	let mut files = Vec::new();
	loop {
		if data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
			let len = data
				.cFileName
				.iter()
				.position(|&c| c == 0)
				.unwrap_or(data.cFileName.len());
			files.push(String::from_utf16_lossy(&data.cFileName[..len]).to_ascii_lowercase());
		}
		// SAFETY: `find` is open; `data` as above.
		if unsafe { FindNextFileW(find, &raw mut data) } == 0 {
			break;
		}
	}
	// SAFETY: `find` is open, and closed once.
	unsafe { FindClose(find) };
	files
}

/// Whether `program` is an App Installer alias (`python.exe` in
/// `WindowsApps`) that only sends to the Microsoft Store: an app execution
/// link to its `PythonRedirector`.
#[cfg(windows)]
fn store_python_alias(program: &std::path::Path) -> bool {
	use std::os::windows::{fs::OpenOptionsExt as _, io::AsRawHandle as _};

	use windows_sys::Win32::{
		Storage::FileSystem::{
			FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES,
		},
		System::{IO::DeviceIoControl, Ioctl::FSCTL_GET_REPARSE_POINT},
	};
	const IO_REPARSE_TAG_APPEXECLINK: u32 = 0x8000_001b;

	let Ok(file) = fs::OpenOptions::new()
		.access_mode(FILE_READ_ATTRIBUTES)
		.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
		.open(program)
	else {
		return false;
	};
	let mut data = vec![0_u8; 16 * 1024];
	let mut len = 0_u32;
	// SAFETY: `data` is writable for its length; `len` receives the count.
	let ok = unsafe {
		DeviceIoControl(
			file.as_raw_handle(),
			FSCTL_GET_REPARSE_POINT,
			std::ptr::null(),
			0,
			data.as_mut_ptr().cast(),
			data.len() as u32,
			&raw mut len,
			std::ptr::null_mut(),
		)
	} != 0;
	if !ok
		|| len < 8
		|| u32::from_le_bytes([data[0], data[1], data[2], data[3]]) != IO_REPARSE_TAG_APPEXECLINK
	{
		return false;
	}
	let wide: Vec<u16> = data[8..len as usize]
		.as_chunks::<2>()
		.0
		.iter()
		.map(|pair| u16::from_le_bytes(*pair))
		.collect();
	String::from_utf16_lossy(&wide).contains("PythonRedirector")
}

/// Runs [line] over this process's fds; its exit status, 130 when
/// interrupted.
fn run(line: &CommandLine) -> i32 {
	let runtime = match tokio::runtime::Builder::new_multi_thread()
		.enable_all()
		.build()
	{
		Ok(runtime) => runtime,
		Err(err) => {
			eprintln!("bash: {err}");
			return 2;
		},
	};
	let status = runtime.block_on(async {
		let mut cancel = CancelToken::default();
		let abort = cancel.emplace_abort_token();
		tokio::spawn(async move {
			if tokio::signal::ctrl_c().await.is_ok() {
				abort.abort(AbortReason::Signal);
			}
		});
		let options = ShellExecuteOptions {
			command: format!("{}{}", prelude(), line.script()),
			cwd: env::current_dir()
				.ok()
				.map(|dir| dir.to_string_lossy().into_owned()),
			..ShellExecuteOptions::default()
		};
		match execute_shell_stdio(options, own_stdio(), cancel).await {
			Ok(result) => result
				.exit_code
				.unwrap_or(if result.timed_out { 124 } else { 130 }),
			Err(err) => {
				eprintln!("bash: {err}");
				2
			},
		}
	});
	let _ = std::io::stdout().flush();
	// Background jobs it left running are not waited for, as bash's are not.
	runtime.shutdown_background();
	status
}

/// This process's stdin, stdout and stderr, each duplicated; None for one
/// it has not (a GUI parent's), the null device's then.
fn own_stdio() -> [Option<fs::File>; 3] {
	#[cfg(unix)]
	use std::os::fd::AsFd as AsOwn;
	#[cfg(windows)]
	use std::os::windows::io::AsHandle as AsOwn;

	fn own(stream: &impl AsOwn) -> Option<fs::File> {
		#[cfg(unix)]
		let owned = stream.as_fd().try_clone_to_owned();
		#[cfg(windows)]
		let owned = stream.as_handle().try_clone_to_owned();
		owned.ok().map(fs::File::from)
	}

	[own(&std::io::stdin()), own(&std::io::stdout()), own(&std::io::stderr())]
}

#[cfg(test)]
mod tests {
	use super::*;

	fn parse(args: &[&str]) -> Option<CommandLine> {
		CommandLine::parse(&args.iter().map(OsString::from).collect::<Vec<_>>())
	}

	#[test]
	fn a_command_line_with_its_name_and_arguments() {
		let line = parse(&["-c", "echo \"$1\"", "bash", "it's"]).unwrap();
		assert_eq!(line.command, "echo \"$1\"");
		assert_eq!(line.script(), "BASH_ARGV0='bash'; set -- 'it'\\''s'; echo \"$1\"");
	}

	#[test]
	fn options_around_c() {
		let line = parse(&["-l", "-c", "-e", "true"]).unwrap();
		assert_eq!(line.options, "e");
		assert_eq!(line.script(), "set -e; true");
		assert_eq!(parse(&["-lc", "true"]).unwrap().command, "true");
		assert_eq!(parse(&["--login", "-c", "--", "-x"]).unwrap().command, "-x");
	}

	#[test]
	fn the_rest_is_the_process_shell() {
		assert_eq!(parse(&["script.sh"]), None);
		assert_eq!(parse(&["--version"]), None);
		assert_eq!(parse(&["-o", "pipefail", "-c", "true"]), None);
		assert_eq!(parse(&[]), None);
		assert_eq!(parse(&["-c"]), None);
	}

	fn nested(args: &[&str]) -> Option<String> {
		CommandLine::nested(&args.iter().map(OsString::from).collect::<Vec<_>>())
			.map(|line| line.script())
	}

	#[test]
	fn scripts_run_in_a_shell_the_engine_starts() {
		assert_eq!(nested(&["s.sh", "it's"]).as_deref(), Some("bash 's.sh' 'it'\\''s'"));
		assert_eq!(nested(&["-e", "s.sh"]).as_deref(), Some("bash '-e' 's.sh'"));
		assert_eq!(
			nested(&["-o", "pipefail", "-c", "false | true"]).as_deref(),
			Some("bash '-o' 'pipefail' '-c' 'false | true'")
		);
		assert_eq!(nested(&["--norc", "--", "s.sh"]).as_deref(), Some("bash '--norc' '--' 's.sh'"));
	}

	#[test]
	fn stdin_and_interactive_shells_stay_the_process_shell() {
		assert_eq!(nested(&[]), None);
		assert_eq!(nested(&["-s", "a"]), None);
		assert_eq!(nested(&["-i"]), None);
		assert_eq!(nested(&["-"]), None);
		assert_eq!(nested(&["--version"]), None);
		assert_eq!(nested(&["-o", "pipefail"]), None);
		assert_eq!(nested(&["-e"]), None);
	}
}
