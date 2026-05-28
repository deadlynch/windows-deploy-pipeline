#Requires -Version 5.1

# =============================================================================
# Deploy.ps1
# SMB-based deployment pipeline using only native Windows resources
# Configure the $CONFIG block below before use
# =============================================================================

# =============================================================================
# MODO DE ACESSO AOS SERVIDORES DE DESTINO
#
# "UNC_ADMIN" : usa o compartilhamento administrativo padrao C$ do Windows
#               Nao requer configuracao adicional nos servidores de destino
#               A conta de servico precisa ser Administrador local
#               RISCO: expoe o disco inteiro do servidor
#               Indicado para ambientes internos controlados
#
# "UNC_SHARE" : usa um compartilhamento SMB dedicado criado em cada servidor
#               Acesso restrito apenas a pasta da aplicacao
#               Indicado para ambientes com requisitos de seguranca mais rigorosos
#               Requer criacao previa do compartilhamento (veja README)
# =============================================================================
$MODO_ACESSO = "UNC_ADMIN"

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
    # Usado apenas no modo UNC_ADMIN
    Backup = "C:\App\Backups"
    # Usado apenas no modo UNC_SHARE - nome do compartilhamento dedicado em cada servidor
    ShareNome = @{
        PRD = "AppDeploy-PRD"
        HML = "AppDeploy-HML"
    }
    # Usado apenas no modo UNC_SHARE - pasta de backup dentro do compartilhamento
    ShareBackup = "AppDeploy-Backup"
    Log = "\\fileserver\deploy\Enviados\deploy_master.log"
}

$_logBuffer = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param([string]$Msg, [string]$Nivel = "INFO")
    $linha = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Nivel, $Msg
    $_logBuffer.Add($linha)
    Add-Content -Path $CONFIG.Log -Value $linha -ErrorAction SilentlyContinue
    switch ($Nivel) {
        "OK"    { Write-Host "  $linha" -ForegroundColor Green }
        "AVISO" { Write-Host "  $linha" -ForegroundColor Yellow }
        "ERRO"  { Write-Host "  $linha" -ForegroundColor Red }
        default { Write-Host "  $linha" -ForegroundColor DarkGray }
    }
}

function Flush-LogParaEnviados {
    param([string]$PastaEnviados)
    $logDest = Join-Path $PastaEnviados "deploy.log"
    $_logBuffer | Add-Content -Path $logDest -ErrorAction SilentlyContinue
}

