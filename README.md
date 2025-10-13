# Upload-4Video

AVideo Uploader — set de scripturi PowerShell pentru încărcarea automată de fișiere video (.mp4) pe instanțe AVideo/YouPHPTube folosind un UI Windows Forms și un script de upload robust.

## Descriere
Acest proiect conține două scripturi principale: 
- `upload-ui.ps1` — interfață grafică (Windows Forms) pentru configurare, lansare și monitorizare procesului de upload.
- `upload.ps1` — scriptul care realizează efectiv încărcarea fișierelor către serverele țintă (plugin MobileManager).

Scopul este să automatizezi upload-ul loturilor de videoclipuri, cu logging, retry-uri simple (posibil de extins), delay între upload-uri și afișarea progresului în UI.

## Cerințe
- Windows 10/11 recomandat (pentru afișarea emoji în UI).
- PowerShell 5 (Windows PowerShell) sau PowerShell 7+ (pwsh) — recomandat `pwsh` pentru suport UTF-8 implicit.
- .NET Framework (pentru Windows Forms) — deja prezent pe Windows moderne.
- Permisiuni pentru a rula scripturi PowerShell (ExecutionPolicy).
- Conexiune la internet și credențiale valide pentru endpoint-urile AVideo.

## Fișiere principale
- `upload-ui.ps1` — UI (versiunea actuală: v3.2).
- `upload.ps1` — uploader (versiunea actuală: v1.6).
- `config.json` — fișier de configurare generat/salvat din UI.
- `upload.log` — logul central generat de uploader (UTF-8).

## Instalare / Pregătire
1. Clonează sau descarcă repository-ul în folderul dorit.
2. Deschide PowerShell cu drepturi normale (sau administrator dacă ai nevoie să schimbi ExecutionPolicy).
3. Dacă folosești `powershell.exe` (versiune Windows PowerShell), rulează: `chcp 65001` pentru a seta code page UTF-8 în consolă (opțional, dar util).
4. Preferabil, instalează PowerShell 7+ și rulează `pwsh` — are suport Unicode/UTF-8 implicit.

## Configurare (config.json)
Poți salva configurația din UI sau edita manual `config.json`. Câmpurile importante:
- `SourceDir`: calea folderului cu fișiere `.mp4` de încărcat.
- `targets`: listă de obiecte `{ "baseUrl": "https://example.com", "user": "admin", "pass": "parola" }` (poți folosi `passEncrypted` din UI).
- `user`, `passEncrypted` sau `pass`: credențiale globale folosite dacă nu sunt setate pe target.
- `categories_id`: ID categorie implicit (opțional).
- `UploadDelay`: numărul de secunde de așteptare între upload-uri (opțional).
- `OpenAI`: `{ "apiKey": "..." }` — dacă vrei titluri generate automat (UseAI).
- `DeleteOnSuccess`: true/false — ștergere fișier local după upload reușit.

Exemplu minim `config.json`:
```json
{
  "SourceDir": "C:\to_upload",
  "targets": [ { "baseUrl": "https://boudoirlive.xyz", "user": "admin", "pass": "secret" } ],
  "categories_id": 0,
  "UploadDelay": 2,
  "DeleteOnSuccess": true
}
```

## Utilizare — UI (recomandat)
1. Rulează `upload-ui.ps1` (click dublu sau din PowerShell cu `pwsh -File upload-ui.ps1`).
2. Completează `Source Folder`, `Domains` (o linie pe domeniu), `Username`, `Password`, `Category ID` și `Upload Delay`.
3. Poți salva configurația cu `Save Config`.
4. Apasă `▶ Start Upload` pentru a porni procesul.
5. UI va afișa logul în timp real și o bară de progres cu numărul de fișiere încărcate.

Notă: UI salvează fișierul `config.json` și folosește `upload.ps1` în background; logul stdout/stderr redirecționat este citit ca UTF-8 pentru a afișa emoji și simboluri.

## Utilizare — CLI (fără UI)
Poți rula direct `upload.ps1` din PowerShell:
- `pwsh -File upload.ps1` — rulează cu setările din `config.json`.
- Argumente: `-UseAI` (folosește OpenAI pentru a genera titluri), `-DeleteOnSuccess` (șterge fișierele după upload).

Exemplu:
```
pwsh -File .\upload.ps1 -UseAI -DeleteOnSuccess
```
## Detalii tehnice și observații
- Scriptul `upload.ps1` folosește `System.Net.Http.HttpClient` pentru upload multipart și detectează răspuns JSON de la server.
- Fișierul `upload.log` este scris cu `UTF-8` pentru a păstra emoji și caractere speciale.
- UI folosește `RichTextBox` și selectează fontul potrivit pentru afișare corectă a emoji-urilor și a caracterelor box-drawing (═, ║ etc.).
- Dacă vezi simboluri `?` sau pătrățele în log: asigură-te că rulezi `pwsh` sau ai setat `chcp 65001` și că fontul `Segoe UI Emoji` este instalat pe sistem.

## Depanare (Debug)
- Verifică `upload.log` în root-ul proiectului pentru detalii despre fiecare upload.
- Dacă upload-urile eșuează, verifică `upload.log` și răspunsul JSON (campo `response`), apoi testează endpoint-ul cu `curl` sau `Invoke-WebRequest`.
- Pentru probleme de autentificare, verifică că `user`/`pass` sunt corecte și că URL-urile din `targets` includ `https://` dacă este cazul.

## Extensii recomandate (viitoare versiuni)
- Retry automat configurabil pentru upload-uri eșuate.
- Pause/Resume în UI.
- Upload paralel (cu throttling).
- Export raport CSV după upload.

## Licență
Proiectul este furnizat așa cum este — poți adapta pentru uz personal. Adaugă o licență (ex: MIT) dacă vrei să-l folosești/redistribui oficial.

---

_Autor: karen20ced4 — Scripturi PowerShell pentru automatizarea încărcărilor AVideo_