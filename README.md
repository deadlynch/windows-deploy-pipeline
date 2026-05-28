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

## Modos de acesso

O script suporta dois modos, configurados pela variavel `$MODO_ACESSO` no topo do script.

| | UNC_ADMIN | UNC_SHARE |
|---|---|---|
| Configuracao nos servidores | Nenhuma | Criar compartilhamentos SMB |
| Escopo de acesso | Disco inteiro (C:\\) | Apenas pasta da aplicacao |
| Permissao necessaria | Administrador local | Permissao no compartilhamento |
| Indicado para | Ambientes internos controlados | Ambientes com requisitos de seguranca |

**UNC_ADMIN** usa o compartilhamento administrativo nativo do Windows (`C$`). Nao requer configuracao adicional, mas expoe o disco inteiro do servidor. Risco aceitavel em ambientes internos controlados.

**UNC_SHARE** usa um compartilhamento SMB dedicado, restrito apenas a pasta da aplicacao. Requer criacao previa em cada servidor de destino:

```powershell
New-SmbShare -Name "AppDeploy-PRD" -Path "C:\App\PRD" -FullAccess "DOMINIO\svc-deploy"
New-SmbShare -Name "AppDeploy-HML" -Path "C:\App\HML" -FullAccess "DOMINIO\svc-deploy"
New-SmbShare -Name "AppDeploy-Backup" -Path "C:\App\Backups" -FullAccess "DOMINIO\svc-deploy"
```

## Pre-requisitos

### Conta de servico

Crie uma conta de servico dedicada (ex: `svc-deploy`) com o minimo de privilegio necessario. Para o modo UNC_ADMIN, adicione-a ao grupo Administrators nos servidores de destino. Para o modo UNC_SHARE, conceda permissao apenas nos compartilhamentos criados.

Nunca use uma conta de usuario real ou o Administrator built-in.

### Compartilhamento C$ (somente UNC_ADMIN)

Verifique se o compartilhamento administrativo esta habilitado nos servidores de destino:

```powershell
Get-SmbShare -Name "C$"
```

Se estiver desabilitado, habilite via registro:

```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" `
    -Name "AutoShareWks" -Value 1 -Type DWord
Restart-Service LanmanServer
```

### Firewall

Habilite as regras necessarias nos servidores de destino:

```powershell
Enable-NetFirewallRule -DisplayGroup "File and Printer Sharing"
Enable-NetFirewallRule -DisplayGroup "Windows Management Instrumentation (WMI)"
```

### WMI remoto

O WMI e usado para encerrar processos que estejam segurando arquivos em uso. Habilite o servico nos servidores de destino:

```powershell
Set-Service -Name Winmgmt -StartupType Automatic
Start-Service Winmgmt
```

Confirme que a conta de servico tem permissao no namespace WMI:

```
wmimgmt.msc -> WMI Control (Local) -> Properties -> Security -> Root -> Security
```

Adicione a conta com permissao **Enable Account** e **Remote Enable**.

### Execution Policy

No servidor que vai rodar o script:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force
```

### Resumo

| Requisito | Onde configurar |
|---|---|
| Conta de servico dedicada | Servidores de destino |
| Compartilhamento C$ habilitado | Servidores de destino (UNC_ADMIN) |
| Compartilhamentos SMB dedicados | Servidores de destino (UNC_SHARE) |
| Firewall: File and Printer Sharing | Servidores de destino |
| Firewall: WMI | Servidores de destino |
| Servico WMI habilitado | Servidores de destino |
| Execution Policy: Bypass | Servidor que roda o script |
| Acesso de escrita ao compartilhamento SMB | Servidor de arquivos |

## Configuracao

Edite o bloco `$CONFIG` e a variavel `$MODO_ACESSO` no inicio do script:

```powershell
$MODO_ACESSO = "UNC_ADMIN"  # ou "UNC_SHARE"
$DIAS_RETENCAO_BACKUP = 30  # backups mais antigos que N dias sao removidos automaticamente

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
    Backup     = "C:\App\Backups"
    ShareNome  = @{ PRD = "AppDeploy-PRD"; HML = "AppDeploy-HML" }  # UNC_SHARE
    ShareBackup = "AppDeploy-Backup"                                  # UNC_SHARE
    Log        = "\\fileserver\deploy\Enviados\deploy_master.log"
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

Ajuste `-Minutes 5` conforme necessario. A task roda independente de usuario logado.

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

O log master centralizado acumula o historico completo em `deploy_master.log`.

## Seguranca

### Credenciais

Nunca armazene senhas em texto no script. Use o Windows Credential Manager:

```powershell
cmdkey /add:192.168.1.10 /user:DOMINIO\svc-deploy /pass:SuaSenha
cmdkey /add:192.168.1.11 /user:DOMINIO\svc-deploy /pass:SuaSenha
```

### Integridade do staging

A pasta de staging e o ponto de entrada do pipeline. Restrinja o acesso:

- Escrita: apenas a conta de servico e o time autorizado a fazer deploy
- Leitura: todos os usuarios que precisam monitorar

Em ambientes com Active Directory, use grupos de seguranca para gerenciar o acesso de forma centralizada.

### Auditoria de quem depositou arquivos

O log do pipeline registra o que foi enviado e quando, mas nao registra quem depositou o arquivo no staging. Para rastrear isso, habilite auditoria via Group Policy no servidor de arquivos:

```
Computer Configuration -> Windows Settings -> Security Settings
-> Advanced Audit Policy -> Object Access -> Audit File System: Success e Failure
```

### Assinatura SMB

Para garantir integridade no transporte, force SMB signing:

```powershell
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force
Set-SmbClientConfiguration -RequireSecuritySignature $true -Force
```

### O que o script nao resolve

O pipeline confia no que chega na pasta de staging. Nao ha validacao se o artefato e legitimo, se passou por testes ou se foi aprovado. Esse controle precisa existir no processo. Definir claramente quem pode escrever na pasta de staging e o principal mecanismo de seguranca do pipeline.

## Licenca

MIT
