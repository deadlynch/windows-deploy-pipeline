# =============================================================================
# register-task.ps1
# Registra a task agendada no Windows Task Scheduler
# Execute uma vez como administrador no servidor que vai rodar o pipeline
# =============================================================================

# Caminho completo do script de deploy
$scriptPath = "C:\Scripts\Deploy.ps1"

# Intervalo de execucao em minutos
$intervaloMinutos = 5

# Nome da task no Task Scheduler
$nomeDaTask = "SMB-Deploy-Pipeline"

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""

$trigger = New-ScheduledTaskTrigger `
    -RepetitionInterval (New-TimeSpan -Minutes $intervaloMinutos) `
    -Once `
    -At (Get-Date)

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $nomeDaTask `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -RunLevel Highest `
    -Force

Write-Host "Task '$nomeDaTask' registrada com sucesso." -ForegroundColor Green
Write-Host "Intervalo: $intervaloMinutos minuto(s)" -ForegroundColor DarkGray
Write-Host "Script   : $scriptPath" -ForegroundColor DarkGray