function Garantir-Pastas {
    foreach ($p in @($CONFIG.Enviados.PRD, $CONFIG.Enviados.HML)) {
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
}

function Get-Hash {
    param([string]$Caminho)
    try {
        return (Get-FileHash -Path $Caminho -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        return $null
    }
}

function Get-UNCDestino {
    param([string]$IP, [string]$CaminhoLocal, [string]$Ambiente)
    if ($MODO_ACESSO -eq "UNC_SHARE") {
        return "\\$IP\$($CONFIG.ShareNome[$Ambiente])"
    } else {
        return "\\$IP\$($CaminhoLocal -replace ':','$')"
    }
}

function Get-UNCBackup {
    param([string]$IP, [string]$Ambiente)
    if ($MODO_ACESSO -eq "UNC_SHARE") {
        return "\\$IP\$($CONFIG.ShareBackup)"
    } else {
        return "\\$IP\$($CONFIG.Backup -replace ':','$')"
    }
}

function Fazer-Backup-Arquivo {
    param([string]$IP, [string]$CaminhoCompleto, [string]$Label, [string]$Timestamp, [string]$Ambiente)
    if (-not (Test-Path $CaminhoCompleto)) { return }
    $bkpRaiz = Join-Path (Get-UNCBackup -IP $IP -Ambiente $Ambiente) "${Label}_${Timestamp}"
    try {
        if (-not (Test-Path $bkpRaiz)) {
            New-Item -ItemType Directory -Path $bkpRaiz -Force | Out-Null
        }
        $nomeArq = Split-Path $CaminhoCompleto -Leaf
        Copy-Item -Path $CaminhoCompleto -Destination (Join-Path $bkpRaiz $nomeArq) -Force
        Write-Log "Backup: $nomeArq" "OK"
    } catch {
        Write-Log "Backup falhou para $CaminhoCompleto : $_" "AVISO"
    }
}

function Liberar-Arquivo {
    param([string]$IP, [string]$NomeArquivo)
    try {
        $processos = Get-WmiObject -Class Win32_Process -ComputerName $IP -ErrorAction Stop |
            Where-Object { $_.ExecutablePath -ne $null -and $_.ExecutablePath -like "*$NomeArquivo*" }
        foreach ($proc in $processos) {
            Write-Log "Encerrando processo '$($proc.Name)' (PID $($proc.ProcessId)) em $IP" "AVISO"
            $proc.Terminate() | Out-Null
            Start-Sleep -Milliseconds 500
        }
    } catch {
        Write-Log "Nao foi possivel verificar processos em $IP : $_" "AVISO"
    }
}

function Copiar-Arquivo {
    param(
        [string]$IP,
        [string]$CaminhoDestinoBase,
        [string]$StagingBase,
        [string]$Label,
        [string]$Timestamp,
        [string]$Ambiente,
        [System.IO.FileInfo]$Arquivo
    )

    $relativo    = $Arquivo.FullName.Substring($StagingBase.Length).TrimStart('\')
    $destinoBase = Get-UNCDestino -IP $IP -CaminhoLocal $CaminhoDestinoBase -Ambiente $Ambiente
    $destinoDir  = Join-Path $destinoBase (Split-Path $relativo -Parent)
    $dest        = Join-Path $destinoBase $relativo
    $old         = "$dest.old"

    if (-not (Test-Path $destinoDir)) {
        try {
            New-Item -ItemType Directory -Path $destinoDir -Force | Out-Null
            Write-Log "Subpasta criada: $destinoDir"
        } catch {
            Write-Log "Nao foi possivel criar subpasta $destinoDir : $_" "ERRO"
            return $false
        }
    }

    $hashOrigem = Get-Hash -Caminho $Arquivo.FullName
    Write-Log "SHA256 origem  : $hashOrigem"

    if (Test-Path $old) {
        try { Remove-Item $old -Force -ErrorAction SilentlyContinue } catch {}
    }

    if (Test-Path $dest) {
        Fazer-Backup-Arquivo -IP $IP -CaminhoCompleto $dest -Label $Label -Timestamp $Timestamp -Ambiente $Ambiente
        try {
            Rename-Item -Path $dest -NewName "$($Arquivo.Name).old" -Force -ErrorAction Stop
        } catch {
            Write-Log "Arquivo em uso: $($Arquivo.Name) -- encerrando processo..." "AVISO"
            Liberar-Arquivo -IP $IP -NomeArquivo $Arquivo.Name
            Start-Sleep -Seconds 1
            try {
                Rename-Item -Path $dest -NewName "$($Arquivo.Name).old" -Force -ErrorAction Stop
            } catch {
                Write-Log "Nao foi possivel liberar $($Arquivo.Name) em $IP. Pulando." "ERRO"
                return $false
            }
        }
    }

    try {
        Copy-Item -Path $Arquivo.FullName -Destination $dest -Force -ErrorAction Stop
    } catch {
        Write-Log "Falha ao copiar $relativo para $IP : $_" "ERRO"
        if (Test-Path $old) {
            try { Rename-Item -Path $old -NewName $Arquivo.Name -Force -ErrorAction SilentlyContinue } catch {}
        }
        return $false
    }

    $hashDestino = Get-Hash -Caminho $dest
    Write-Log "SHA256 destino : $hashDestino"

    if ($hashOrigem -and $hashDestino -and $hashOrigem -eq $hashDestino) {
        Write-Log "[OK] $relativo - integridade confirmada" "OK"
        if (Test-Path $old) { try { Remove-Item $old -Force -ErrorAction SilentlyContinue } catch {} }
        return $true
    } else {
        Write-Log "INTEGRIDADE FALHOU: $relativo em $IP - hashes nao batem!" "ERRO"
        if (Test-Path $old) {
            try {
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
                Rename-Item -Path $old -NewName $Arquivo.Name -Force -ErrorAction SilentlyContinue
                Write-Log "Arquivo anterior restaurado automaticamente." "AVISO"
            } catch {}
        }
        return $false
    }
}

function Executar-Deploy {
    param([string]$Ambiente)

    $stagingPath = $CONFIG.Staging[$Ambiente]
    $arquivos    = Get-ChildItem -Path $stagingPath -File -Recurse -ErrorAction SilentlyContinue

    if (-not $arquivos -or $arquivos.Count -eq 0) {
        Write-Log "[$Ambiente] Nenhum arquivo em staging. Nada a fazer."
        return
    }

    $timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
    $enviadoPath = Join-Path $CONFIG.Enviados[$Ambiente] $timestamp
    New-Item -ItemType Directory -Path $enviadoPath -Force | Out-Null

    Write-Log "[$Ambiente] $($arquivos.Count) arquivo(s) detectado(s):"
    foreach ($arq in $arquivos) {
        $rel = $arq.FullName.Substring($stagingPath.Length).TrimStart('\')
        Write-Log "  $rel"
    }

    $totalOK = 0
    $totalErro = 0

    foreach ($srv in $CONFIG.Servidores.GetEnumerator()) {
        $nome = $srv.Key
        $ip   = $srv.Value

        Write-Log "[$Ambiente] -> $nome ($ip)"
        Write-Log "--------------------------------------------"

        if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet)) {
            Write-Log "[$Ambiente] $nome inacessivel. Pulando." "ERRO"
            $totalErro++
            continue
        }

        $bkpUNC = Get-UNCBackup -IP $ip -Ambiente $Ambiente
        if (-not (Test-Path $bkpUNC)) {
            try { New-Item -ItemType Directory -Path $bkpUNC -Force | Out-Null } catch {}
        }

        foreach ($arq in $arquivos) {
            $ok = Copiar-Arquivo -IP $ip `
                                 -CaminhoDestinoBase $CONFIG.Destino[$Ambiente] `
                                 -StagingBase $stagingPath `
                                 -Label $Ambiente `
                                 -Timestamp $timestamp `
                                 -Ambiente $Ambiente `
                                 -Arquivo $arq
            if ($ok) { $totalOK++ } else { $totalErro++ }
        }

        Write-Log "--------------------------------------------"
    }

    foreach ($arq in $arquivos) {
        $rel     = $arq.FullName.Substring($stagingPath.Length).TrimStart('\')
        $destEnv = Join-Path $enviadoPath (Split-Path $rel -Parent)
        if (-not (Test-Path $destEnv)) {
            New-Item -ItemType Directory -Path $destEnv -Force | Out-Null
        }
        try {
            Move-Item -Path $arq.FullName -Destination (Join-Path $destEnv $arq.Name) -Force
        } catch {
            Write-Log "Nao foi possivel mover $($arq.Name) para Enviados: $_" "AVISO"
        }
    }

    Get-ChildItem -Path $stagingPath -Directory -Recurse |
        Sort-Object -Property FullName -Descending |
        Where-Object { (Get-ChildItem -Path $_.FullName -Recurse -File).Count -eq 0 } |
        ForEach-Object {
            try {
                Remove-Item -Path $_.FullName -Force
                Write-Log "Subpasta removida do staging: $($_.Name)"
            } catch {
                Write-Log "Nao foi possivel remover subpasta $($_.FullName): $_" "AVISO"
            }
        }

    Flush-LogParaEnviados -PastaEnviados $enviadoPath
    Write-Log "[$Ambiente] Concluido: $totalOK OK | $totalErro erro(s)" $(if ($totalErro -gt 0) { "AVISO" } else { "OK" })
}

Write-Host ""
Write-Host "  ================================================" -ForegroundColor DarkCyan
Write-Host "     SMB Deploy Pipeline [$MODO_ACESSO]" -ForegroundColor DarkCyan
Write-Host "  ================================================" -ForegroundColor DarkCyan
Write-Host ""

Write-Log "=== Inicio do ciclo de deploy === Modo: $MODO_ACESSO"
Garantir-Pastas
Executar-Deploy -Ambiente "PRD"
Executar-Deploy -Ambiente "HML"
Write-Log "=== Ciclo finalizado ==="
Write-Host ""
