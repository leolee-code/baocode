//! `chmod` on Windows, where a file's mode is its read-only attribute: a
//! mode that leaves no write permission sets it, one that gives some clears
//! it, anything else changes nothing. GNU's modes (`755`, `+x`, `u=rw,go-w`,
//! `-w`) and options (`-R`, `-v`, `-c`, `-f`); directories are walked but
//! keep their attributes. Agents run `chmod +x script.sh` there as anywhere.

use std::{
	ffi::{OsStr, OsString},
	io::Write,
	path::Path,
};

use clap::{Arg, ArgAction, ArgMatches, Command, builder::ValueParser};
use uucore::display::Quotable;

use crate::host::{Host, Utility, format_usage, matches_parser, strip_errno};

const ARGS: &str = "args";

/// Parsed `chmod` invocation: options and operands alike, sorted in
/// [`Utility::run`] (a mode may start with `-`).
pub(crate) struct Chmod {
	matches: ArgMatches,
}

matches_parser!(Chmod, app);

#[derive(Default)]
struct Opts {
	recursive: bool,
	verbose:   bool,
	changes:   bool,
	quiet:     bool,
}

impl Utility for Chmod {
	const NAME: &'static str = "chmod";

	fn run(self, host: &mut Host) -> i32 {
		let mut opts = Opts::default();
		let mut operands: Vec<OsString> = Vec::new();
		let mut options_done = false;
		for arg in self
			.matches
			.get_many::<OsString>(ARGS)
			.unwrap_or_default()
		{
			let text = arg.to_string_lossy();
			if options_done || !text.starts_with('-') || text == "-" {
				operands.push(arg.clone());
				continue;
			}
			match &*text {
				"--" => options_done = true,
				"--recursive" => opts.recursive = true,
				"--verbose" => opts.verbose = true,
				"--changes" => opts.changes = true,
				"--silent" | "--quiet" => opts.quiet = true,
				_ if text[1..].chars().all(|c| "Rvcf".contains(c)) => {
					for c in text[1..].chars() {
						match c {
							'R' => opts.recursive = true,
							'v' => opts.verbose = true,
							'c' => opts.changes = true,
							_ => opts.quiet = true,
						}
					}
				},
				// `-w`, `-x`: a mode.
				_ if !text.starts_with("--") => operands.push(arg.clone()),
				_ => {
					host.error(format!("unrecognized option {}", text.quote()), 1);
					return 1;
				},
			}
		}
		let Some((mode, files)) = operands.split_first() else {
			host.error("missing operand", 1);
			return 1;
		};
		let mode = mode.to_string_lossy().into_owned();
		if files.is_empty() {
			host.error(format!("missing operand after {}", mode.quote()), 1);
			return 1;
		}
		if apply(&mode, 0o644, false).is_none() {
			host.error(format!("invalid mode: {}", mode.quote()), 1);
			return 1;
		}
		for file in files {
			if host.is_cancelled() {
				break;
			}
			change(host, &opts, &mode, file);
		}
		host.exit_code()
	}
}

/// Applies `mode` to `file` (and, with `-R`, what a directory holds).
fn change(host: &mut Host, opts: &Opts, mode: &str, file: &OsStr) {
	let path = host.resolve(file);
	let meta = match host.fs().metadata(&path) {
		Ok(meta) => meta,
		Err(err) => {
			if !opts.quiet {
				host.error(format!("cannot access {}: {}", file.quote(), strip_errno(&err)), 1);
			} else {
				host.fail(1);
			}
			return;
		},
	};
	let dir = meta.is_dir();
	let old = meta.permissions().mode() & 0o7777;
	let new = apply(mode, old, dir).unwrap_or(old);
	if !dir && old != new {
		if let Err(err) = host
			.fs()
			.set_permissions(&path, pi_vfs::Permissions::from_mode(new))
		{
			if !opts.quiet {
				host.error(
					format!("changing permissions of {}: {}", file.quote(), strip_errno(&err)),
					1,
				);
			} else {
				host.fail(1);
			}
			return;
		}
	}
	let new = if dir { old } else { new };
	if opts.verbose || (opts.changes && old != new) {
		let verb = if old == new { "retained as" } else { "changed from" };
		let line = if old == new {
			format!("mode of {} {verb} {new:04o} ({})", file.quote(), symbolic(new))
		} else {
			format!(
				"mode of {} {verb} {old:04o} ({}) to {new:04o} ({})",
				file.quote(),
				symbolic(old),
				symbolic(new)
			)
		};
		let _ = writeln!(host.stdout, "{line}");
	}
	if dir && opts.recursive {
		let Ok(entries) = host.fs().read_dir(&path) else {
			return;
		};
		let names: Vec<OsString> = entries.flatten().map(|entry| entry.file_name()).collect();
		for name in names {
			if host.is_cancelled() {
				return;
			}
			let child = Path::new(file).join(name);
			change(host, opts, mode, child.as_os_str());
		}
	}
}

