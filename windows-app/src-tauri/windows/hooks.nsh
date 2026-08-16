!macro NSIS_HOOK_POSTINSTALL
  ${If} ${FileExists} "$INSTDIR\${MAINBINARYNAME}.exe"
  ${AndIfNot} ${FileExists} "$INSTDIR\RemoteCanvas Host.exe"
    CopyFiles /SILENT "$INSTDIR\${MAINBINARYNAME}.exe" "$INSTDIR\RemoteCanvas Host.exe"
  ${EndIf}
!macroend
