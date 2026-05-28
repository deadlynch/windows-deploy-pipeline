# smb-deploy-pipeline

Pipeline de deploy automatizado usando apenas recursos nativos do Windows. Sem dependencia externa, sem agente instalado nos servidores de destino, sem licenca.

## Como funciona

O pipeline monitora uma pasta de staging compartilhada via SMB. Quando detecta arquivos novos, distribui automaticamente para todos os servidores de destino configurados, faz backup dos arquivos substituidos, verifica a integridade de cada arquivo via SHA256 e registra tudo em log.

```
Dev deposita arquivo em \\fileserver\staging
        |
Task Agendada (a cada N minutos)
        |
Detecta arquivo novo?
    Sim --> backup + copia + SHA256 + log
    Nao --> encerra silenciosamente
```

## Funcionalidades

- Monitoramento automatico via Windows Task Scheduler
- Suporte a multiplos servidores de destino
- Suporte a subpastas: a estrutura do staging e espelhada no destino
- Backup automatico apenas dos arquivos substituidos, com timestamp
- Tratamento de arquivos em uso via WMI remoto
- Verificacao de integridade SHA256 pos-copia
- Rollback automatico em caso de falha de integridade
- Log por deploy e log master centralizado
- Limpeza automatica do staging apos cada ciclo

## Pre-requisitos

- Windows PowerShell 5.1 ou superior
- Permissao de escrita nos servidores de destino via UNC path
- Permissao administrativa nos servidores de destino para operacoes WMI
- Compartilhamento SMB acessivel para o servidor que roda o script

## Estrutura de pastas esperada

```
\\fileserver\deploy\
    staging-prd\         <- dev deposita aqui
    staging-hml\         <- dev deposita aqui
    Enviados\
        PRD\
            20250528_143022\
                arquivo.exe
                deploy.log
        HML\
            ...
        deploy_master.log
```

## Configuracao

Edite o bloco `$CONFIG` no inicio do script:

```powershell
$CONFIG = @{
    Staging = @{
        PRD = "\\fileserver\deploy\staging-prd"
        HML = "\\fileserver\deploy\staging-hml"
    }
    Enviados = @{
        PRD = "\\fileserver\deploy\Enviados\PRD"
        HML = "\\fileserver\deploy\Enviados\HML"
    }
    Servidores = @{
        SRV01 = "192.168.1.10"
        SRV02 = "192.168.1.11"
    }
    Destino = @{
        PRD = "C:\App\PRD"
        HML = "C:\App\HML"
    }
    Backup = "C:\App\Backups"
    Log    = "\\fileserver\deploy\Enviados\deploy_master.log"
}
```

## Registrando a Task Agendada

Execute uma vez como administrador no servidor que vai rodar o pipeline:

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
               -Argument "-NonInteractive -ExecutionPolicy Bypass -File C:\Scripts\Deploy.ps1"
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName "SMB-Deploy-Pipeline" -Action $action -Trigger $trigger `
               -Settings $settings -RunLevel Highest -Force
```

Ajuste o intervalo `-Minutes 5` conforme necessario.

## Como usar

1. Copiar os arquivos para a pasta de staging do ambiente desejado
2. Aguardar o proximo ciclo (padrao: 5 minutos)
3. Verificar o log em `Enviados\<ambiente>\<timestamp>\deploy.log`

Para subpastas, replicar a estrutura no staging:

```
staging-prd\
    app.exe              -> C:\App\PRD\app.exe
    plugins\
        plugin.dll       -> C:\App\PRD\plugins\plugin.dll
```

## Log de auditoria

Cada deploy gera entradas no formato:

```
[2025-05-28 14:30:22] [INFO] [PRD] 2 arquivo(s) detectado(s): app.exe, plugin.dll
[2025-05-28 14:30:23] [OK]   Backup: app.exe
[2025-05-28 14:30:23] [INFO] SHA256 origem  : A3F1D2B7C9E4F1A2...
[2025-05-28 14:30:24] [INFO] SHA256 destino : A3F1D2B7C9E4F1A2...
[2025-05-28 14:30:24] [OK]   app.exe - integridade confirmada
[2025-05-28 14:30:25] [OK]   [PRD] Concluido: 4 OK | 0 erro(s)
```

## Licenca

MIT