/// `mode` (GNU's `[ugoa]*([-+=]([rwxXst]*|[ugo]))+` clauses, or an octal
/// number) applied to the permission bits `old` of a file (a directory with
/// `dir`); `None` for a mode that is not one. Without `ugoa` a clause is
/// for all, the umask aside.
fn apply(mode: &str, old: u32, dir: bool) -> Option<u32> {
	if !mode.is_empty() && mode.bytes().all(|b| (b'0'..=b'7').contains(&b)) {
		return u32::from_str_radix(mode, 8).ok().filter(|m| *m <= 0o7777);
	}
	let mut bits = old;
	for clause in mode.split(',') {
		let who_end = clause
			.find(|c: char| !"ugoa".contains(c))
			.unwrap_or(clause.len());
		let mut who = clause[..who_end]
			.chars()
			.map(|c| match c {
				'u' => 0o4700,
				'g' => 0o2070,
				'o' => 0o1007,
				_ => 0o7777,
			})
			.fold(0, |all, one| all | one);
		if who == 0 {
			who = 0o7777;
		}
		let mut rest = &clause[who_end..];
		if rest.is_empty() {
			return None;
		}
		while let Some(op) = rest.chars().next() {
			if !"+-=".contains(op) {
				return None;
			}
			rest = &rest[1..];
			let end = rest.find(|c: char| "+-=".contains(c)).unwrap_or(rest.len());
			let (perms, next) = rest.split_at(end);
			rest = next;
			let mut given = 0;
			for c in perms.chars() {
				given |= match c {
					'r' => 0o444,
					'w' => 0o222,
					'x' => 0o111,
					'X' if dir || bits & 0o111 != 0 => 0o111,
					'X' => 0,
					's' => 0o6000,
					't' => 0o1000,
					'u' => (bits >> 6 & 7) * 0o111,
					'g' => (bits >> 3 & 7) * 0o111,
					'o' => (bits & 7) * 0o111,
					_ => return None,
				};
			}
			let given = given & who;
			bits = match op {
				'+' => bits | given,
				'-' => bits & !given,
				_ => (bits & !who) | given,
			};
		}
	}
	Some(bits)
}

/// `rwxr-xr-x` for the permission bits of `mode`.
fn symbolic(mode: u32) -> String {
	(0..9)
		.map(|i| {
			if mode & (0o400 >> i) == 0 {
				'-'
			} else {
				['r', 'w', 'x'][i % 3]
			}
		})
		.collect()
}

fn app() -> Command {
	Command::new(Chmod::NAME)
		.version("9.8")
		.about("Change the mode of each FILE to MODE.")
		.override_usage(format_usage(
			"chmod [OPTION]... MODE[,MODE]... FILE...\n  or:  chmod [OPTION]... OCTAL-MODE FILE...",
		))
		.disable_help_flag(true)
		.disable_version_flag(true)
		.arg(
			Arg::new(ARGS)
				.action(ArgAction::Append)
				.num_args(0..)
				.allow_hyphen_values(true)
				.trailing_var_arg(true)
				.value_parser(ValueParser::os_string()),
		)
}

#[cfg(test)]
mod tests {
	use super::{apply, symbolic};

	#[test]
	fn modes_apply_as_gnu_chmod_does() {
		assert_eq!(apply("755", 0o644, false), Some(0o755));
		assert_eq!(apply("+x", 0o644, false), Some(0o755));
		assert_eq!(apply("-w", 0o644, false), Some(0o444));
		assert_eq!(apply("a-w", 0o666, false), Some(0o444));
		assert_eq!(apply("u+w,go-w", 0o444, false), Some(0o644));
		assert_eq!(apply("u=rw,go=r", 0o777, false), Some(0o644));
		assert_eq!(apply("go=u", 0o640, false), Some(0o666));
		assert_eq!(apply("a+X", 0o644, false), Some(0o644));
		assert_eq!(apply("a+X", 0o644, true), Some(0o755));
		assert_eq!(apply("u+wx-r", 0o444, false), Some(0o344));
		assert_eq!(apply("z", 0o644, false), None);
		assert_eq!(apply("u", 0o644, false), None);
		assert_eq!(apply("+q", 0o644, false), None);
		assert_eq!(apply("8", 0o644, false), None);
	}

	#[test]
	fn symbolic_permissions() {
		assert_eq!(symbolic(0o755), "rwxr-xr-x");
		assert_eq!(symbolic(0o444), "r--r--r--");
	}
}
