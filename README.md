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

### Conta de servico

O script precisa rodar sob uma conta com privilegios administrativos nos servidores de destino. O recomendado e criar uma conta de servico dedicada (ex: `svc-deploy`) e adicioná-la ao grupo **Administrators** em cada servidor de destino.

### Acesso via UNC path (C$)

O script acessa os servidores de destino via compartilhamento administrativo padrao do Windows (`C$`). Para isso funcionar:

1. O compartilhamento administrativo precisa estar habilitado nos servidores de destino. Verifique com:
```powershell
Get-SmbShare -Name "C$"
```

2. Se estiver desabilitado, habilite via registro:
```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
    -Name "AutoShareWks" -Value 1 -Type DWord
Restart-Service LanmanServer
```

3. O firewall dos servidores de destino precisa permitir o compartilhamento de arquivos. Habilite a regra:
```powershell
Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing"
```

### Acesso WMI remoto

O WMI e usado para identificar e encerrar processos que estejam com arquivos bloqueados. Para habilitar nos servidores de destino:

1. Habilite o servico WMI:
```powershell
Set-Service -Name Winmgmt -StartupType Automatic
Start-Service Winmgmt
```

2. Libere o WMI no firewall:
```powershell
Enable-NetFirewallRule -DisplayGroup "Windows Management Instrumentation (WMI)"
```

3. Confirme que a conta de servico tem permissao no namespace WMI. No servidor de destino, execute:
```
wmimgmt.msc -> WMI Control (Local) -> Properties -> Security -> Root -> Security
```
Adicione a conta de servico com permissao **Enable Account** e **Remote Enable**.

### Execution Policy

No servidor que vai rodar o script (onde a task agendada sera registrada), configure a Execution Policy:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force
```

### Resumo dos pre-requisitos

| Requisito | Onde configurar |
|---|---|
| Conta com privilegios de admin | Servidores de destino |
| Compartilhamento C$ habilitado | Servidores de destino |
| Firewall: File and Printer Sharing | Servidores de destino |
| Firewall: WMI | Servidores de destino |
| Servico WMI habilitado | Servidores de destino |
| Execution Policy: Bypass | Servidor que roda o script |
| Acesso de escrita ao compartilhamento SMB | Servidor de arquivos |

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
