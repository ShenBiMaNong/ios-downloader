# 准备本地 Flutter 工程：生成平台目录 + 拉依赖 + 静态检查
# 用法: powershell -File tools/prepare_project.ps1 [-FlutterRoot D:\other\proj\flutter-sdk\flutter]
param([string]$FlutterRoot = 'D:\other\proj\flutter-sdk\flutter')

$ErrorActionPreference = 'Stop'

# 国内网络镜像（pub 包 + Flutter 构件）
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'

$flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
if (-not (Test-Path $flutter)) { throw "flutter 未找到: $flutter" }

Push-Location 'D:\other\proj\downloader'
try {
  Write-Output '== flutter version =='
  & $flutter --version 2>&1

  Write-Output '== flutter create（补齐 ios/android 平台目录，不覆盖已有代码）=='
  & $flutter create --platforms=ios,android --org com.example --project-name video_downloader . 2>&1

  Write-Output '== flutter pub get =='
  & $flutter pub get 2>&1

  Write-Output '== flutter analyze =='
  & $flutter analyze 2>&1
} finally {
  Pop-Location
}
Write-Output 'DONE'
