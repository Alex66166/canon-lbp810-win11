# First hardware test: Canon LBP-810

## Assumptions

- Physical Canon LBP-810 powered on, A4 loaded, known-good USB cable
- Direct USB connection to Windows 11 x64 (no USB print-sharing switch)
- No running Windows XP virtual machine simultaneously holding the USB device
- Windows built-in usbprint.sys is still bound; do not install Zadig/WinUSB

## Zero-impact diagnostics

1. Download Install-LBP810.ps1 from this repository.
2. Inspect it.
3. Run with -DiagnosticOnly, which only enumerates connected hardware and Windows printer queues.
4. Review local logs in %LOCALAPPDATA%\CanonLBP810\Logs.

Expected: at least one USB device with VID_04A9 / PID_260A or Canon LBP-810 friendly name. If absent, do not modify the driver; check the connection and power.

## CAPT status probe

Run with -SkipPrint. Native bridge enumerates the Windows USBPRINT interface GUID, opens the matching device using the standard Windows class driver, and requests CAPT extended status. At no point is a Windows printer queue created or a custom kernel driver installed. The script stops if native binary download, checksum, decompression self-test or CAPT request fails.

Expected: a visible ready/online status line. First real hardware run is necessary to establish whether this interface supports bidirectional CAPT read/write reliably on this machine.

## Physical print test

Run without switches. The native program sends one black-and-white A4 diagnostic page at 600dpi through libcapt, with a visible rectangular top border and eight vertical bars.

- The program may time out or the device may reject the request, particularly until we validate USBREAD behavior.
- If a CAPT command finishes without an error, still visually verify that the physical sheet exited.
- The software cannot confirm whether the printed image is positioned correctly or whether paper physically emerged. Report this observation separately.
- Do not repeat printing blindly if paper jams.

## Security

The only downloaded executable is from this repository's public dev prerelease. It is SHA-256 verified against the attached checksum. Checksum protects against transfer mismatch; it is not independent code-signing or a proof of trust. Review source and build logs before use. The script does NOT transmit logs or hardware identifiers.

Do not publish the full diagnostics without removing hostnames and device serial numbers.

## Current limitation

This stage proves the USB/CAPT transport and tests a single generated pattern. A normal Windows printer driver, printer queue, document rendering (Word/Excel/PDF) and stable background print service are **not** yet implemented. This distinction is intentional.


## Verified model identification (Canon LBP-810)

The front panel labeled "LBP-810 / Automatic Image Refinement" is the expected Canon LBP-810, not LBP-800, LBP-1120, or LBP-2900. The Canon manual documents USB and parallel connections, and device logs show VID 04A9 / PID 260A.

- Canon official user guide: https://files.canon-europe.com/files/soft26493/Manual/LBP810_UG_EN.PDF
- Debian report with real USB descriptors: https://lists.debian.org/debian-printing/2022/08/msg00037.html
- Related USB/CUPS issue: https://github.com/OpenPrinting/cups/issues/80
- libcapt implementation and hardware claims: https://github.com/darkvision77/libcapt
- captppd with libusb transport: https://github.com/darkvision77/captppd
- Owner discussions of Windows x64 problems: https://radiokot.ru/forum/viewtopic.php?t=164379

Windows USBPRINT bidirectional transport remains **UNVERIFIED** on a physical LBP-810. Other software working through a different USB backend does not guarantee our Windows bridge works.

## Safety improvements after review

- Exact VID:PID match was confirmed.
- A test page now requires progress of the CAPT Printed counter and subsequent printer idle; simply writing bytes never counts as print completion.
- Best-effort GoOffline and ReleaseUnit cleanup on failure.
- PowerShell checks the latest dev release checksum before using a locally cached binary.
- First run should use -DiagnosticOnly; default mode attempts ONE test page after successful status handshake.
- No USB driver reassignment, unsigned kernel drivers or arbitrary driver installers.
