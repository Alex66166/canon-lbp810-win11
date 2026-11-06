# Canon LBP-810 for Windows 11 x64

## Запуск одной командой (Windows 11)

Подключите Canon LBP-810 к USB, включите принтер, вставьте бумагу A4, откройте PowerShell и выполните **одну строку**:

~~~powershell
irm https://raw.githubusercontent.com/Alex66166/canon-lbp810-win11/main/Start-LBP810.ps1 | iex
~~~

Эта команда скачает и выполнит загрузчик из данного GitHub-репозитория; загрузчик сам скачает актуальную версию основного скрипта, запустит обнаружение USB-устройства, диагностику CAPT и **попытается распечатать одну тестовую страницу**. Никаких других ручных команд не требуется. Результаты — в консоли и в %LOCALAPPDATA%\CanonLBP810\Logs.

**Важно:** тест прямого USB/CAPT — это экспериментальный прототип, **не полноценный драйвер Windows**. На реальном Canon LBP-810 он ещё не проверен, и установка принтера для обычной печати Ctrl+P пока не реализована. Поскольку команда сразу выполняет код из GitHub, сначала ознакомьтесь с ним, если вы не доверяете репозиторию.


Experimental native printing project for the Canon LBP-810 (USB VID 04A9 / PID 260A), **without Linux, WSL, virtual machines, or old Canon x86 drivers**.

## Status: hardware-testing prototype, NOT a finished printer driver

- USB/PnP discovery, diagnostics and reporting in one PowerShell script.
- Native Windows x64 USBPRINT transport with libcapt CAPT v1 protocol.
- Offline compression self-test, printer-status request, and attempted physical A4 600 dpi test pattern.
- **Not implemented:** normal Windows printer queue, Word/Excel/PDF Ctrl+P integration, document rasterization, or permanent Windows printer installation.
- **Not yet verified on a physical LBP-810.** USB detection or a successful compile does not prove a page printed.

## Quick start on Windows 11 x64

Plug in and power on the LBP-810; load A4 paper. Open PowerShell:

~~~powershell
$path = Join-Path $env:TEMP 'Install-LBP810.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/Alex66166/canon-lbp810-win11/main/Install-LBP810.ps1' -OutFile $path
notepad $path
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path
~~~

The script checks Windows, detects the printer, downloads our built native prototype (and verifies SHA-256), performs an offline test, asks the printer for its CAPT status, and then attempts ONE physical test page. If a stage fails, it stops with a clear result. Diagnostics are saved under %LOCALAPPDATA%\CanonLBP810\Logs (never uploaded).

Read-only USB diagnostics, without downloading or printing:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LBP810.ps1 -DiagnosticOnly
~~~

Test connection only, without wasting paper:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LBP810.ps1 -SkipPrint
~~~

Script-only self-test without physical hardware:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LBP810.ps1 -SelfTest
~~~

If the dev prerelease binary is unavailable or CI fails, the script reports a blocker rather than claiming installation succeeded. It never replaces your USB driver, creates a misleading Generic/Text Only printer, or downloads unknown printer drivers.

## Building from source

Windows x64 with Visual Studio 2022 C++ tools, CMake >= 3.21, Git:

~~~powershell
cmake -S native -B build -A x64
cmake --build build --config Release
.\build\Release\lbp810-bridge.exe --self-test
.\build\Release\lbp810-bridge.exe --list
.\build\Release\lbp810-bridge.exe --status
.\build\Release\lbp810-bridge.exe --print-test
~~~

Uses pinned upstream libcapt (BSD-2-Clause). This build and USB workflow are experimental until physically validated.

## Design

Built-in Windows USB printer class driver (usbprint.sys) => SetupAPI USB interface => CreateFile / ReadFile / WriteFile => libcapt CAPT v1 and SCoA => Canon LBP-810.

The native bridge is an early **USB protocol test tool**, not an installed print queue. Standard Ctrl+P requires a Windows spooler integration, page rasterization and full job management.

## References

- https://github.com/darkvision77/libcapt
- https://learn.microsoft.com/en-us/windows-hardware/drivers/print/usb-printing
- https://learn.microsoft.com/en-us/windows-hardware/drivers/print/programming-considerations-for-usbprint
- https://files.canon-europe.com/files/soft26493/Manual/LBP810_UG_EN.PDF

Independent, community project; not affiliated with Canon.
