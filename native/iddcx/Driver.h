// NexusLink IddCx UMDF2 driver — phone-shaped virtual monitor.
// Port of Microsoft's IddSampleDriver (MIT) trimmed to one monitor whose
// mode is set from the host via a named pipe (see Driver.cpp comments).
//
// Requires: Windows Driver Kit 10, Visual Studio 2022, Windows 10 19H1+.
// Local install: enable test signing, then `devcon install NexusLinkIdd.inf NexusLink\IddDevice`.
// Shipping: attestation-sign the catalog via Microsoft Partner Center (EV cert).

#pragma once

#define NOMINMAX
#include <windows.h>
#include <wdf.h>
#include <iddcx.h>
#include <vector>

struct MonitorMode {
    DWORD width;
    DWORD height;
    DWORD vsync;
};

class IndirectDeviceContext {
public:
    explicit IndirectDeviceContext(WDFDEVICE wdfDevice);
    ~IndirectDeviceContext();
    void InitAdapter();
    void FinishInit(UINT connectorIndex);
    NTSTATUS AssignSwapChain(IDDCX_SWAPCHAIN swapChain, LUID renderAdapter, HANDLE newFrameEvent);

    static constexpr MonitorMode kModes[] = {
        { 720, 1600, 60 },
        { 1080, 2400, 60 },
        { 1080, 1920, 60 },
        { 800, 1280, 60 },
        { 1920, 1080, 60 },
    };

    WDFDEVICE m_wdfDevice = nullptr;
    IDDCX_ADAPTER m_adapter = nullptr;
    IDDCX_MONITOR m_monitor = nullptr;
};

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(IndirectDeviceContext, DeviceGetContext);
