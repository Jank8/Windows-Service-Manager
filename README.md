# Windows Service Manager

**Version 1.0.0**

A single-file Windows service manager with a WPF (dark theme) GUI, written in PowerShell.
It lists the services of the local machine and lets you start, stop, restart and change their
startup type without leaving the window.

Runs on the **Windows PowerShell 5.1** that ships with Windows 10/11 (and on PowerShell 7+).
No modules to install, no `pwsh` required.

## Requirements

- Windows 10 or Windows 11
- Administrator rights (the script asks for elevation through UAC and restarts itself)
- Windows PowerShell 5.1 (built in) or PowerShell 7+

## Running

```powershell
powershell.exe -File .\WindowsServiceManager.ps1
```

Or right-click the file and choose **Run with PowerShell**. The script restarts itself elevated
and in STA mode when needed, so it also works from a normal (non-elevated) console.

The console window stays open on purpose - it shows a short log of what the background
operations are doing, which is handy when a service refuses to stop.

## Features

- **Service list** with display name, service name, process, state, startup type and account.
  Click a column header to sort.
- **Live search** across name, display name, description, account, path and process name.
  Several words are combined with AND. Accents are ignored, so `usluga` also matches `Usługa`.
- **State filter**: All / Running / Stopped.
- **Start / Stop / Restart**. Dependent services are stopped first (deepest first) and, for a
  restart, started again afterwards - the confirmation dialog lists exactly what will be affected.
- **Startup type**: Automatic, Automatic (delayed), Manual, Disabled.
- **Paused services** can be resumed with Start.
- **Drivers** are detected (`Kernel Driver`, `File System Driver`, `Adapter`, `Recognizer Driver`)
  and changing the startup type of a boot/system-start driver asks for an extra confirmation.
- **Non-blocking**: every operation runs in a background runspace, the window never freezes.
  Every wait has a 60 second timeout and can be cancelled with **Esc**.
- **High DPI** aware (per-monitor v2 when the OS supports it).

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `F5` | Refresh the list |
| `Ctrl+F` | Jump to the search box |
| `Esc` | Cancel the running operation, or clear the search |
| `Enter` | Confirm a dialog |

## How it works

- The service list comes from `Get-CimInstance Win32_Service`; the display names of the running
  processes are mapped from a single `Get-Process` call.
- Operations run in a persistent runspace pool (`[powershell]::Create()` + `RunspacePool`), the UI
  polls the handle with a `DispatcherTimer`.
- `Start-Service` / `Stop-Service` wait forever while a service is stuck in `StartPending` /
  `StopPending`, so the script drives `ServiceController` itself, polls the state and enforces the
  timeout. A `CancellationTokenSource` is passed into the worker so **Esc** interrupts the wait.
- The startup type is changed with `sc.exe config ... start=`, because `Set-Service` cannot set a
  delayed automatic start.

## Notes

- Stopping or disabling critical services and drivers can make Windows unstable. The tool asks for
  confirmation, but it does not know which services are critical - treat it as a power tool.
- The script is single-file by design: copy it anywhere and run it. If you keep it in a folder that
  other (non-admin) users can write to, remember that it requests elevation.

## License

GNU General Public License v3.0 - see [LICENSE](LICENSE).
