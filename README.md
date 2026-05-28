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

## Modos de acesso aos servidores de destino

O script suporta dois modos, configurados pela variavel `$MODO_ACESSO` no topo do script.

### UNC_ADMIN (padrao)

Acessa os servidores via compartilhamento administrativo nativo do Windows (`C$`). Nao requer configuracao adicional nos servidores de destino, mas a conta de servico precisa ser Administrador local.

**Risco:** o `C$` expoe o disco inteiro do servidor. Uma conta comprometida tem acesso total a `C:\`.

Indicado para ambientes internos controlados onde o risco e aceitavel.

### UNC_SHARE (recomendado para ambientes com requisitos de seguranca)

Acessa os servidores via compartilhamento SMB dedicado, restrito apenas a pasta da aplicacao. Requer criacao previa do compartilhamento em cada servidor de destino:

```powershell
# Execute em cada servidor de destino
New-SmbShare -Name "AppDeploy-PRD" -Path "C:\App\PRD" -FullAccess "DOMINIO\svc-deploy"
New-SmbShare -Name "AppDeploy-HML" -Path "C:\App\HML" -FullAccess "DOMINIO\svc-deploy"
New-SmbShare -Name "AppDeploy-Backup" -Path "C:\App\Backups" -FullAccess "DOMINIO\svc-deploy"
```

Depois ajuste `$MODO_ACESSO` no script:

```powershell
$MODO_ACESSO = "UNC_SHARE"
```

E configure os nomes dos compartilhamentos no `$CONFIG`:

```powershell
ShareNome = @{
    PRD = "AppDeploy-PRD"
    HML = "AppDeploy-HML"
}
ShareBackup = "AppDeploy-Backup"
```

### Comparativo

| | UNC_ADMIN | UNC_SHARE |
|---|---|---|
| Configuracao nos servidores | Nenhuma | Criar compartilhamentos SMB |
| Escopo de acesso | Disco inteiro (C:\) | Apenas pasta da aplicacao |
| Permissao necessaria | Administrador local | Permissao no compartilhamento |
| Indicado para | Ambientes internos controlados | Ambientes com requisitos de seguranca |

## Seguranca

### Conta de servico

Nunca execute o script sob uma conta de usuario real ou sob o Administrator built-in. Crie uma conta de servico dedicada com o minimo de privilegio necessario:

- Permissao de escrita na pasta de staging
- Permissao de escrita nas pastas de destino nos servidores
- Permissao administrativa nos servidores de destino apenas se usar WMI para liberar arquivos em uso

### Credenciais

Nunca armazene senhas em texto no script. Use o Windows Credential Manager para armazenar as credenciais da conta de servico:

```powershell
cmdkey /add:192.168.1.10 /user:DOMINIO\svc-deploy /pass:SuaSenha
cmdkey /add:192.168.1.11 /user:DOMINIO\svc-deploy /pass:SuaSenha
```

A task agendada usa as credenciais armazenadas automaticamente, sem expor nada no codigo.

### Integridade do staging

A pasta de staging e o ponto de entrada do pipeline. Qualquer pessoa com permissao de escrita nela pode distribuir arquivos para todos os servidores de destino. Restrinja o acesso:

- Leitura: todos os usuarios que precisam monitorar
- Escrita: apenas a conta de servico e o time autorizado a fazer deploy

Em ambientes com Active Directory, use grupos de seguranca para gerenciar isso de forma centralizada.

### Auditoria de acesso ao staging

O log do pipeline registra o que foi enviado e quando, mas nao registra quem depositou o arquivo no staging. Para rastrear isso, habilite auditoria de acesso a objeto no servidor de arquivos via Group Policy:

```
Computer Configuration
  -> Windows Settings
    -> Security Settings
      -> Advanced Audit Policy
        -> Object Access
          -> Audit File System: Success e Failure
```

Os eventos ficam registrados no Event Viewer do servidor de arquivos e podem ser correlacionados com os logs do pipeline.

### Assinatura SMB

O SMB por padrao pode trafegar sem assinatura dependendo da versao e configuracao do ambiente. Para garantir integridade no transporte, force SMB signing nos servidores:

```powershell
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force
Set-SmbClientConfiguration -RequireSecuritySignature $true -Force
```

### Retencao de backups

O script cria uma pasta de backup por ciclo de deploy. Sem politica de retencao, o disco dos servidores de destino pode lotar com o tempo. O script inclui uma rotina de limpeza automatica configuravel pela variavel `$DIAS_RETENCAO_BACKUP` no topo do script. O padrao e 30 dias.

### O que o script nao resolve

O pipeline confia no que chega na pasta de staging. Nao ha validacao se o artefato e legitimo, se passou por testes ou se foi aprovado. Esse controle precisa existir no processo, nao no script. Definir claramente quem pode escrever na pasta de staging e o principal mecanismo de seguranca do pipeline.
