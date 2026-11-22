//! The arguments of a Windows program as Git Bash (MSYS2) would pass them.
//!
//! Commands an agent writes on Windows are written for Git Bash, whose
//! runtime rewrites the arguments of every non-MSYS program it starts: a
//! POSIX path becomes a Windows one, and `//x` becomes `/x` (the way to pass
//! a `/x` switch through it). Passed as written, `git -C /c/repo` fails and
//! `cmd //c dir` opens an interactive `cmd`. This does the same for the
//! paths the shell itself understands ([`pi_vfs::msys_drive`], `/tmp`):
//!
//! - `/c/x/y` and `/mnt/c/x/y` → `C:/x/y`, `/c/` → `C:/`, when drive `C:`
//!   exists. A bare `/c` stays: a switch (`cmd /c`), as no Windows program
//!   takes a drive's root spelled that way.
//! - `/tmp` and `/tmp/x` → the temporary directory, `/` separated.
//! - `//x` → `/x`, when no other `/` follows (`//server/share` stays).
//! - The value of `--name=PATH`, `name=PATH`, and of a one-letter option
//!   `-XPATH` (`-I/c/include`), converted as a whole argument is.
//!
//! Anything else is passed as written: Windows switches (`/s`, `/nologo`),
//! URLs, relative paths, and POSIX paths with nothing behind them here
//! (`/usr/bin`, `/dev/null`). As in Git Bash, `MSYS_NO_PATHCONV` (set, not
//! empty) turns it off, and `MSYS2_ARG_CONV_EXCL` lists `;`-separated
//! prefixes of arguments to leave alone (`*` for all).

use std::borrow::Cow;

/// What converting needs to know of the system.
pub(crate) trait Paths {
	/// Whether drive `letter` (uppercase) exists.
	fn drive_exists(&self, letter: u8) -> bool;
	/// The temporary directory `/tmp` stands for, `/` separated, without a
	/// trailing `/`.
	fn temp_dir(&self) -> String;
}

/// The running system's drives and temporary directory.
pub(crate) struct System;

impl Paths for System {
	fn drive_exists(&self, letter: u8) -> bool {
		std::path::Path::new(&format!("{}:\\", char::from(letter))).exists()
	}

	fn temp_dir(&self) -> String {
		let dir = std::env::temp_dir().to_string_lossy().replace('\\', "/");
		dir.trim_end_matches('/').to_owned()
	}
}

/// Which arguments to leave alone, from the environment's
/// `MSYS_NO_PATHCONV` and `MSYS2_ARG_CONV_EXCL`.
pub(crate) struct Exclusions {
	all:      bool,
	prefixes: Vec<String>,
}

impl Exclusions {
	pub(crate) fn new(no_pathconv: Option<&str>, conv_excl: Option<&str>) -> Self {
		let conv_excl = conv_excl.unwrap_or_default();
		let all = no_pathconv.is_some_and(|value| !value.is_empty())
			|| conv_excl.split(';').any(|prefix| prefix == "*");
		let prefixes = conv_excl
			.split(';')
			.filter(|prefix| !prefix.is_empty() && *prefix != "*")
			.map(str::to_owned)
			.collect();
		Self { all, prefixes }
	}

	fn excludes(&self, arg: &str) -> bool {
		self.all
			|| self
				.prefixes
				.iter()
				.any(|prefix| arg.starts_with(prefix.as_str()))
	}
}

/// `arg` as Git Bash would pass it to a Windows program.
pub(crate) fn convert<'a>(
	arg: &'a str,
	paths: &dyn Paths,
	exclusions: &Exclusions,
) -> Cow<'a, str> {
	if !arg.contains('/') || exclusions.excludes(arg) {
		return Cow::Borrowed(arg);
	}
	if let Some(rest) = arg.strip_prefix("//") {
		if !rest.is_empty() && !rest.contains('/') {
			return Cow::Borrowed(&arg[1..]);
		}
		return Cow::Borrowed(arg);
	}
	if let Some(path) = path(arg, paths) {
		return Cow::Owned(path);
	}
	// `--name=PATH`, `name=PATH`.
	if let Some(eq) = arg.find('=') {
		let name = arg[..eq].trim_start_matches('-');
		let is_name = !name.is_empty()
			&& name
				.bytes()
				.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'));
		if is_name && let Some(path) = path(&arg[eq + 1..], paths) {
			return Cow::Owned(format!("{}{path}", &arg[..=eq]));
		}
		return Cow::Borrowed(arg);
	}
	// `-XPATH`.
	let bytes = arg.as_bytes();
	if bytes.len() > 2
		&& bytes[0] == b'-'
		&& bytes[1].is_ascii_alphabetic()
		&& bytes[2] == b'/'
		&& let Some(path) = path(&arg[2..], paths)
	{
		return Cow::Owned(format!("{}{path}", &arg[..2]));
	}
	Cow::Borrowed(arg)
}

