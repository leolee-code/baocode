# BaoCode Bash

A `bash.exe` for Windows that coding agents can rely on: bash 5.3 with the
usual Unix command-line tools built in, in one ~10 MB file, no Git for Windows
or MSYS2 needed.

[BaoCode](https://baocode.dev) offers it on Windows and, once installed, runs
its agents' shell commands with it ahead of Git Bash.

## Why

An agent writes shell commands the way they look on Linux and macOS. On
Windows they meet `cmd.exe` or PowerShell, or a Git Bash whose tools are
whatever that install happens to have, and paths that are `C:\x` to one
program and `/c/x` to the next. Much of an agent's time there goes into
working around that.

## What it does

- **bash 5.3**: a bash engine in Rust: `[[ ]]`, arithmetic, arrays,
  here-docs, functions, background jobs.
- **Tools built in**, run in-process ahead of `PATH`:
  `rg`, `grep`, `sed`, `awk`, `find`, `fd`, `xargs`, `jq`, `tar`, `diff`,
  `sort`, `uniq`, `cut`, `tr`, `head`, `tail`, `wc`, `tee`, `cat`, `ls`, `cp`,
  `mv`, `rm`, `mkdir`, `touch`, `ln`, `stat`, `du`, `df`, `date`, `env`,
  `which`, `sha256sum` and the other hash sums, `base64`, `od`, `seq`,
  `timeout`, `nohup`, `sleep`, `ps`, `pgrep`, `pkill`, `sponge`, `ts`, `sd`,
  `rsync` and more (80-odd in all).
- **Paths**: `C:\work\app`, `C:/work/app`, `/c/work/app` and
  `/mnt/c/work/app` all name the same folder, and `/tmp` is the temporary
  folder. The shell prints them as `C:/work/app` (`pwd`, `$PWD`, `$HOME`,
  `realpath`, `command -v`), a spelling both bash and Windows programs read,
  so `"$PWD/x"` can be handed to either; `cygpath` (`-u`, `-w`, `-m`, `-p`,
  `-a`) converts. `PATH` takes `;` and `:` between entries
  (`PATH="$PATH:/c/tools"`), and Windows programs get it `;` separated.
  Windows programs get arguments as Git Bash passes them: `git -C /c/repo`
  sees `C:/repo`, `cmd //c dir` sees `/c` (`MSYS_NO_PATHCONV` and
  `MSYS2_ARG_CONV_EXCL` work as there).
- **Windows programs stay reachable**: a command line written for the Windows
  program a built-in shadows (`find /c "x" file`, `sort /r`) goes to that
  program; everything else on `PATH` (`git`, `node`, `python`, …) runs as
  usual.
- **UTF-8 output**: `cmd`, PowerShell and other console programs write UTF-8
  whatever the system's code page (no GBK on a Chinese Windows), and Python
  runs with `PYTHONUTF8=1`.
- **No surprises from Windows' own shims**: `bash x.sh`, `sh -c …` and `exec
  bash` run this bash, not WSL's (`exec env …` the built-in `env`); `$SHELL`
  and `$BASH` are this bash; where `python3` is only the Microsoft Store's
  placeholder, it runs the Python that is installed.
- **What scripts written for Git Bash expect**: `uname -s` is
  `MINGW64_NT-…` and `$OSTYPE` `msys`; `diff <(a) <(b)`, `/dev/stdin`,
  `/dev/stderr`, `/dev/zero` and `/dev/urandom` work; a `#!/usr/bin/env node`
  script runs with node, and `/usr/bin/env`, `/bin/bash` and the like work as
  commands; `env` and `xargs` find `node.exe` and `npm.cmd` (`env -i` too);
  `pwd -W` prints `C:/…`; `$PPID` is the parent's pid; `rev` is there;
  `sed` edits files that are not UTF-8 (GBK) without touching their other
  bytes; `chmod` sets and clears the read-only attribute.

## Use

```
bash -c 'rg -n TODO src | head -20'
bash -lc 'cd /c/work/app && npm test'
bash script.sh arg
bash                    # interactive
```

`bash -c COMMAND [NAME [ARGS…]]` and `bash script.sh [ARGS…]` (with bash's
options) run with the tools above. Commands on stdin and the interactive shell
run the engine as a process shell, where a program on `PATH` comes before a
built-in tool.

## Build

```
cargo build --release -p bash-exe     # target/release/bash(.exe)
```

The toolchain is pinned in `rust-toolchain.toml` (a nightly: the UTF-8/16
kernels in `xutf` use `portable_simd`). It builds and runs on macOS and Linux
too, which is handy for development; the releases are Windows only
(x64 and arm64), built and published by BaoCode's CI to
`https://dl.baocode.dev/tools/bash-exe/`.

## Origin and license

This is a fork of the shell from [oh-my-pi](https://github.com/can1357/oh-my-pi)
(`crates/pi-shell` and the crates it needs), taken at commit
`84f5adc3bbfc0c2a7caecbad78b1b6eedf0a2939` (see `UPSTREAM_COMMIT`) and
maintained separately since; `bash-exe` is ours. Thanks to Can Bölük, Stencil
Labs and the oh-my-pi contributors.

oh-my-pi is MIT-licensed and the crates keep their notices (`LICENSE-MIT`,
each crate's `LICENSE`/`NOTICE`, and `crates/pi-builtins/LICENSE` for the
ported utilities: uutils coreutils, ripgrep, jaq and others). Parts of the
bash engine follow GNU bash's own sources closely, and GNU bash is GPL; to be
on the safe side this repository as a whole, and the `bash.exe` built from
it, are distributed under the GNU General Public License v3.0 or later
(`LICENSE`).
