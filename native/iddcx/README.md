# NexusLink IddCx virtual display

This is the Windows analog of Linux Xvfb: an extra monitor sized for a phone.
It is a UMDF2 IddCx driver. It cannot ship unsigned to other PCs.

## Build (developer machine)

1. Install Visual Studio 2022 with **Desktop development with C++**
2. Install the **Windows 11 WDK**
3. Open a VS/WDK developer prompt in this folder and compile `Driver.cpp` as a UMDF2 driver targeting `NexusLinkIdd.dll`
4. `inf2cat /driver:. /os:10_x64` then test-sign the `.cat`

## Local install (this PC only)

```bat
bcdedit /set testsigning on
:: reboot
pnputil /add-driver NexusLinkIdd.inf /install
```

Or create the software device from an elevated prompt:

```bat
devcon install NexusLinkIdd.inf NexusLink\IddDevice
```

Windows will treat the adapter as an extra monitor. The host places it to the right of the primary so the real desktop is not resized.

## Other people's PCs

Test signing is not acceptable for friends. Submit the catalog for **attestation signing** through Microsoft Partner Center using an EV code-signing certificate. `packaging/windows/sign.ps1` is the local/CI wrapper around `signtool`.
