; ============================================================
; Yeahbear（耶熊）PC 客户端 安装脚本（Inno Setup 6）
; 打包命令：
;   ISCC.exe yeahbear_setup.iss
; 产物：build\installer\Yeahbear_Setup_0.1.2.exe
; ============================================================
#define MyAppName "耶熊"
#define MyAppVersion "0.1.2"
#define MyAppExeName "Yeahbear.exe"
#define MyAppPublisher "Yeahbear"

[Setup]
; 唯一安装标识（勿改，升级版本沿用）
AppId={{C1D3B65B-43D7-4357-8B84-0218D079890F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
; 默认安装目录：D:\Yeahbear
DefaultDirName=D:\Yeahbear
; 安装向导允许用户修改安装目录（默认填 D:\Yeahbear）
DisableDirPage=no
; 不创建程序组页（仍会创建开始菜单快捷方式）
DisableProgramGroupPage=yes
OutputDir=build\installer
OutputBaseFilename=Yeahbear_Setup_{#MyAppVersion}
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; 最低权限安装（不弹 UAC），D:\Yeahbear 标准用户可写
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; 卸载时自动请求关闭正在运行的客户端进程（Restart Manager）
CloseApplications=yes
CloseApplicationsFilter=Yeahbear.exe

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
; 打包 Flutter Release 全量产物（exe + dll + data）
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[UninstallRun]
; 卸载前强制结束客户端进程（防止 exe/dll 被占用导致删不干净）。
; 找不到进程时 taskkill 报错，用 cmd 包裹忽略错误继续卸载。
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM Yeahbear.exe >nul 2>&1"; Flags: runhidden

[UninstallDelete]
; 卸载最后兜底：清空整个安装目录（含卸载后残留的日志/缓存文件）
Type: filesandordirs; Name: "{app}"

[Icons]
; 桌面快捷方式"耶熊"（当前用户桌面）
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"
; 开始菜单快捷方式
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"

[Run]
; 安装完成后勾选启动
Filename: "{app}\{#MyAppExeName}"; Description: "立即运行 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
// 安装开始时自动结束旧版客户端进程（覆盖安装/升级场景）。
// 配合 [Setup] 的 CloseApplications 双保险，确保 exe/dll 不被旧进程占用。
procedure KillYeahbear;
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/F /IM Yeahbear.exe /T', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  KillYeahbear;
end;
