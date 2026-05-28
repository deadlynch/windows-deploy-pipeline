# =============================================================================
# config-example.ps1
# Exemplo de configuracao do bloco $CONFIG do Deploy.ps1
# Copie e ajuste para o seu ambiente
# =============================================================================

$CONFIG = @{

    # Pastas de staging — onde os artefatos sao depositados antes do deploy
    # Utilize UNC paths (\\servidor\compartilhamento\pasta)
    Staging = @{
        PRD = "\\fileserver\deploy\staging-prd"
        HML = "\\fileserver\deploy\staging-hml"
    }

    # Pastas de historico — onde os artefatos enviados e os logs ficam armazenados
    Enviados = @{
        PRD = "\\fileserver\deploy\Enviados\PRD"
        HML = "\\fileserver\deploy\Enviados\HML"
    }

    # Servidores de destino — adicione quantos precisar
    # Chave: nome amigavel | Valor: IP ou hostname
    Servidores = @{
        SRV01 = "192.168.1.10"
        SRV02 = "192.168.1.11"
        # SRV03 = "192.168.1.12"
    }

    # Caminho local nos servidores de destino onde os artefatos serao copiados
    Destino = @{
        PRD = "C:\App\PRD"
        HML = "C:\App\HML"
    }

    # Caminho local nos servidores de destino para armazenar backups
    # Criado automaticamente se nao existir
    Backup = "C:\App\Backups"

    # Caminho do log master centralizado (UNC path recomendado)
    Log = "\\fileserver\deploy\Enviados\deploy_master.log"
}
