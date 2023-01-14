use std::{
    ffi::OsStr,
    fmt::{self, Write},
    process::{self, Child, Command, Output},
};

use crate::{utf8_to_string_lossy, CommandFailed, InstallError};

pub trait CommandExt {
    fn formattable(&self) -> CommandFormattable<'_>;

    fn output_checked_status(&mut self) -> Result<Output, InstallError>;

    fn spawn_with_cmd(self) -> Result<ChildWithCommand, InstallError>;
}

impl CommandExt for Command {
    fn formattable(&self) -> CommandFormattable<'_> {
        CommandFormattable(self)
    }

    fn output_checked_status(&mut self) -> Result<Output, InstallError> {
        self.output()
            .map_err(InstallError::from)
            .and_then(|output| check_status(self, output))
    }

    fn spawn_with_cmd(mut self) -> Result<ChildWithCommand, InstallError> {
        self.spawn()
            .map_err(InstallError::from)
            .map(move |child| ChildWithCommand { child, cmd: self })
    }
}

pub struct CommandFormattable<'a>(&'a Command);

fn needs_escape(s: &str) -> bool {
    s.contains(|ch| !matches!(ch, 'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '=' | '/' | ',' | '.' | '+'))
}

fn write_os_str(f: &mut fmt::Formatter<'_>, os_str: &OsStr) -> fmt::Result {
    let s = os_str.to_string_lossy();

    if needs_escape(&s) {
        // There is some ascii whitespace (' ', '\n', '\t'),
        // or non-ascii characters need to quote them using `"`.
        //
        // But then, it is possible for the `s` to contains `"`,
        // so they needs to be escaped.
        f.write_str("\"")?;

        for ch in s.chars() {
            if ch == '"' {
                // Escape it with `\`.
                f.write_char('\\')?;
            }

            f.write_char(ch)?;
        }

        f.write_str("\"")
    } else {
        f.write_str(&s)
    }
}

impl fmt::Display for CommandFormattable<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let cmd = self.0;

        write_os_str(f, cmd.get_program())?;

        for arg in cmd.get_args() {
            f.write_str(" ")?;
            write_os_str(f, arg)?;
        }

        Ok(())
    }
}

pub struct ChildWithCommand {
    cmd: Command,
    child: Child,
}

fn check_status(cmd: &Command, output: Output) -> Result<Output, InstallError> {
    if output.status.success() {
        Ok(output)
    } else {
        Err(CommandFailed {
            command: cmd.formattable().to_string(),
            stdout: utf8_to_string_lossy(output.stdout),
            stderr: utf8_to_string_lossy(output.stderr),
        }
        .into())
    }
}

impl ChildWithCommand {
    pub fn wait_with_output_checked_status(self) -> Result<Output, InstallError> {
        let cmd = self.cmd;

        self.child
            .wait_with_output()
            .map_err(InstallError::from)
            .and_then(|output| check_status(&cmd, output))
    }

    pub fn stdin(&mut self) -> &mut Option<process::ChildStdin> {
        &mut self.child.stdin
    }

    pub fn stdout(&mut self) -> &mut Option<process::ChildStdout> {
        &mut self.child.stdout
    }

    pub fn stderr(&mut self) -> &mut Option<process::ChildStderr> {
        &mut self.child.stderr
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cmd_format() {
        assert_eq!(
            Command::new("cargo")
                .args(["binstall", "-V"])
                .formattable()
                .to_string(),
            "cargo binstall -V"
        );
    }
}
