use std::{
    ffi::OsStr,
    fmt,
    process::{Child, Command, Output},
};

use crate::{utf8_to_string_lossy, CommandFailed, InstallError};

pub trait CommandExt {
    fn formattable(&self) -> CommandFormattable<'_>;

    fn output_checked_status(&mut self) -> Result<Output, InstallError>;

    fn spawn_with_cmd(self) -> Result<ChildWithRefToCmd, InstallError>;
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

    fn spawn_with_cmd(mut self) -> Result<ChildWithRefToCmd, InstallError> {
        self.spawn()
            .map_err(InstallError::from)
            .map(move |child| ChildWithRefToCmd { child, cmd: self })
    }
}

pub struct CommandFormattable<'a>(&'a Command);

fn write_os_str(f: &mut fmt::Formatter<'_>, os_str: &OsStr) -> fmt::Result {
    f.write_str(&os_str.to_string_lossy())
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

pub struct ChildWithRefToCmd {
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

impl ChildWithRefToCmd {
    pub fn wait_with_output_checked_status(self) -> Result<Output, InstallError> {
        let cmd = self.cmd;

        self.child
            .wait_with_output()
            .map_err(InstallError::from)
            .and_then(|output| check_status(&cmd, output))
    }
}
