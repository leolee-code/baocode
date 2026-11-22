//! What the shell keeps from git's environment, and the switch values its
//! `PI_*` variables take.

/// Git variables that pin a repository location to the launch checkout.
///
/// Forwarding them into a shell makes `git` ignore the command's working
/// directory and mutate the wrong worktree or index, so the shell rediscovers
/// the repository from `cwd` instead.
pub const GIT_REPO_LOCATION_ENV_VARS: [&str; 6] = [
	"GIT_DIR",
	"GIT_COMMON_DIR",
	"GIT_WORK_TREE",
	"GIT_INDEX_FILE",
	"GIT_OBJECT_DIRECTORY",
	"GIT_ALTERNATE_OBJECT_DIRECTORIES",
];

/// Whether `key` is one of [`GIT_REPO_LOCATION_ENV_VARS`]. Windows
/// environment lookups are case-insensitive, so `git_dir` binds there exactly
/// like `GIT_DIR`; POSIX names are case-sensitive.
#[cfg(windows)]
pub fn is_git_repo_location_var(key: &str) -> bool {
	GIT_REPO_LOCATION_ENV_VARS
		.iter()
		.any(|name| key.eq_ignore_ascii_case(name))
}

/// Whether `key` is one of [`GIT_REPO_LOCATION_ENV_VARS`]. Windows
/// environment lookups are case-insensitive, so `git_dir` binds there exactly
/// like `GIT_DIR`; POSIX names are case-sensitive.
#[cfg(not(windows))]
pub fn is_git_repo_location_var(key: &str) -> bool {
	GIT_REPO_LOCATION_ENV_VARS.contains(&key)
}

/// Whether a switch variable's value turns it on: present and not `""`,
/// `"0"` or `"false"` (any case).
pub fn flag_on(value: Option<&str>) -> bool {
	matches!(value, Some(value) if !value.is_empty() && value != "0" && !value.eq_ignore_ascii_case("false"))
}
