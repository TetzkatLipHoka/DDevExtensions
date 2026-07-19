@echo off
rem D12 command-line build for DDevExtensions (Release/Win32).
rem msbuild with the D12.3 rsvars fails on this machine (MSB4066: the
rem BDS\23.0 EnvOptions.proj uses a Condition attribute the old .NET
rem Framework msbuild rejects), so build with dcc32 directly - same
rem pattern as D_7\build_d7.bat (SUBST keeps the paths short).
setlocal
if not exist T:\ subst T: "D:\Delphi\___Claude Workspace\DDevExtensions"
cd /d T:\Code\DDevExtensions\D_D120
set DCU=C:\Users\TLH\AppData\Local\Temp\d12dcu
if not exist "%DCU%" mkdir "%DCU%"
"C:\Delphi\12.3\bin\dcc32.exe" -B DDevExtensions.dpr ^
 -U"..\Source;..\Source\CompileProgress;..\Source\ProjectSettings;..\Source\IDEMenuHandler;..\Source\ExcelExport;..\Source\Keybindings;..\Source\FileCleaner;..\Source\CompileBackup;..\Source\FormDesignerHelpers;..\Source\FileSelector;..\Source\DSUFeatures;..\Source\ComponentSelector;..\Source\OldPalette;..\Source\StartParameterManager;..\Source\StartParameterTeam;..\Source\Editor;..\..\..\CompileInterceptor\Source;..\..\..\Shared;..\..\..\Shared\PascalParser;..\..\..\Shared\IDE;..\..\..\Shared\IDE\Options;..\..\..\Shared\Xml;C:\Delphi\12.3\lib\win32\release;C:\Delphi\12.3\source\ToolsAPI" ^
 -I"..\Source;..\jedi" ^
 -NSVcl;Vcl.Imaging;Vcl.Touch;Vcl.Samples;Vcl.Shell;System;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;Bde ^
 -DRELEASE ^
 -LUrtl -LUvcl -LUdesignide ^
 -E"..\Bin" ^
 -N"%DCU%"
endlocal
