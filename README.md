# WindowsDebloat

[![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4?style=for-the-badge&logo=windows&logoColor=white)](https://www.microsoft.com/windows)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Interactive Menu](https://img.shields.io/badge/Modo-Interativo-0078D42D9F2D?style=for-the-badge)](#usage)
[![Backup + Restore](https://img.shields.io/badge/Seguro-Backup%20%2B%20Restauração-FF9800?style=for-the-badge)](#backup-and-restore)

WindowsDebloat e um script PowerShell interativo para remover bloatware opcional e aplicar tweaks de privacidade e interface no Windows 10/11.

Ele foi feito para ser rapido, simples e reversivel:

- menu interativo
- elevação automática (UAC)
- backup por sessão
- restore para mudanças de registro e servicos
- **Deep tweaks** opcionais (ficheiro separado `DeepTweaks.ps1`, carregado por *dot-sourcing* no arranque do script principal)

> [!WARNING]
> O script altera configurações do sistema (registro, servicos e apps). Use por sua conta e risco.  
> Recomendo testar primeiro em VM/Sandbox.

Este projeto te ajudou? Apoie meu trabalho:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/ronyg)

## Uso:

### Método rápido:

1. Baixe o projeto (ZIP) ou clone o repositorio.
2. Abra a pasta do projeto.
3. Execute `Run-Debloat-As-Admin.cmd`.
4. Aceite o UAC e siga o menu.

### Método tradicional:

1. Abra PowerShell como administrador.
2. Navegue para a pasta do projeto.
3. Rode:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-WindowsDebloat.ps1
```

### Método avançado:

Para PowerShell 7:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Invoke-WindowsDebloat.ps1
```

## Implementações

### Remoção de apps:

- Remove apps opcionais do usuario atual.
- Remove apps provisionados para novos perfis (opcional, mais agressivo).

### Ajustes de privacidade:

- Telemetry policies
- Advertising ID
- Tailored experiences
- Activity feed policies
- Consumer features policy
- Servicos: `DiagTrack`, `dmwappushservice`, `lfsvc`

### UI e Personalizações:

- Context menu classico (Windows 11)
- Hide Recommended no Start (Windows 11)
- Disable Copilot policy (Windows 11)
- Taskbar alinhada a esquerda (Windows 11)
- Dark mode (apps + sistema)

### Segurança e Rollback:

- Backup automatico de mudanças reversiveis em JSON
- Restaura por sessão com aplicacao em ordem reversa

### Deep tweaks (agressivos):

Funcoes extra em [`DeepTweaks.ps1`](DeepTweaks.ps1), carregadas automaticamente quando o ficheiro esta na mesma pasta que `Invoke-WindowsDebloat.ps1`. Cada passo usa o mesmo fluxo `Invoke-TweakStep` + helpers com backup.

- **Performance / energia:** efeitos visuais, animacoes, transparencia, Fast Startup, plano alto desempenho, hibernacao off, servicos SysMain, WSearch, Fax, RemoteRegistry (se existirem).
- **Gaming:** Game DVR / Game Bar, Game Mode, rato (sem "enhance pointer precision"), `HwSchMode` (GPU scheduling) em builds suportadas.
- **Rede:** `NetworkThrottlingIndex`, `SystemResponsiveness`, LLMNR/multicast, Delivery Optimization, ajustes TCP por interface.
- **Privacidade extra:** Cortana / pesquisa web em politica, widgets, CEIP, Windows Error Reporting, feedback.
- **Hardening:** SMBv1 (feature opcional), AutoRun, Windows Script Host, Remote Assistance, **negar RDP recebido** (`fDenyTSConnections`).

> [!CAUTION]
> Os **deep tweaks** (submenu **A**) sao **muito mais agressivos** que as opcoes 1-8. So entre se for de proposito. Use restore (`R`) para reverter. Parte das alteracoes pode exigir **reinicio**.

## Menu:

### Principal (alto nivel)

Os menus usam **setas para cima/baixo** e **ENTER** para confirmar (estilo aplicativo). **ESC** no menu principal sai do script; no submenu Advanced / Deep tweaks e na lista de restore, **ESC** cancela / volta. Se a consola nao suportar `ReadKey` (ex.: entrada redireccionada), o script faz *fallback* para escolha por numero.

1. Remove optional pre-installed apps (current user)
2. Remove optional apps for NEW profiles (provisioned)
3. Privacy: telemetry, ads ID, activity feed, location service
4. UI: classic right-click, hide Start recommendations, disable Copilot
5. Taskbar: align icons to the LEFT
6. Appearance: enable dark mode
7. Extras: show file extensions, reduce lock screen tips
8. Run ALL safe tweaks (1,3,4,5,6,7)  
**A)** Advanced / Deep tweaks (abre submenu; agressivo; mesmo backup/restore)

R. Restore from backup file  
L. List backup files  
Q. Quit

### Submenu Advanced / Deep tweaks

Apos escolher **A** no menu principal:

| Opcao | Descricao |
|-------|-----------|
| **1** | Deep performance (visual effects, services, power, hibernation...) |
| **2** | Deep gaming (Game DVR, mouse accel, GPU scheduling...) |
| **3** | Deep network (LLMNR, Delivery Optimization, TCP tweaks...) |
| **4** | Deep privacy extra (Cortana/search web, error reporting...) |
| **5** | Security hardening (SMBv1, Remote Assistance, RDP...) |
| **6** | Run **all** deep tweaks (1-5 em sequencia), com confirmacao `y/N` |
| **B** | Back to main menu |

## Perfil padrão:

A opcao `8` roda um perfil rapido e seguro para maioria dos usuarios:

- opcao 1 (apps do usuario atual)
- opcao 3 (privacy)
- opcao 4 (UI)
- opcao 5 (taskbar left)
- opcao 6 (dark mode)
- opcao 7 (extras)

Ela nao executa a opcao `2` (provisioned removal).

## Aplicativos afetados por essa otimização:

Os apps abaixo estao na lista padrão de remoção (`Get-BloatPackageNames`):

<details>
<summary>Clique para expandir</summary>

- Microsoft.BingNews
- Microsoft.BingWeather
- Microsoft.GetHelp
- Microsoft.Getstarted
- Microsoft.Microsoft3DViewer
- Microsoft.MicrosoftOfficeHub
- Microsoft.MicrosoftSolitaireCollection
- Microsoft.MixedReality.Portal
- Microsoft.People
- Microsoft.PowerAutomateDesktop
- Microsoft.SkypeApp
- Microsoft.WindowsFeedbackHub
- Microsoft.XboxApp
- Microsoft.XboxGameOverlay
- Microsoft.XboxGamingOverlay
- Microsoft.XboxIdentityProvider
- Microsoft.XboxSpeechToTextOverlay
- Microsoft.YourPhone
- Microsoft.ZuneMusic
- Microsoft.ZuneVideo
- Microsoft.WindowsMaps
- Microsoft.OneConnect
- Microsoft.Messaging
- Microsoft.BingFinance
- Microsoft.BingSports
- Microsoft.BingTravel
- Microsoft.Office.OneNote
- Microsoft.Todos
- Clipchamp.Clipchamp
- Microsoft.549981C3F5F10
- LinkedInforWindows

</details>

## Backup e restauração:

- Backups ficam em `.\backups\session-YYYYMMDD-HHMMSS.json`.
- O script registra mudancas de:
  - registro (**DWORD** e tambem **String/ExpandString/QWord** via `RegistryProperty`)
  - startup type de servicos
  - tweak de context menu classico
  - **plano de energia ativo** (`PowerActiveScheme`)
  - **hibernacao** (`HibernateEnabledState` + `powercfg`)
  - **features opcionais Windows** (`OptionalFeatureState`, ex.: SMBv1)
- O restore (opcao `R`) aplica tudo em ordem reversa.

Se `DeepTweaks.ps1` nao estiver na pasta do script, aparece um aviso e a opcao **A** (submenu Advanced / Deep tweaks) informa que o modulo nao esta disponivel.

Notas:

- Apps removidos nao sao reinstalados automaticamente no restore.
- Para reinstalar apps, use Microsoft Store ou `winget`.

## Ambientes restritos: (Windows Sandbox, etc.)

Em ambientes restritos, algumas mudancas podem ser bloqueadas por politica.

O script trata isso com warnings por etapa e continua a execucao.
No final da opcao 3, ele mostra o resumo:

`Privacy tweaks completed with warnings. Success: X, Failed: Y`

## Personalizações:

Voce pode ajustar a lista de apps removidos editando:

- `Get-BloatPackageNames` em `Invoke-WindowsDebloat.ps1`

Voce tambem pode comentar/remover opcoes no menu para criar um perfil mais conservador.

## Solução de problemas:

Se algo falhar, inclua estes dados na issue:

- Versao do Windows (`winver`)
- Versao do PowerShell (`$PSVersionTable.PSVersion`)
- Opcao escolhida no menu
- Mensagem completa do erro/warning

## Arquivos do projeto:

- `Invoke-WindowsDebloat.ps1`: script principal (helpers de backup, menu, restore)
- `DeepTweaks.ps1`: deep tweaks agressivos; **dot-sourced** pelo principal (funcoes no mesmo escopo)
- `Run-Debloat-As-Admin.cmd`: launcher com UAC
- `README.md`: documentacao

## Star History:

<a href="https://www.star-history.com/?repos=Devzinh%2FWindowsDebloat&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Devzinh/WindowsDebloat&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Devzinh/WindowsDebloat&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Devzinh/WindowsDebloat&type=date&legend=top-left" />
 </picture>
</a>
