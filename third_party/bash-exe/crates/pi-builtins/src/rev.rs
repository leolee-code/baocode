//! `rev` builtin (util-linux): write each line of the files, or of standard
//! input, with its characters in reverse order. A byte that is not part of
//! a UTF-8 character counts as one character and is kept as it is.

use std::{
	ffi::OsString,
	io::{BufRead, BufReader, BufWriter, Read, Write},
};

use bstr::ByteSlice;
use clap::{Arg, ArgAction, ArgMatches, Command, builder::ValueParser};
use uucore::display::Quotable;

use crate::host::{Host, Utility, format_usage, matches_parser, strip_errno};

const ZERO: &str = "zero";
const FILE: &str = "file";

/// Parsed `rev` invocation.
pub(crate) struct Rev {
	matches: ArgMatches,
}

matches_parser!(Rev, app);

impl Utility for Rev {
	const NAME: &'static str = "rev";

	fn run(self, host: &mut Host) -> i32 {
		let separator = if self.matches.get_flag(ZERO) { b'\0' } else { b'\n' };
		let files: Vec<OsString> = self
			.matches
			.get_many::<OsString>(FILE)
			.map_or_else(|| vec![OsString::from("-")], |files| files.cloned().collect());
		for file in &files {
			if host.is_cancelled() {
				break;
			}
			let result = if file == "-" {
				reverse(&mut host.stdin, separator, &mut host.stdout)
			} else {
				let path = host.resolve(file);
				match host.fs().open(path) {
					Ok(input) => reverse(input, separator, &mut host.stdout),
					Err(error) => {
						host.error(format!("cannot open {}: {}", file.quote(), strip_errno(&error)), 1);
						continue;
					},
				}
			};
			if let Err(error) = result {
				if error.kind() == std::io::ErrorKind::BrokenPipe {
					return host.exit_code();
				}
				host.error(format!("{}: {}", file.maybe_quote(), strip_errno(&error)), 1);
			}
		}
		host.exit_code()
	}
}

/// Write the lines of `input` to `out` reversed.
fn reverse(input: impl Read, separator: u8, out: impl Write) -> std::io::Result<()> {
	let mut reader = BufReader::new(input);
	let mut out = BufWriter::new(out);
	let mut line = Vec::new();
	let mut reversed = Vec::new();
	loop {
		line.clear();
		if reader.read_until(separator, &mut line)? == 0 {
			break;
		}
		let ended = line.last() == Some(&separator);
		let text = if ended { &line[..line.len() - 1] } else { &line[..] };
		reversed.clear();
		for (start, end, _) in text.char_indices().rev() {
			reversed.extend_from_slice(&text[start..end]);
		}
		if ended {
			reversed.push(separator);
		}
		out.write_all(&reversed)?;
	}
	out.flush()
}

/// The `rev` argument model.
fn app() -> Command {
	Command::new(Rev::NAME)
		.version("2.41")
		.about("Reverse lines characterwise.")
		.override_usage(format_usage("rev [options] [<file> ...]"))
		.arg(
			Arg::new(ZERO)
				.short('0')
				.long(ZERO)
				.help("zero line delimiter")
				.action(ArgAction::SetTrue),
		)
		.arg(
			Arg::new(FILE)
				.action(ArgAction::Append)
				.value_parser(ValueParser::os_string())
				.value_hint(clap::ValueHint::FilePath),
		)
}

#[cfg(test)]
mod tests {
	use super::Rev;
	use crate::host::run_util;

	#[test]
	fn reverses_each_line() {
		let (code, capture) = run_util::<Rev>(&[], "hello\nwörld\n\nlast", "/");
		assert_eq!(code, 0);
		assert_eq!(capture.out(), "olleh\ndlröw\n\ntsal");
		assert_eq!(capture.err(), "");
	}

	#[test]
	fn zero_separates_on_nul() {
		let (code, capture) = run_util::<Rev>(&["-0"], "ab\0cd\0", "/");
		assert_eq!(code, 0);
		assert_eq!(capture.out(), "ba\0dc\0");
	}

	#[test]
	fn reads_files_and_reports_missing_ones() {
		let dir = tempfile::tempdir().unwrap();
		std::fs::write(dir.path().join("in"), b"abc\n").unwrap();
		let (code, capture) = run_util::<Rev>(&["in", "nope"], "", dir.path());
		assert_eq!(code, 1);
		assert_eq!(capture.out(), "cba\n");
		assert_eq!(capture.err(), "rev: cannot open 'nope': No such file or directory\n");
	}
}
