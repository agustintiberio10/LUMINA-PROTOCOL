# INSTRUCCIONES — Reemplazar GitHub repo con V2

## Paso 1: Descargar esta carpeta LUMINA-PROTOCOL-V2

## Paso 2: En tu PC, ir al repo clonado y limpiar
```powershell
cd C:\Users\AGUSTIN\Desktop\LUMINA-PROTOCOL   # o donde tengas el clone
git checkout main

# Borrar todo excepto .git/
Get-ChildItem -Exclude .git | Remove-Item -Recurse -Force
```

## Paso 3: Copiar los archivos V2
```powershell
# Copiar todo el contenido de LUMINA-PROTOCOL-V2 aquí
Copy-Item -Path "LUMINA-PROTOCOL-V2\*" -Destination "." -Recurse
```

## Paso 4: IMPORTANTE — Verificar child vaults
Los 4 child vaults (VolatileShort, VolatileLong, StableShort, StableLong) los 
reconstruí yo basándome en BaseVault. Si los que tenés en "contratos valulats" 
tienen diferencias (distinto naming, extra logic), reemplazá los míos:

```powershell
# Copiar tus child vaults auditados sobre los míos
Copy-Item "C:\Users\AGUSTIN\Desktop\contratos valulats\VolatileShortVault.sol" "src\vaults\"
Copy-Item "C:\Users\AGUSTIN\Desktop\contratos valulats\VolatileLongVault.sol" "src\vaults\"
Copy-Item "C:\Users\AGUSTIN\Desktop\contratos valulats\StableShortVault.sol" "src\vaults\"
Copy-Item "C:\Users\AGUSTIN\Desktop\contratos valulats\StableLongVault.sol" "src\vaults\"
```

## Paso 5: Instalar dependencias Foundry
```powershell
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
forge install smartcontractkit/chainlink
```

## Paso 6: Compilar
```powershell
forge build
```

Si hay errores de import, revisá que los remappings en foundry.toml matcheen 
con las carpetas en lib/.

## Paso 7: Commitear y pushear
```powershell
git add -A
git commit -m "V2: Complete contracts redesign - 24 contracts, 4825 lines, 3 phases audited"
git push origin main
```

## Estructura final del repo
```
LUMINA-PROTOCOL/
├── .gitignore
├── README.md
├── foundry.toml
├── lib/                    ← creado por forge install
│   ├── openzeppelin-contracts/
│   ├── openzeppelin-contracts-upgradeable/
│   └── chainlink/
├── src/
│   ├── interfaces/  (7)   IAggregatorV3, ICoverRouter, IOracle, IPhalaVerifier, 
│   │                       IPolicyManager, IShield, IVault
│   ├── core/        (2)   CoverRouter v6, PolicyManager v3
│   ├── vaults/      (5)   BaseVault + 4 child vaults
│   ├── products/    (5)   BaseShield + BSS + Depeg + IL + Exploit
│   ├── oracles/     (2)   LuminaOracle, LuminaPhalaVerifier
│   └── libraries/   (3)   PremiumMath, ILMath, USDYConverter
└── test/                   ← Fase 4 (próximo paso)
```