/// The Windows spelling of the POSIX path `text`, or `None` when it is none
/// the shell knows (or a bare `/c`).
fn path(text: &str, paths: &dyn Paths) -> Option<String> {
	if !text.starts_with('/') || text.starts_with("//") {
		return None;
	}
	if let Some((letter, tail)) = pi_vfs::msys_drive(text.as_bytes()) {
		// `/c`: a switch. `/mnt/c` is a drive however written.
		let bare = text.len() == 2;
		if bare || !paths.drive_exists(letter) {
			return None;
		}
		// `tail` is a suffix of `text`, cut after an ASCII `/`.
		let tail = std::str::from_utf8(tail).ok()?;
		return Some(format!("{}:/{tail}", char::from(letter)));
	}
	let rest = text.strip_prefix("/tmp")?;
	if !(rest.is_empty() || rest.starts_with('/')) {
		return None;
	}
	Some(format!("{}{rest}", paths.temp_dir()))
}

#[cfg(test)]
mod tests {
	use super::*;

	struct Fake;

	impl Paths for Fake {
		fn drive_exists(&self, letter: u8) -> bool {
			matches!(letter, b'C' | b'D')
		}

		fn temp_dir(&self) -> String {
			"C:/Users/me/AppData/Local/Temp".to_owned()
		}
	}

	fn convert_all(arg: &str) -> String {
		convert(arg, &Fake, &Exclusions::new(None, None)).into_owned()
	}

	#[test]
	fn drive_paths_become_windows_paths() {
		assert_eq!(convert_all("/c/repo/src"), "C:/repo/src");
		assert_eq!(convert_all("/d/"), "D:/");
		assert_eq!(convert_all("/mnt/c/x"), "C:/x");
		assert_eq!(convert_all("/mnt/d"), "D:/");
		assert_eq!(convert_all("/c/中文/文件.txt"), "C:/中文/文件.txt");
	}

	#[test]
	fn switches_stay() {
		assert_eq!(convert_all("/c"), "/c");
		assert_eq!(convert_all("/s"), "/s");
		assert_eq!(convert_all("/nologo"), "/nologo");
		assert_eq!(convert_all("/C:x"), "/C:x");
		assert_eq!(convert_all("/v:q"), "/v:q");
	}

	#[test]
	fn a_drive_that_is_not_there_is_no_path() {
		assert_eq!(convert_all("/z/x"), "/z/x");
		// A pattern, not a path.
		assert_eq!(convert_all("/a/"), "/a/");
	}

	#[test]
	fn tmp_is_the_temporary_directory() {
		assert_eq!(convert_all("/tmp"), "C:/Users/me/AppData/Local/Temp");
		assert_eq!(convert_all("/tmp/x.log"), "C:/Users/me/AppData/Local/Temp/x.log");
		assert_eq!(convert_all("/tmpdir"), "/tmpdir");
	}

	#[test]
	fn a_doubled_slash_passes_one() {
		assert_eq!(convert_all("//c"), "/c");
		assert_eq!(convert_all("//nologo"), "/nologo");
		assert_eq!(convert_all("//server/share"), "//server/share");
		assert_eq!(convert_all("//"), "//");
	}

	#[test]
	fn option_values() {
		assert_eq!(convert_all("--file=/c/x"), "--file=C:/x");
		assert_eq!(convert_all("--out=/tmp/o"), "--out=C:/Users/me/AppData/Local/Temp/o");
		assert_eq!(convert_all("PREFIX=/d/opt"), "PREFIX=D:/opt");
		assert_eq!(convert_all("-I/c/include"), "-IC:/include");
		assert_eq!(convert_all("--file=/usr/x"), "--file=/usr/x");
		assert_eq!(convert_all("a b=/c/x"), "a b=/c/x");
		assert_eq!(convert_all("-cx/c/y"), "-cx/c/y");
	}

	#[test]
	fn the_rest_stays() {
		for arg in [
			"/usr/bin",
			"/dev/null",
			"https://example.com/c/x",
			"src/c/x",
			"C:/x",
			r"C:\x",
			"a:b/c",
			"x//y",
			"plain",
			"",
		] {
			assert_eq!(convert_all(arg), arg);
		}
	}

	#[test]
	fn exclusions() {
		let off = Exclusions::new(Some("1"), None);
		assert_eq!(convert("/c/x", &Fake, &off), "/c/x");
		let empty = Exclusions::new(Some(""), None);
		assert_eq!(convert("/c/x", &Fake, &empty), "C:/x");
		let star = Exclusions::new(None, Some("*"));
		assert_eq!(convert("//c", &Fake, &star), "//c");
		let some = Exclusions::new(None, Some("/c/keep;--raw="));
		assert_eq!(convert("/c/keep/x", &Fake, &some), "/c/keep/x");
		assert_eq!(convert("--raw=/c/x", &Fake, &some), "--raw=/c/x");
		assert_eq!(convert("/c/other", &Fake, &some), "C:/other");
	}
}
