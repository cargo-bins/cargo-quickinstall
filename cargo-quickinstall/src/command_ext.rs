use std::{ffi::OsStr, fmt, process::Command};

pub trait CommandExt {
    fn formattable(&self) -> CommandFormattable<'_>;
}

impl CommandExt for Command {
    fn formattable(&self) -> CommandFormattable<'_> {
        CommandFormattable(self)
    }
}

impl<T: CommandExt> CommandExt for &mut T {
    fn formattable(&self) -> CommandFormattable<'_> {
        T::formattable(*self)
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
