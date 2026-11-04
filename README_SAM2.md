# SAM-2-Segmentierung für kruemung_jinhan.m und kruemung.m

Die HSV-Farbmaske bzw. die Graustufen-Binarisierung reichen für die neuen
Aufnahmen nicht. Stattdessen segmentiert das **Segment Anything Model 2
(SAM 2, Meta)** den Draht. Der Ablauf ist zweistufig:

1. **Python**: `segment_wire_sam2.py` segmentiert ein **Video (.avi)** oder
   einen **Bilderordner (.jpg)** - wahlweise auch **mehrere auf einmal** -
   komplett (Auswahlfenster am Start) und speichert die Masken als PNGs im
   Nebenordner `<name>_sam2_masks` (neben dem Video bzw. neben dem
   Bilderordner).
2. **MATLAB**: `kruemung_jinhan.m` (Video) bzw. `kruemung.m` (Bilderordner)
   lädt diese Masken und macht wie gewohnt Skelettierung + Krümmungsberechnung.

---

## Einmalige Einrichtung (Python)

Voraussetzung: **Python ≥ 3.10** (auf Windows: [python.org](https://www.python.org/downloads/),
beim Installieren "Add to PATH" anhaken) und **Git**.

In **PowerShell** (Standard-Terminal unter Windows, Prompt `PS C:\...>`):

```powershell
# 1. Virtuelle Umgebung anlegen (einmalig), z.B. im Benutzerordner
# WICHTIG: "py" statt "python" verwenden (siehe Hinweis unten)!
py -m venv $env:USERPROFILE\sam2env
& "$env:USERPROFILE\sam2env\Scripts\Activate.ps1"

# 2. PyTorch installieren
#    MIT NVIDIA-GPU (empfohlen, deutlich schneller) - CUDA-Variante:
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
#    ODER OHNE GPU (nur CPU):
#    pip install torch torchvision

# 3. SAM 2 + Hilfspakete installieren (kein Git nötig, siehe Hinweis unten)
pip install https://github.com/facebookresearch/sam2/archive/refs/heads/main.zip
pip install opencv-python matplotlib numpy pillow
```

> **Fehler beim Aktivieren?** Falls PowerShell meldet, dass die Ausführung von
> Skripts auf diesem System deaktiviert ist, einmal pro PowerShell-Fenster
> ausführen (gilt nur für die aktuelle Sitzung):
> ```powershell
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
> ```
> Danach die `Activate.ps1`-Zeile erneut ausführen.

> **cmd.exe / Eingabeaufforderung statt PowerShell?** Dann stattdessen:
> `py -m venv %USERPROFILE%\sam2env` und zum Aktivieren
> `%USERPROFILE%\sam2env\Scripts\activate.bat`.

> **Warum `py` statt `python`?** Auf manchen Rechnern zeigt der Befehl `python`
> nicht auf eine echte Python-Installation, sondern auf ein von einem anderen
> Programm mitgeliefertes Python (z.B. Inkscape oder GIMP nutzen intern ein
> eigenes, eingeschränktes Python und hängen ihren `bin`-Ordner in den PATH).
> Damit erzeugtes venv ist kaputt (u.a. fehlt `Scripts\Activate.ps1`). Der
> **Python Launcher** `py` (wird vom offiziellen python.org-Installer mit
> installiert) findet dagegen zuverlässig die echte Python-Installation,
> unabhängig vom PATH. Prüfen kannst du das mit:
> ```powershell
> (Get-Command python).Source   # zeigt evtl. ein "fremdes" Python
> py --version                  # sollte die echte Python-Version zeigen
> ```
> Falls du bereits mit `python -m venv ...` einen kaputten `sam2env`-Ordner
> angelegt hast, diesen zuerst löschen und mit `py -m venv ...` neu anlegen:
> ```powershell
> Remove-Item -Recurse -Force $env:USERPROFILE\sam2env
> py -m venv $env:USERPROFILE\sam2env
> ```

> **Fehler "Cannot find command 'git'"?** `pip install git+https://...` braucht
> ein installiertes `git`. Zwei Möglichkeiten:
> - **Ohne Git (einfacher):** stattdessen das ZIP-Archiv installieren (siehe
>   Schritt 3 oben) - funktioniert identisch, ganz ohne Git:
>   ```powershell
>   pip install https://github.com/facebookresearch/sam2/archive/refs/heads/main.zip
>   ```
> - **Mit Git:** [Git for Windows](https://git-scm.com/download/win)
>   installieren (Standardoptionen reichen), PowerShell-Fenster **neu öffnen**
>   (damit der PATH aktualisiert wird), danach `pip install git+https://...`
>   erneut ausführen.

> **GPU oder nicht?** Das Skript erkennt das automatisch: mit CUDA-GPU nutzt es
> das Modell `base_plus`, ohne GPU das kleine `tiny`-Modell (funktioniert, ist
> aber pro Video deutlich langsamer). Die Modellgröße kann oben im Skript
> (`MODEL_SIZE`) fest vorgegeben werden.

> **Checkpoint-Download:** Beim ersten Start lädt das Skript die Modellgewichte
> automatisch von Metas offiziellen Servern in den Ordner `checkpoints/` neben
> dem Skript (tiny ≈ 150 MB, base_plus ≈ 320 MB, large ≈ 900 MB). Falls der
> Rechner keinen Internetzugang hat: Datei manuell von der im Skript
> hinterlegten URL laden und in `checkpoints/` legen.

---

## Nutzung

```powershell
& "$env:USERPROFILE\sam2env\Scripts\Activate.ps1"
python segment_wire_sam2.py
```

1. Im ersten Auswahlfenster **"Video (.avi)"** oder **"Bilderordner (.jpg)"**
   klicken.
2. Im zweiten Auswahlfenster wählen, ob **eins** oder **mehrere**
   segmentiert werden sollen (alle Dialoge starten in
   `M:\nascas2\Students\Wöhlken\2026-07-06`):
   - **Ein Video / Ein Bilderordner**: das Video bzw. den Bilderordner
     auswählen.
   - **Mehrere Videos**: einen Ordner auswählen, der mehrere `.avi`-Dateien
     enthält. Alle `.avi`-Dateien darin werden verarbeitet.
   - **Mehrere Bilderordner**: einen Überordner auswählen, der mehrere
     Bilderordner (mit `.jpg`-Bildern) enthält. Alle Unterordner mit
     `.jpg`-Bildern werden verarbeitet (vorhandene `*_sam2_masks`-Ordner
     werden ignoriert).

   Die Reihenfolge ist jeweils alphabetisch.
3. **Prompt-Phase:** Nacheinander öffnet sich für **jedes** Video / jeden
   Bilderordner der Prompt-Frame (Standard: das 10. Bild, einstellbar über
   `PROMPT_FRAME` oben im Skript). Im Fenstertitel steht, welches Video gerade
   dran ist (z.B. `[2/5] versuch_02 - Frame 10`):
   - **Linksklick** = Punkt liegt AUF dem Draht (grünes `+`)
   - **Rechtsklick** = Punkt gehört NICHT zum Draht (rotes `x`, z.B. um
     fälschlich mitsegmentierte Bereiche auszuschließen)
   - **Taste `u`** = letzten Klick rückgängig machen
   - Nach jedem Klick wird die aktuelle Maske blau überlagert angezeigt.
   - **Enter** = bestätigen, weiter zum nächsten Video / Bilderordner.
   - Fenster **ohne** grünen Klick schließen = dieses Video / diesen Ordner
     überspringen (bei "Ein Video / Ein Bilderordner": Abbruch).
4. **Segmentier-Phase:** Erst wenn alle Prompts gesetzt sind, segmentiert
   SAM 2 alle Videos / Bilderordner nacheinander (Maske vorwärts + rückwärts
   ab dem Prompt-Frame) - ohne weitere Eingaben, man kann den Rechner also
   laufen lassen. Schlägt eins fehl, wird mit dem nächsten weitergemacht.
5. Am Ende steht eine **Zusammenfassung** (OK / FEHLER / SKIP pro Video bzw.
   Ordner). Ergebnis jeweils: Ordner
   `<videoname bzw. ordnername>_sam2_masks\frame_00001.png, ...`
   neben dem Video/Bilderordner (weiß = Draht, schwarz = Hintergrund).
6. In MATLAB `kruemung_jinhan.m` (Video) bzw. `kruemung.m` (Bilderordner)
   ausführen und dasselbe Video / denselben Ordner wählen.

**Tipp:** Ein paar PNGs aus der Mitte/dem Ende des Ordners kurz ansehen, um zu
prüfen, dass SAM 2 den Draht über das ganze Video sauber verfolgt hat. Falls
nicht: Skript erneut ausführen und zusätzliche positive/negative Klicks setzen.

---

## Fehlermeldungen

- **MATLAB: "Keine SAM-2-Masken gefunden"** → Schritt "Nutzung" oben für dieses
  Video / diesen Bilderordner ausführen.
- **MATLAB: "Maskenanzahl passt nicht zur Frame-/Bildanzahl"** → Python-Skript
  erneut ausführen (alter/unvollständiger Maskenordner wird überschrieben).
- **Python: "Fehlendes Paket"** → Einrichtung oben durchführen bzw. venv
  aktivieren (`Activate.ps1`).
- **PowerShell: "... die Ausführung von Skripts ist auf diesem System
  deaktiviert"** → `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`
  ausführen (siehe oben), dann `Activate.ps1` erneut aufrufen.
