# Creates a "Seat Picker" shortcut on your Desktop that opens the picker without a console window.
# Run once:  powershell -ExecutionPolicy Bypass -File .\install.ps1
$dir = $PSScriptRoot
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'Seat Picker.lnk'
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\Codex-Seat-Picker.ps1`""
$s.WorkingDirectory = $dir
$s.IconLocation = "$dir\assets\seat-icon.ico,0"
$s.Description = 'Seat Picker: switch Codex seats and keep projects in sync'
$s.Save()
Write-Host "Created $lnk"
if (-not (Get-Command python -ErrorAction SilentlyContinue) -and -not $env:SEAT_PICKER_PYTHON) {
    Write-Warning 'Python was not found on PATH. Install Python 3, or set SEAT_PICKER_PYTHON to your python.exe.'
}
