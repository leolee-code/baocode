//! `cygpath` builtin (Windows): convert paths between the spellings Git
//! Bash scripts meet: POSIX (`/c/x`), Windows (`C:\x`) and mixed (`C:/x`,
//! the one the shell itself prints). Paths are converted as text, as
//! Cygwin's does; `-a` makes them absolute against the working directory.

use std::io::Write;

use clap::{Arg, ArgAction, ArgMatches, Command};

use crate::host::{Host, Utility, format_usage, matches_parser};

const UNIX: &str = "unix";
const WINDOWS: &str = "windows";
const MIXED: &str = "mixed";
const PATH: &str = "path";
const ABSOLUTE: &str = "absolute";
const DOS: &str = "dos";
const LONG: &str = "long-name";
const SHORT: &str = "short-name";
const NAME: &str = "name";

/// Parsed `cygpath` invocation.
pub(crate) struct Cygpath {
	matches: ArgMatches,
}

matches_parser!(Cygpath, app);

/// The spelling a path is converted to.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Form {
	/// `/c/x`.
	Unix,
	/// `C:\x`.
	Windows,
	/// `C:/x`.
	Mixed,
}

impl Utility for Cygpath {
	const NAME: &'static str = "cygpath";

	fn run(self, host: &mut Host) -> i32 {
		let m = &self.matches;
		let form = if m.get_flag(WINDOWS) || m.get_flag(DOS) {
			Form::Windows
		} else if m.get_flag(MIXED) {
			Form::Mixed
		} else {
			Form::Unix
		};
		let list = m.get_flag(PATH);
		let absolute = m.get_flag(ABSOLUTE);
		let names: Vec<String> = m
			.get_many::<String>(NAME)
			.map(|n| n.cloned().collect())
			.unwrap_or_default();
		if names.is_empty() {
			return host.usage_error("no path given", 1);
		}
		let cwd = host.cwd().to_string_lossy().replace('\\', "/");
		let temp = std::env::temp_dir().to_string_lossy().replace('\\', "/");
		let at = Place { cwd: &cwd, temp: temp.trim_end_matches('/') };
		for name in &names {
			if name.is_empty() {
				host.error("can't convert empty path", 1);
				continue;
			}
			let out = if list {
				convert_list(name, form, absolute, &at)
			} else {
				convert(name, form, absolute, &at)
			};
			if writeln!(host.stdout, "{out}").is_err() {
				return 1;
			}
		}
		let _ = host.stdout.flush();
		host.exit_code()
	}
}

/// Where relative and `/tmp` paths are: the working directory and the
/// temporary directory, both `/` separated.
struct Place<'a> {
	cwd:  &'a str,
	temp: &'a str,
}

/// A `PATH`-style list: entries split on `;` or `:` (not a drive's), each
/// converted, joined with `:` for the POSIX spelling, `;` otherwise.
fn convert_list(list: &str, form: Form, absolute: bool, at: &Place<'_>) -> String {
	let sep = if form == Form::Unix { ":" } else { ";" };
	pi_vfs::path_list(list.as_bytes(), true)
		.into_iter()
		.map(|entry| {
			let entry = String::from_utf8_lossy(entry);
			if entry.is_empty() {
				String::new()
			} else {
				convert(&entry, form, absolute, at)
			}
		})
		.collect::<Vec<_>>()
		.join(sep)
}

/// `path` in `form`.
fn convert(path: &str, form: Form, absolute: bool, at: &Place<'_>) -> String {
	let mut mixed = mixed(path, at);
	if absolute && !is_absolute(&mixed) {
		mixed = format!("{}/{mixed}", at.cwd.trim_end_matches('/'));
	}
	if absolute {
		mixed = normalize(&mixed);
	}
	match form {
		Form::Mixed => on_drive(mixed, at.cwd),
		Form::Windows => on_drive(mixed, at.cwd).replace('/', "\\"),
		Form::Unix => unix(&mixed),
	}
}

/// `path` with `/` separators, an MSYS drive alias (`/c/x`,
/// `/cygdrive/c/x`) as the drive path and `/tmp` the temporary directory.
fn mixed(path: &str, at: &Place<'_>) -> String {
	let path = path.replace('\\', "/");
	if let Some(rest) = path.strip_prefix("/tmp")
		&& (rest.is_empty() || rest.starts_with('/'))
	{
		return format!("{}{rest}", at.temp);
	}
	let alias = path.strip_prefix("/cygdrive").filter(|r| r.starts_with('/')).unwrap_or(&path);
	if let Some((letter, tail)) = pi_vfs::msys_drive(alias.as_bytes()) {
		return format!("{}:/{}", char::from(letter), String::from_utf8_lossy(tail));
	}
	path
}

/// Whether `path` (`/` separated) is absolute: rooted or on a drive.
fn is_absolute(path: &str) -> bool {
	path.starts_with('/') || drive(path).is_some()
}

/// The drive letter of `C:/x` (or a bare `C:`).
fn drive(path: &str) -> Option<char> {
	match path.as_bytes() {
		[letter, b':'] | [letter, b':', b'/', ..] if letter.is_ascii_alphabetic() => {
			Some(char::from(*letter))
		},
		_ => None,
	}
}

/// A root-relative `/x` on the drive of `cwd`, as Windows reads it.
fn on_drive(path: String, cwd: &str) -> String {
	match drive(cwd) {
		Some(letter) if path.starts_with('/') && !path.starts_with("//") => {
			format!("{}:{path}", letter.to_ascii_uppercase())
		},
		_ => path,
	}
}

