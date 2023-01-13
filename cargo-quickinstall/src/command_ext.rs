use std::{
    ffi::OsStr,
    fmt,
    process::{Command, Output},
};

use crate::{utf8_to_string_lossy, CommandFailed, InstallError};

pub trait CommandExt {
    fn formattable(&self) -> CommandFormattable<'_>;

    fn output_checked_status(&mut self) -> Result<Output, InstallError>;
}

impl CommandExt for Command {
    fn formattable(&self) -> CommandFormattable<'_> {
        CommandFormattable(self)
    }

    fn output_checked_status(&mut self) -> Result<Output, InstallError> {
        let output = self.output()?;

        if output.status.success() {
            Ok(output)
        } else {
            Err(CommandFailed {
                command: self.formattable().to_string(),
                stdout: utf8_to_string_lossy(output.stdout),
                stderr: utf8_to_string_lossy(output.stderr),
            }
            .into())
        }
    }
}

impl<T: CommandExt> CommandExt for &mut T {
    fn formattable(&self) -> CommandFormattable<'_> {
        T::formattable(*self)
    }

    fn output_checked_status(&mut self) -> Result<Output, InstallError> {
        T::output_checked_status(*self)
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
