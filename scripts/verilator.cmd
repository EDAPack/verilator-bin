@rem verilator-bin: run the Perl `verilator` script beside this file, so cmd,
@rem PowerShell and native Python (shutil.which, subprocess) can invoke it.
@rem The path is passed with forward slashes: MSYS2 perl does not treat `\` as a
@rem separator, so FindBin would mislocate the install (docs/design/windows.md).
@setlocal
@set "VLT_BIN=%~dp0"
@perl "%VLT_BIN:\=/%verilator" %*