/// The POSIX spelling of a mixed path: `C:/x` is `/c/x`, `C:/` is `/c`.
fn unix(path: &str) -> String {
	match drive(path) {
		Some(letter) => {
			let tail = &path[2..];
			let tail = if tail == "/" { "" } else { tail };
			format!("/{}{tail}", letter.to_ascii_lowercase())
		},
		None => path.to_owned(),
	}
}

/// `.` and `..` resolved textually, repeated separators collapsed; a
/// drive or share root stays.
fn normalize(path: &str) -> String {
	let (root, rest) = if drive(path).is_some() {
		path.split_at(2.min(path.len()))
	} else if let Some(rest) = path.strip_prefix("//") {
		let server = rest.find('/').map_or(rest.len(), |i| i + 1);
		let share = rest[server..].find('/').map_or(rest.len(), |i| server + i);
		path.split_at(2 + share)
	} else {
		("", path)
	};
	let mut parts: Vec<&str> = Vec::new();
	for part in rest.split('/') {
		match part {
			"" | "." => {},
			".." => {
				parts.pop();
			},
			_ => parts.push(part),
		}
	}
	format!("{root}/{}", parts.join("/"))
}

/// The `cygpath` argument model.
fn app() -> Command {
	let flag = |id: &'static str, short: char, help: &'static str| {
		Arg::new(id)
			.short(short)
			.long(id)
			.help(help)
			.action(ArgAction::SetTrue)
	};
	Command::new(Cygpath::NAME)
		.version("3.6.0")
		.about("Convert Unix and Windows format paths.")
		.override_usage(format_usage("cygpath (-d|-m|-u|-w) [-a] [-p] NAME..."))
		.arg(flag(UNIX, 'u', "print Unix form of NAMEs (/c/x)"))
		.arg(flag(WINDOWS, 'w', "print Windows form of NAMEs (C:\\x)"))
		.arg(flag(MIXED, 'm', "like --windows, but with regular slashes (C:/x)"))
		.arg(flag(DOS, 'd', "same as --windows (no short 8.3 names)"))
		.arg(flag(PATH, 'p', "NAME is a path list such as PATH"))
		.arg(flag(ABSOLUTE, 'a', "output absolute path"))
		.arg(flag(LONG, 'l', "accepted; names are left as they are"))
		.arg(flag(SHORT, 's', "accepted; names are left as they are"))
		.arg(Arg::new(NAME).action(ArgAction::Append))
}

#[cfg(test)]
mod tests {
	use super::{Cygpath, Form, Place, convert, convert_list};
	use crate::host::run_util;

	const AT: Place<'static> =
		Place { cwd: "C:/work/app", temp: "C:/Users/me/AppData/Local/Temp" };

	#[test]
	fn converts_between_the_three_spellings() {
		let to = |path, form| convert(path, form, false, &AT);
		assert_eq!(to(r"C:\Users\me", Form::Unix), "/c/Users/me");
		assert_eq!(to("D:/x", Form::Unix), "/d/x");
		assert_eq!(to("C:/", Form::Unix), "/c");
		assert_eq!(to("/c/Users/me", Form::Windows), r"C:\Users\me");
		assert_eq!(to("/cygdrive/d/x", Form::Mixed), "D:/x");
		assert_eq!(to("/c/x", Form::Unix), "/c/x");
		assert_eq!(to("/tmp/f", Form::Mixed), "C:/Users/me/AppData/Local/Temp/f");
		assert_eq!(to("/usr/bin", Form::Windows), r"C:\usr\bin");
		assert_eq!(to("/usr/bin", Form::Unix), "/usr/bin");
		assert_eq!(to(r"sub\f", Form::Unix), "sub/f");
		assert_eq!(to("sub/f", Form::Windows), r"sub\f");
		assert_eq!(to(r"\\srv\share\d", Form::Unix), "//srv/share/d");
		assert_eq!(to("//srv/share/d", Form::Windows), r"\\srv\share\d");
	}

	#[test]
	fn absolute_names_resolve_against_the_working_directory() {
		let abs = |path, form| convert(path, form, true, &AT);
		assert_eq!(abs("../lib/./x", Form::Mixed), "C:/work/lib/x");
		assert_eq!(abs(".", Form::Unix), "/c/work/app");
		assert_eq!(abs("C:/a/../b", Form::Windows), r"C:\b");
	}

	#[test]
	fn path_lists_take_either_separator() {
		let list = |path, form| convert_list(path, form, false, &AT);
		assert_eq!(list(r"C:\bin;D:\tools", Form::Unix), "/c/bin:/d/tools");
		assert_eq!(list("/c/bin:/d/tools", Form::Windows), r"C:\bin;D:\tools");
		assert_eq!(list(r"C:\bin;D:/x:/e/y", Form::Mixed), "C:/bin;D:/x;E:/y");
	}

	#[test]
	fn reports_missing_and_empty_names() {
		let (code, capture) = run_util::<Cygpath>(&[], "", "/");
		assert_eq!(code, 1);
		assert!(capture.err().starts_with("cygpath: no path given\n"), "{}", capture.err());
		let (code, capture) = run_util::<Cygpath>(&["-w", ""], "", "/");
		assert_eq!(code, 1);
		assert_eq!(capture.err(), "cygpath: can't convert empty path\n");
		let (code, capture) = run_util::<Cygpath>(&["-amp", "/c/x:/d/y"], "", "/");
		assert_eq!(code, 0);
		assert_eq!(capture.out(), "C:/x;D:/y\n");
	}
}
