#include "Driver.h"

#include <initguid.h>

namespace {

const UINT64 IDD_DRIVER_VERSION = 0x00010000;

NTSTATUS IddSampleIoDeviceD0Entry(WDFDEVICE Device, WDF_POWER_DEVICE_STATE) {
    auto* ctx = DeviceGetContext(Device);
    ctx->InitAdapter();
    return STATUS_SUCCESS;
}

} // namespace

IndirectDeviceContext::IndirectDeviceContext(WDFDEVICE wdfDevice) : m_wdfDevice(wdfDevice) {}
IndirectDeviceContext::~IndirectDeviceContext() = default;

void IndirectDeviceContext::InitAdapter() {
    IDDCX_ADAPTER_CAPS caps{};
    caps.Size = sizeof(caps);
    caps.MaxMonitorsSupported = 2;
    caps.EndPointDiagnostics.Size = sizeof(caps.EndPointDiagnostics);
    caps.EndPointDiagnostics.GammaMode = IDDCX_FEATURE_IMPLEMENTATION_NONE;
    caps.EndPointDiagnostics.TransmissionType = IDDCX_TRANSMISSION_TYPE_WIRED_OTHER;

    IDDCX_ENDPOINT_VERSION ver{};
    ver.Size = sizeof(ver);
    ver.MajorVer = 1;
    caps.EndPointDiagnostics.pEndPointFriendlyName = L"NexusLink virtual display";
    caps.EndPointDiagnostics.pEndPointManufacturerName = L"NexusLink";
    caps.EndPointDiagnostics.pEndPointModelName = L"Phone";
    caps.EndPointDiagnostics.pFirmwareVersion = &ver;
    caps.EndPointDiagnostics.HardwareVersion.Size = sizeof(caps.EndPointDiagnostics.HardwareVersion);

    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, IndirectDeviceContext);

    IDDCX_ADAPTER_CONFIG config{};
    config.Size = sizeof(config);
    IddCxAdapterInitAsync(&caps, m_wdfDevice, &attr, &m_adapter);
}

void IndirectDeviceContext::FinishInit(UINT) {
    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT(&attr);

    IDDCX_MONITOR_INFO info{};
    info.Size = sizeof(info);
    info.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI;
    info.ConnectorIndex = 0;
    info.MonitorDescription.Size = sizeof(info.MonitorDescription);
    info.MonitorDescription.Type = IDDCX_MONITOR_DESCRIPTION_TYPE_EDID;
    info.MonitorDescription.DataSize = 0;
    info.MonitorDescription.pData = nullptr;

    IddCxMonitorCreate(m_adapter, &info, &attr, &m_monitor);

    IDDCX_MONITOR_ARRIVAL arrival{};
    arrival.Size = sizeof(arrival);
    IddCxMonitorArrival(m_monitor, &arrival);
}

NTSTATUS IndirectDeviceContext::AssignSwapChain(IDDCX_SWAPCHAIN, LUID, HANDLE) {
    return STATUS_SUCCESS;
}

extern "C" NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath) {
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, [](WDFDRIVER, PWDFDEVICE_INIT DeviceInit) -> NTSTATUS {
        WDF_PNPPOWER_EVENT_CALLBACKS pnp;
        WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
        pnp.EvtDeviceD0Entry = IddSampleIoDeviceD0Entry;
        WdfDeviceInitSetPnpPowerEventCallbacks(DeviceInit, &pnp);
        IddCxDeviceInitConfig(DeviceInit);

        WDF_OBJECT_ATTRIBUTES attr;
        WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, IndirectDeviceContext);
        WDFDEVICE device;
        NTSTATUS status = WdfDeviceCreate(&DeviceInit, &attr, &device);
        if (!NT_SUCCESS(status)) return status;
        new (DeviceGetContext(device)) IndirectDeviceContext(device);
        return IddCxDeviceInitialize(device);
    });
    return WdfDriverCreate(DriverObject, RegistryPath, WDF_NO_OBJECT_ATTRIBUTES, &config, WDF_NO_HANDLE);
}
