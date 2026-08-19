!define PRODUCT "NexusLink"
!define PUBLISHER "NexusLink"
!ifndef HOST_DIR
  !define HOST_DIR "..\..\dist\windows"
!endif

Name "${PRODUCT} Host"
OutFile "..\..\dist\NexusLink-Host-Setup.exe"
InstallDir "$PROGRAMFILES64\NexusLink"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

Page directory
Page instfiles

Section "Install"
  SetOutPath "$INSTDIR"
  File "${HOST_DIR}\nexuslink-host.exe"
  File /nonfatal "${HOST_DIR}\nexuslink-sidecar.exe"
  File /nonfatal "${HOST_DIR}\conpty-host.exe"
  File /r "${HOST_DIR}\www"

  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name=NexusLink'
  nsExec::ExecToLog 'netsh advfirewall firewall add rule name=NexusLink dir=in action=allow protocol=TCP localport=45678'
  nsExec::ExecToLog 'netsh advfirewall firewall add rule name="NexusLink mDNS" dir=in action=allow protocol=UDP localport=5353'

  CreateDirectory "$SMPROGRAMS\NexusLink"
  CreateShortCut "$SMPROGRAMS\NexusLink\NexusLink Host.lnk" "$INSTDIR\nexuslink-host.exe"
  CreateShortCut "$DESKTOP\NexusLink Host.lnk" "$INSTDIR\nexuslink-host.exe"

  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\NexusLink" "DisplayName" "NexusLink Host"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\NexusLink" "UninstallString" "$INSTDIR\uninstall.exe"
  WriteUninstaller "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name=NexusLink'
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="NexusLink mDNS"'
  Delete "$SMPROGRAMS\NexusLink\NexusLink Host.lnk"
  RMDir "$SMPROGRAMS\NexusLink"
  Delete "$DESKTOP\NexusLink Host.lnk"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\NexusLink"
  RMDir /r "$INSTDIR"
SectionEnd
