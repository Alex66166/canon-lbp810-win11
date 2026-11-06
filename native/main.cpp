// Windows x64 USB/CAPT protocol prototype for Canon LBP-810.
// Not a Windows printer driver or spooler integration.
// Uses usbprint.sys's GUID_DEVINTERFACE_USBPRINT, never replaces a USB driver.
// CAPT/SCoA protocol implementation: darkvision77/libcapt (BSD-2-Clause).
#include <windows.h>
#include <setupapi.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cwctype>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <stop_token>
#include <streambuf>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "libcapt/BasicCaptPrinter.hpp"
#include "libcapt/Compression/ScoaStreambuf.hpp"
#include "libcapt/Protocol/Enums.hpp"
#include "libcapt/Protocol/ExtendedStatus.hpp"
#include "libcapt/Protocol/PageParams.hpp"
#include "libcapt/Protocol/ReprintStatus.hpp"
#include "libcapt/Utility/BufferedPage.hpp"

namespace {
constexpr unsigned kPageWidth = 4960;
constexpr unsigned kPageHeight = 7014;
constexpr unsigned kLineSize = kPageWidth / 8;

// This GUID is defined by usbprint.h (Microsoft).
const GUID kUsbPrinterInterface =
    {0x28d78fad, 0x5a12, 0x11d1, {0xae, 0x5b, 0x00, 0x00, 0xf8, 0x03, 0xa8, 0xc2}};

std::wstring upper(std::wstring s) {
    std::transform(s.begin(), s.end(), s.begin(), [](wchar_t c) { return std::towupper(c); });
    return s;
}

std::vector<std::wstring> enumerateLbp810() {
    std::vector<std::wstring> found;
    HDEVINFO info = SetupDiGetClassDevsW(
        &kUsbPrinterInterface, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (info == INVALID_HANDLE_VALUE) {
        throw std::runtime_error("SetupDiGetClassDevsW failed");
    }
    for (DWORD index = 0;; ++index) {
        SP_DEVICE_INTERFACE_DATA data{};
        data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInterfaces(info, nullptr, &kUsbPrinterInterface, index, &data)) {
            if (GetLastError() != ERROR_NO_MORE_ITEMS) {
                std::cerr << "Warning: failed to enumerate an interface: " << GetLastError() << '\n';
            }
            break;
        }
        DWORD needed = 0;
        SetupDiGetDeviceInterfaceDetailW(info, &data, nullptr, 0, &needed, nullptr);
        if (needed < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;
        std::vector<unsigned char> buffer(needed);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(buffer.data());
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
        if (!SetupDiGetDeviceInterfaceDetailW(info, &data, detail, needed, nullptr, nullptr)) {
            std::cerr << "Warning: failed to read USB interface: " << GetLastError() << '\n';
            continue;
        }
        std::wstring path(detail->DevicePath);
        const auto id = upper(path);
        if (id.find(L"VID_04A9&PID_260A") != std::wstring::npos) {
            found.emplace_back(std::move(path));
        }
    }
    SetupDiDestroyDeviceInfoList(info);
    return found;
}

std::string utf8(const std::wstring& s) {
    if (s.empty()) return {};
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return "<conversion failed>";
    std::string output(static_cast<size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.c_str(), -1, output.data(), bytes, nullptr, nullptr);
    output.pop_back();
    return output;
}

class UsbPrintStreambuf final : public std::streambuf {
    HANDLE handle_ = INVALID_HANDLE_VALUE;
    std::array<char, 8192> out_{};
    char input_ = 0;

    bool flushBuffer() {
        if (handle_ == INVALID_HANDLE_VALUE) return false;
        const auto pending = static_cast<DWORD>(pptr() - pbase());
        DWORD offset = 0;
        while (offset < pending) {
            DWORD done = 0;
            if (!WriteFile(handle_, pbase() + offset, pending - offset, &done, nullptr) || done == 0) {
                return false;
            }
            offset += done;
        }
        setp(out_.data(), out_.data() + out_.size() - 1);
        return true;
    }

protected:
    int_type overflow(int_type ch = traits_type::eof()) override {
        if (!traits_type::eq_int_type(ch, traits_type::eof())) {
            *pptr() = traits_type::to_char_type(ch);
            pbump(1);
        }
        return flushBuffer() ? traits_type::not_eof(ch) : traits_type::eof();
    }
    int sync() override { return flushBuffer() ? 0 : -1; }

    int_type underflow() override {
        if (gptr() < egptr()) return traits_type::to_int_type(*gptr());
        if (handle_ == INVALID_HANDLE_VALUE) return traits_type::eof();
        DWORD got = 0;
        if (!ReadFile(handle_, &input_, 1, &got, nullptr) || got != 1) return traits_type::eof();
        setg(&input_, &input_, &input_ + 1);
        return traits_type::to_int_type(*gptr());
    }
    std::streamsize xsgetn(char* dest, std::streamsize count) override {
        if (count <= 0) return 0;
        std::streamsize copied = 0;
        while (gptr() < egptr() && copied < count) {
            dest[copied++] = *gptr();
            gbump(1);
        }
        while (copied < count) {
            DWORD got = 0;
            const auto ask = static_cast<DWORD>(std::min<std::streamsize>(count - copied, 4096));
            if (!ReadFile(handle_, dest + copied, ask, &got, nullptr) || got == 0) break;
            copied += got;
        }
        return copied;
    }

public:
    UsbPrintStreambuf() { setp(out_.data(), out_.data() + out_.size() - 1); }
    ~UsbPrintStreambuf() override { close(); }
    UsbPrintStreambuf(const UsbPrintStreambuf&) = delete;
    UsbPrintStreambuf& operator=(const UsbPrintStreambuf&) = delete;

    void open(const std::wstring& path) {
        handle_ = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
        if (handle_ == INVALID_HANDLE_VALUE) {
            throw std::runtime_error("CreateFileW(USBPRINT) failed, Windows error " +
                                     std::to_string(GetLastError()));
        }
    }
    void close() {
        if (handle_ != INVALID_HANDLE_VALUE) {
            flushBuffer();
            CloseHandle(handle_);
            handle_ = INVALID_HANDLE_VALUE;
        }
    }
};

Capt::PageParams testParams() {
    return Capt::PageParams{
        .PaperSize = 0x09,
        .TonerDensity = 0x3f,
        .Mode = 0,
        .Resolution = Capt::ResolutionIdx::RES_600,
        .SmoothEnable = true,
        .TonerSaving = false,
        .MarginLeft = 1,
        .MarginTop = 1,
        .ImageLineSize = static_cast<uint16_t>(kLineSize),
        .ImageLines = static_cast<uint16_t>(kPageHeight),
        .PaperWidth = static_cast<uint16_t>(kPageWidth),
        .PaperHeight = static_cast<uint16_t>(kPageHeight)
    };
}

std::string makePattern() {
    std::string bytes(kLineSize * kPageHeight, '\0');
    auto pixel = [&](unsigned x, unsigned y) {
        if (x >= kPageWidth || y >= kPageHeight) return;
        auto& dest = bytes[static_cast<size_t>(y) * kLineSize + x / 8];
        dest = static_cast<char>(static_cast<unsigned char>(dest) | (0x80U >> (x & 7U)));
    };
    // Small, recognizable non-blank diagnostic pattern, near the top of A4.
    for (unsigned x = 420; x < 4540; ++x) {
        for (unsigned y = 420; y < 430; ++y) pixel(x, y);
        for (unsigned y = 1400; y < 1410; ++y) pixel(x, y);
    }
    for (unsigned y = 420; y < 1410; ++y) {
        for (unsigned x = 420; x < 430; ++x) pixel(x, y);
        for (unsigned x = 4530; x < 4540; ++x) pixel(x, y);
    }
    for (unsigned bar = 0; bar < 8; ++bar) {
        for (unsigned y = 600; y < 1240; ++y) {
            const unsigned startX = 660 + bar * 470;
            for (unsigned x = startX; x < startX + 80 + bar * 14; ++x) {
                pixel(x, y);
            }
        }
    }
    return bytes;
}

int selfTest() {
    auto bitmap = makePattern();
    std::stringbuf raw(std::move(bitmap), std::ios::in | std::ios::binary);
    Capt::Compression::ScoaStreambuf encoder(raw, kLineSize, kPageHeight);
    Capt::Utility::BufferedPage page(0, testParams(), &encoder);
    std::array<char, 4096> block{};
    std::size_t encodedBytes = 0;
    while (true) {
        const std::streamsize n = page.sgetn(block.data(), block.size());
        if (n <= 0) break;
        encodedBytes += static_cast<size_t>(n);
    }
    if (encodedBytes == 0) {
        std::cerr << "SELFTEST FAIL: empty SCoA output\n";
        return 9;
    }
    std::cout << "SELFTEST OK: A4 monochrome 600dpi; SCoA bytes=" << encodedBytes << '\n';
    return 0;
}

void printStatus(const Capt::ExtendedStatus& status) {
    std::cout << "CAPT status: ready=" << status.Ready()
              << " online=" << status.Online()
              << " reserved=" << status.UnitReserved()
              << " printing=" << status.IsPrinting()
              << " fatal=" << status.FatalError()
              << " paperbits=" << static_cast<unsigned>(status.PaperAvailableBits)
              << '\n';
}

int statusOrPrint(const std::wstring& path, bool print) {
    UsbPrintStreambuf device;
    device.open(path);
    std::iostream stream(&device);
    Capt::BasicCaptPrinter<std::stop_token> printer(stream);
    const auto initial = printer.GetStatus();
    printStatus(initial);
    if (!print) return 0;
    if (!initial.Ready() || initial.FatalError()) {
        std::cerr << "Not ready; will not print (paper, cover, cartridge or device error)\n";
        return 5;
    }

    auto bitmap = makePattern();
    std::stringbuf raw(std::move(bitmap), std::ios::in | std::ios::binary);
    Capt::Compression::ScoaStreambuf encoder(raw, kLineSize, kPageHeight);
    Capt::Utility::BufferedPage page(0, testParams(), &encoder);

    printer.ReserveUnit();
    printer.ClearError();
    if (!printer.GoOnline(0)) {
        printer.ReleaseUnit();
        std::cerr << "Failed to switch printer to online mode\n";
        return 6;
    }
    std::cout << "Sending one CAPT test page...\n";
    if (!printer.WriteVideoData(page.Params, page)) {
        std::cerr << "CAPT video data rejected\n";
        return 7;
    }
    auto final = printer.WaitPrintEnd(std::stop_token{});
    if (!final || final->VideoDataError() || final->Rejected()) {
        std::cerr << "CAPT reported a page error or rejected the page\n";
        return 8;
    }
    printStatus(*final);
    printer.GoOffline();
    printer.ReleaseUnit();
    std::cout << "CAPT JOB COMPLETE (software protocol); check printed sheet physically.\n";
    return 0;
}
} // namespace

int main(int argc, char** argv) {
    try {
        const std::string command = argc >= 2 ? argv[1] : "";
        if (command == "--self-test") return selfTest();
        if (command != "--list" && command != "--status" && command != "--print-test") {
            std::cerr << "Usage: lbp810-bridge.exe --self-test | --list | --status | --print-test\n";
            return 1;
        }
        auto matches = enumerateLbp810();
        if (command == "--list") {
            for (const auto& path : matches) std::cout << "LBP810 USBPRINT: " << utf8(path) << '\n';
            std::cout << "COUNT=" << matches.size() << '\n';
            return matches.empty() ? 2 : 0;
        }
        if (matches.size() != 1) {
            std::cerr << "Expected exactly one LBP-810 USBPRINT interface, got " << matches.size() << '\n';
            return 2;
        }
        return statusOrPrint(matches.front(), command == "--print-test");
    } catch (const std::exception& e) {
        std::cerr << "BRIDGE ERROR: " << e.what() << '\n';
        return 10;
    }
}
