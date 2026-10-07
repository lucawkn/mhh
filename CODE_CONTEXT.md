# Code-Kontext – Repository `mhh`

Diese Datei fasst den wichtigen Kontext aller Auswertungs-Skripte zusammen,
damit der Konversationsverlauf gelöscht werden kann, ohne Verständnis über den
Code zu verlieren. Stand: 2026-07-09.

Das Repository enthält die **Bildauswertungs- / Tracking-Skripte**
(Auswertung der aufgenommenen Bilder bzw. Videos):
- **Krümmung:** `kruemung.m` (Draht, JPG), `kruemung_hai.m` (Schlauch, AVI),
  `kruemung_jinhan.m` (Draht, AVI), `inlayGeometry.m` (Referenz-Krümmung des
  Inlays); Spline-Varianten `kruemung_jinhan_v2_luca.m` (+ Batch/Excel:
  `kruemung_jinhan_v2_luca_batch.m`) + `inlayGeometry_v2.m`.
- **Tip-Tracking:** `tip_track_matching_spline.m` (JPG), `cochlea_model_tracking2.m`
  (MP4), `create_trajectory.m` (Referenztrajektorie).
- **SAM-2-Segmentierung (Python):** `segment_wire_sam2.py` + `README_SAM2.md`
  (erzeugen die Drahtmasken für `kruemung.m`/`kruemung_jinhan.m`).

(`cochlea_model_tracking.m`, der Vorläufer von `cochlea_model_tracking2.m`
mit manueller Tip-Zuweisung per Suchradius/Klick-Korrektur, wurde gelöscht;
`cochlea_model_tracking2.m` ist die aktuelle, vollautomatische Video-Variante.)

(Die Versuchssteuerungs-/Hardware-Skripte `bfrAufnahmeApp.m`, `listKameras.m`
und `testKameras.m` liegen in einem anderen Branch und sind hier bewusst nicht
enthalten.)

Kontext: Formgedächtnis-/Memory-CI-Forschung. Es geht um die Verbiegung von
Draht/Elektroden über Temperatur und um das Tracking der Spitze (Tip) einer
Cochlea-Elektrode beim Einführen ins Cochleamodell.

---

## Gemeinsame Konventionen (für die Auswertungs-Skripte)

- **Koordinaten:** Bildkoordinaten, `TipCoordinates(k,:) = [row, col]` = `[y, x]`.
  Referenzpunkte aus `ginput` werden dagegen als `[x, y] = [col, row]`
  gespeichert (z.B. `cochleaCenter`, `cochleaEntrance`). Achtung auf die
  Reihenfolge beim Rechnen!
- **Bildanzeige:** `axis ij` (y zeigt nach unten). Das ist relevant für die
  Vorzeichendefinition von Winkeln (siehe `cochlea_model_tracking2.m`).
- **Binarisierungs-Konvention beim Tracking:** Elektrode/Draht = `0` (schwarz),
  Hintergrund = `1` (weiß) bzw. Vordergrund `fg` = `true` bei der Background-
  Subtraction in `cochlea_model_tracking2.m`. Das Tracking sucht dort, wo die
  Elektrode als dunkler Bereich vom Hintergrund abweicht.
- **`ImageData`-Struct-Array (nur `kruemung.m`/`tip_track_matching_spline.m`):**
  pro Frame ein Eintrag mit Feldern wie `name`, `path`, `gray`/`rgb`, `bw`,
  ggf. `skel`, `xs`, `ys`, `kappa`.
- **Persistenz:** Trajektorien werden als `.mat` neben den Daten gespeichert.
  `tip_track_matching_spline.m` fragt beim nächsten Start per `questdlg`
  "Alte verwenden / Neu zuweisen"; `cochlea_model_tracking2.m` lädt IMMER eine
  vorher mit `create_trajectory.m` erzeugte `.mat` (keine eigene Neuzuweisung)
  und speichert seine Fenster-Einstellungen zusätzlich als `tracking_params.mat`
  im Video-Ordner (siehe eigener Abschnitt).
- **SAM-2-Workflow (zweistufig, für Draht-Videos/-Bilder):** Wo HSV- bzw.
  Graustufen-Masken versagen, segmentiert das Python-Skript `segment_wire_sam2.py`
  (Segment Anything Model 2, Meta) den Draht **einmalig** pro Video bzw.
  Bilderordner und legt die Masken als PNGs in `<name>_sam2_masks\frame_%05d.png`
  ab (1-basiert, alphabetisch sortiert = identisch zur `imageDatastore`-/
  Frame-Reihenfolge in MATLAB). `kruemung.m` (JPG-Ordner) und `kruemung_jinhan.m`
  (AVI) **laden** diese Masken dann, statt selbst zu binarisieren. Einrichtung
  und Bedienung: siehe `README_SAM2.md`.
- **Tracking-Pipeline (nur `kruemung.m`/`tip_track_matching_spline.m`):** feste
  Workspace-Maske (Rechteck) + runde Tip-Suchmaske → größte zusammenhängende
  Komponente im Komplement → geodätische Distanztransformation
  (`bwdistgeodesic`) liefert den am weitesten entfernten Punkt = Tip.
  Plausibilitätsprüfungen (Krümmung, Konnektivität), bei Fehlschlag
  Vektorprädiktion + progressive Suche, sonst manuelles Klicken.
  `cochlea_model_tracking2.m` verwendet ein **anderes, trapezbasiertes**
  Verfahren ohne manuelle Korrektur (siehe eigener Abschnitt unten).

---

## `kruemung.m` — Krümmung eines biegenden Drahts über Temperatur (JPG)

**Zweck:** JPG-Bildfolge eines sich biegenden Drahts einlesen, den Draht
skelettieren, seine Krümmung entlang der Bogenlänge berechnen und als
Farbverlauf über dem Originalbild darstellen. Zusätzlich mittlere Krümmung über
Temperatur.

**Wichtig – zweistufiger SAM-2-Workflow (ersetzt die frühere Binarisierung +
ROI/Polygon-Maske):** Vorab einmal `segment_wire_sam2.py` ausführen, dort
"Bilderordner (.jpg)" wählen und diesen Ordner segmentieren; die Masken landen
neben dem Ordner als `<ordnername>_sam2_masks\frame_%05d.png`. Erst danach
dieses Skript starten.

**Ablauf:**
1. Ordner mit `*.jpg` wählen (`uigetdir`, `imageDatastore`).
2. **SAM-2-Masken prüfen:** `error`, wenn der Ordner `<ordnername>_sam2_masks`
   fehlt oder die Maskenanzahl ≠ Bildanzahl ist (falsche Zuordnung vermeiden).
3. Pro Bild: Temperatur aus Dateinamen (`..._03-5` → `03.5 °C`), Graustufen +
   `medfilt2` (nur für die Slider-Anzeige). **Draht = vorberechnete SAM-2-Maske**
   `imread(frame_%05d.png) > 0` (weiß = Draht); Zuordnung über die Position `n`
   (imds ist alphabetisch sortiert = Python-Sortierung).
4. Kleine Specks raus (`bwareaopen(...,300)`), Lücken schließen (`imclose`,
   `gapCloseRadius = 1`).
5. **Drahtauswahl:** die Komponente mit der **größten `MajorAxisLength`**
   (nicht größte Fläche!) wird als Draht gewählt — robust gegen runde
   Luftblasen, die mehr Fläche haben können.
6. Skelettieren (`bwskel`, `MinBranchLength=25`), Endpunkt finden,
   `bwdistgeodesic` für die Bogenlänge, `unique(d)` für streng monotone
   Stützstellen (sonst `interp1`-Fehler), `interp1` auf `N=20` gleichverteilte
   Punkte, glätten, Krümmung `kappa = |x'y'' − y'x''| / (x'²+y'²)^1.5`.
7. NaN-Guards: Frames mit < 2 Skelettpunkten / ohne Komponente werden mit NaN
   gefüllt (kein Absturz).
8. `figure(2)`: mittlere Krümmung über eindeutige Temperaturen (normiert,
   NaN-sicher via `accumarray`).
9. `figure` mit **Slider** (`uicontrol` + `addlistener` auf `Value`/`PostSet`):
   farbige Krümmungsdarstellung (jet-Colormap) über dem Graustufenbild, lokale
   Funktion `drawFrame`.

**Wichtige Parameter:** `gapCloseRadius=1`, `N=20`.

**Gelöste Probleme:** `interp1`-Fehler (→ `unique(d)` + NaN-Guards);
Draht/Blasen-Unterscheidung (→ `MajorAxisLength`). Die frühere
Graustufen-Binarisierung (`level=0.6`) + ROI-Polygon (`xv`/`yv`/`poly2mask`) +
ROI-Rechteck reichten bei den neuen Aufnahmen nicht mehr → durch die
SAM-2-Masken ersetzt.

---

## `kruemung_hai.m` — Krümmung eines Schlauchs über die Zeit (AVI)

**Zweck:** wie `kruemung.m`, aber für einen **Schlauch** aus einem **`.avi`-Video**
statt eines Drahts aus JPG. Die mittlere Krümmung wird über die **Zeit** geplottet.

**Ablauf / Unterschiede zu `kruemung.m`:**
1. `.avi` wählen (`uigetfile`, Default-Pfad Nguyen-Messversuch), `VideoReader`;
   Zeitvektor `tVec = (0:ImageNummax-1)/frameRate`.
2. Segmentierung per **HSV-Farbmaske** `createMask(rgbImg)` (aus dem Color
   Thresholder App generiert; Funktionsname im Skript ggf. anpassen), danach nur
   die größte zusammenhängende Fläche behalten.
3. Skelett + Krümmung wie `kruemung.m`, aber `N=7` (kurzer Schlauch).
4. `figure(2)`: mittlere Krümmung über die Zeit, normiert auf `max_kappa=0.0117`.
5. Slider-Darstellung über dem RGB-Bild (`ImageData(n).rgb`).

---

## `kruemung_jinhan.m` — Krümmung eines Drahts über die Zeit (AVI, SAM-2)

**Zweck:** Kopie von `kruemung_hai.m` für einen **Draht** aus `.avi`, bei dem die
HSV-Maske versagt → Segmentierung über **vorberechnete SAM-2-Masken** (statt
`createMask`).

**Unterschiede zu `kruemung_hai.m`:**
- Default-Pfad `M:\nascas2\Students\Wöhlken\2026-07-06`.
- **Zweistufiger Workflow:** vorab `segment_wire_sam2.py` (Video wählen) →
  `<videoname>_sam2_masks\frame_%05d.png`; das Skript prüft Existenz + Anzahl
  (`error` bei fehlend / Anzahl ≠ Frameanzahl) und lädt `imread(...) > 0` als
  Draht statt `createMask`.
- Sonst identisch: größte Komponente, Skelett + Krümmung, `N=7`, Krümmung über
  die Zeit normiert auf `max_kappa=0.0117`, Slider über dem RGB-Bild. Gibt
  zusätzlich `max_kappa` (normiert/nicht normiert) und `end_kappa` aus.

---

## `kruemung_jinhan_v2_luca.m` — wie `kruemung_jinhan.m`, Krümmung per Spline-Fit

**Zweck:** gleiche Pipeline wie `kruemung_jinhan.m` (AVI, SAM-2-Masken), aber
die Krümmung wird **rauscharm über eine Least-Squares-Spline** berechnet statt
über `interp1` auf wenige Punkte + `gradient`.

**Ausführliche Methodenbeschreibung:** `README_kruemung_jinhan_v2.md` (von der
Maske über Skelett, Spline-Fit und Krümmung bis zu den Plots).

**Krümmungsberechnung:**
- **Alle** Skelettpixel (sortiert nach geodätischer Bogenlänge `d`) werden mit
  einer kubischen Regressionsspline approximiert (`fitSplineLSQ`): Knoten
  gleichmäßig im Abstand `knotSpacing`, Koeffizienten per linearem Least
  Squares (`c = B \ x`; Basis `B` = `spline(knots, eye(nKnots))` ausgewertet,
  not-a-knot, nur Basis-MATLAB, keine Toolbox nötig).
- `nParamIter` Fußpunkt-Iterationen: Parameter jedes Pixels wird auf den
  nächstgelegenen Spline-Punkt korrigiert und neu gefittet → minimiert den
  **orthogonalen** Abstand Pixel ↔ Spline.
- Krümmung **analytisch** aus den exakten Spline-Ableitungen (`ppDeriv` auf der
  pp-Form), ausgewertet an `Neval=200` Punkten; `mean_kappa` = Mittel darüber.
- `ImageData(n).fitRMS` = RMS-Abstand Pixel ↔ Spline [px] (Kontrolle; ~0.3–0.5 px
  ist normal durch Pixelrasterung).
- Anzeige: Spline als ein `patch` mit Farbverlauf (`EdgeColor='interp'`).
- Nach der Maskenprüfung fragt ein `questdlg` („Maskenkontrolle“), ob die
  Schwarz/Weiß-Maske jedes Frames in `figure(1)` angezeigt werden soll
  (`showMasks`; Default/Fenster schließen = nicht anzeigen → spart Zeit).
- **Startpunkt der Bogenlänge wird nachverfolgt** (statt `ex(1)` = linkester
  Endpunkt, der je Frame die Richtung drehen konnte): erster gültiger Frame →
  Endpunkt am nächsten zum Bildrand (eingespanntes Ende), danach Endpunkt am
  nächsten zu `prevStart` (Startpunkt des Vorframes). `ImageData(n).s` =
  Bogenlänge ab Startpunkt [px].
- **`figure(3)`: 3D-Plot κ(Länge, Zeit)** per `surf`: gemeinsame Längsachse
  `sGrid` in mm (0 … größte Länge), pro Frame `interp1` von `kappa` (in 1/mm)
  auf `sGrid`, kürzere Frames → NaN (Lücke). Von oben (`view(2)`) = Heatmap.
  Achtung: an den Drahtenden ist die Spline-Krümmung ungenauer (Ausreißer möglich).

**Wichtige Parameter:** `knotSpacing=40` px (größer = glatter; Test an
gerasterten Kreisen/Spiralen R≈80–330 px: Fehler der mittleren Krümmung ~2 %,
lokal ~7 % in der Drahtmitte, an den Enden größer), `nParamIter=3`, `Neval=200`.
**Keine Normierung mehr:** Die Spline-Krümmung ist ein echter Messwert. `figure(2)`
zeigt die mittlere Krümmung **absolut in 1/mm** (`[ImageData.mean_kappa] * pxPerMm`;
`ImageData` bleibt intern in 1/px) mit gestrichelter Referenzlinie `kappaInlay`
(= exakte mittlere Inlay-Krümmung 0.4252 1/mm, Radius ≈ 2.35 mm, aus
`inlayGeometry_v2.m`). Ausgabe max./End-Krümmung in 1/mm + Radius.
`pxPerMm` (Kalibrierung des Videos) muss eingetragen werden; bei `1` → Warnung.

---

## `kruemung_jinhan_v2_luca_batch.m` — Batch-Version mit Excel-Export

**Zweck:** alle `.avi` eines Ordners mit der **identischen** Spline-Krümmung wie
`kruemung_jinhan_v2_luca.m` auswerten (Pipeline pro Frame in lokaler Funktion
`frameMeanCurvature`) und die Kennwerte in die Testlisten-Excel schreiben.
Batch-/Excel-Logik übernommen aus dem Nutzer-Skript
`kruemmung_jinhan_v16_batch_skip_excel.m` (nicht im Repo).

- Ordner (`uigetdir`) + Excel einmal wählen; Testparameter aus dem Dateinamen
  `...-<Pulslaenge>-<Pulspause>-<Pulsanzahl>-<Spannung>` (`parseVideoTestParams`).
- Zielzeile: Blatt `Pulslänge-<x>ms`, Block mit passender Pulslänge/-anzahl/
  -pause (Zeile mit `Pulslänge/ms` in Spalte B), dann Zeile mit `Spannung-set`
  in Spalte C (`getExcelTargetState`).
- **Spalten W:Z** (M:V gehören dem v16-Skript): W = Max mittlere Krümmung
  [1/mm], X = End-Krümmung (letzter gültiger Frame) [1/mm], Y = Zeitpunkt des
  Max [s], **Z = Video-Datei = Abschlussmarker** (zuletzt geschrieben). Zeilen
  mit gefülltem Z werden vor der Auswertung übersprungen; nur leere Zellen
  werden beschrieben; Header in W:Z der Headerzeile nur, wo leer.
- `pxPerMm = 43`, Bildrate aus dem Video (`v.FrameRate`); keine Plots, keine
  RGB-Frames; `try/catch` pro Video + Zusammenfassung am Ende.
- Spline-Funktionen sind eine Kopie aus `kruemung_jinhan_v2_luca.m`
  (identisch halten, ebenso `knotSpacing`/`nParamIter`/`Neval`).

---

## `inlayGeometry.m` — Referenz-Krümmung des Inlays (TB01Lv01)

**Zweck:** analytische Inlay-Geometrie (6 Kreisbögen aus Radien/Zentren/Winkeln
+ gerade Einlaufstrecke, Autor N. Suzaly) zeichnen UND daraus eine mittlere
Krümmung berechnen, die als Normierung (`max_kappa`) für `kruemung_hai.m` dient.

**Wichtig:** Die Krümmung wird **EXAKT wie in `kruemung_hai.m`** berechnet
(`N=7` äquidistante Punkte per linearem Resampling, Gauß-Glättung, `gradient`
direkt auf den 7 Punkten, `kappa = |x'y''−y'x''|/(x'²+y'²)^1.5`,
`mean(kappa,'omitnan')`), damit die Werte direkt vergleichbar sind. Da Krümmung
`1/Länge` ist, werden die mm-Koordinaten vorher mit `pxPerMm` in den
Pixel-Maßstab des Videos gebracht (Kalibrierwert eintragen, `1` = keine
Umrechnung). Die gerade Einlaufstrecke ist eingeschlossen. Ausgabe: mittlere
Krümmung zum Einsetzen als `max_kappa`.

---

## `inlayGeometry_v2.m` — Referenz-Krümmung des Inlays (Spline-Methode)

**Zweck:** wie `inlayGeometry.m` (gleiche Geometrie), aber die Krümmung wird
mit **derselben Least-Squares-Spline-Methode wie `kruemung_jinhan_v2_luca.m`**
berechnet. Die **exakte** mittlere Krümmung in 1/mm ist die Referenzlinie
`kappaInlay` in `kruemung_jinhan_v2_luca.m`; der Spline-Wert zeigt, wie gut die
Spline-Methode beim gewählten Maßstab die Geometrie trifft. Ausgabe beider
Werte in 1/px und 1/mm.

- Lokale Funktionen `fitSplineLSQ`, `splineCurvature`, `ppDeriv` sind
  **Kopien** aus `kruemung_jinhan_v2_luca.m` → bei Änderungen beide anpassen;
  ebenso die Parameter `knotSpacing=40`, `nParamIter=3`, `Neval=200`.
- `pxPerMm` (Kalibrierung) muss stimmen: Krümmung skaliert mit 1/Maßstab UND
  `knotSpacing` ist in px. Warnung, wenn die Inlay-Länge < 4·`knotSpacing` ist
  (z.B. bei `pxPerMm=1`: Inlay nur ~16 px lang).
- Gibt zusätzlich die **exakte** mittlere Krümmung aus
  (`Σ Bogenwinkel / Gesamtlänge`; Gerade κ=0, Bögen κ=1/r) und plottet den
  Krümmungsverlauf Spline vs. exakt. Test (Octave, `pxPerMm=30`): Spline
  0.0145 vs. exakt 0.0142 1/px.

---

## `tip_track_matching_spline.m` — Tip-Tracking aus JPG + Temperaturanalyse

**Zweck:** Vorläufer von `cochlea_model_tracking.m`, arbeitet auf **JPG-Bildern**
statt Video. Trackt die Elektrodenspitze über die Bildfolge und analysiert den
Fortschritt entlang der Trajektorie **über die Temperatur** (Formgedächtnis-
Aktivierung).

**Ablauf:**
1. JPG-Ordner wählen, Graustufen + `medfilt2`, Binarisierung (`level=0.55`).
2. Trajektorie laden oder neu (`tip_trajectory.mat` enthält
   `TipCoordinates`, `T`, `t_rel`).
3. Manuelle Maskenerzeugung: Workspace-Rechteck (`drawrectangle`) + Tip-Klick
   (`ginput`), `tipRadius=25`.
4. Tracking-Schleife (siehe gemeinsame Pipeline). Zusätzlich werden pro Frame
   **Temperatur** `T(k)` und **Zeitstempel** aus dem Dateinamen geparst
   (`yyyyMMdd_HHmmss`), `t_rel` = Sekunden seit Start.
   - Es gibt einen großen **auskommentierten** ersten Versuch der Tracking-
     Schleife (Zeilen ~129–300); aktiv ist die Variante ab "`%% test`".
5. `reviewTips(ImageData, TipCoordinates, tipRadius)`: **Slider**-basierte
   manuelle Kontrolle (hier noch mit Slider; `cochlea_model_tracking2.m` hat
   dagegen KEINE manuelle Kontrolle mehr — vollautomatisch). Klick setzt Tip
   neu, "Bestätigen" beendet.
6. `figure(3)`: Trajektorie (Punkte, Linie, Spline). Achsen fest `1280×960`.
7. **Äquidistante Punkte** (`figure(4)`): Kurve dicht splinen und Punkte mit
   konstantem euklidischem Sehnenabstand `d=5 px` per Kreis-Segment-Schnitt
   erzeugen (`TipCoordsEqui`).
8. **Fortschritt über Temperatur** (`figure(5)`): jeder Messpunkt wird dem
   nächstgelegenen Referenzpunkt zugeordnet → Anteil `0..100 %` der Trajektorie
   über `T`.
   - **Aufwärmphase (neu):** ausgewertet werden nur die Frames `1..kMax` bis zur
     **höchsten gemessenen Temperatur** (der Abkühl-/Rückweg wird abgeschnitten).
9. **3-Segment-Regression** (`figure(6)`): stückweise lineare Anpassung
   `fitPlateauRampPlateau` mit festen Randwerten (Start 0, Ende 100). Liefert
   Aktivierungstemperaturen `As = x1`, `Af = x2`.
   - **Messbereichs-Erweiterung (neu):** vor dem Fit werden `measTemp`/`prog` in
     1-°C-Schritten nach unten bis −25 °C (Fortschritt mit `zeros` = erstem Wert
     aufgefüllt) und nach oben bis 90 °C (mit `ones` = letztem Wert aufgefüllt)
     verlängert, damit die gefittete Funktion über den ganzen Messbereich
     definiert ist.

**Lokale Funktionen:**
- `reviewTips(...)` — Slider-Variante der Tip-Kontrolle.
- `fitPlateauRampPlateau(x, y, c1=0, c2=100)` — stetige stückweise-lineare
  3-Segment-Regression. Knickstellen `x1<x2` per Grid-Suche + `fminsearch`
  optimiert; Knickwerte `y1,y2` exakt per linearer Ausgleichsrechnung
  (`sseFixed`). Rückgabe: `params` (inkl. `m1,m2,m3,r2`) + `predictFcn`.
- Hilfsfunktionen `modelEval`, `sseFixed`, `objective`.

---

## `cochlea_model_tracking2.m` — Tip-Tracking aus MP4-Videos (Hauptskript, vollautomatisch)

**Zweck:** Ersetzt `cochlea_model_tracking.m` (gelöscht) vollständig. Verarbeitet
**einen ganzen Ordner mit mehreren MP4-Videos** (Dateinamen z.B.
`2026-06-23_TP07_V01_F1_Camera1.mp4`, dann `V02`, …; `*_Camera2.mp4` wird
ignoriert) nacheinander. Pro Video wird die Elektrodenspitze **komplett
automatisch** getrackt (KEINE manuelle Korrektur, KEIN Suchradius-Klick mehr —
bewusst gegenüber der Vorgängerversion entfernt) und Winkel, Insertionstiefe
und Kraft werden berechnet und geplottet.

**Bedienreihenfolge beim Start:**
1. **Video-Ordner wählen** (`uigetdir` mit `defaultPath`); `dir('*_Camera1.mp4')`
   liefert die zu verarbeitenden Videos (`error`, wenn leer). `*_Camera2.mp4`
   wird ignoriert.
2. **EIN Parameterfenster** `selectTrackingParams(defaults)` (modales
   `figure`, lokale Funktion am Dateiende) mit ALLEN Einstellungen:
   - **Ähnlichkeitstransformation:** Rotation um `M`, Skalierung um `M`,
     Translation X/Y.
   - **Maske / Background Subtraction:** `numBgFrames`, `fgThreshold`,
     `minBlobSize`.
   - **Wiedergabe:** Haken „Video rückwärts abspielen" (`reverseVideo`) + Feld
     „Startframe".
   - **Modus:** Live-Vorschau (RGB Image / BW Maske → `previewMode`),
     Video-Modus (Ein Video / Alle Videos → `videoMode`).
   „Bestätigen" liest alle Felder (`str2double`, bei NaN `errordlg` + Fenster
   bleibt offen); Schließen ohne Bestätigen gibt `[]` zurück → `error(...)`.
3. **Persistenz:** die bestätigten Werte werden als `<ordner>\tracking_params.mat`
   gespeichert. Beim erneuten Öffnen desselben Ordners wird das Fenster mit
   diesen Werten **vorbelegt** (Datei über die Top-of-File-Defaults gelegt,
   robust gegen fehlende Felder). Die Konstanten oben im Code sind nur die
   Fallback-Vorbelegung, wenn noch keine `tracking_params.mat` existiert.
4. Bei `videoMode==1` (Ein Video) zusätzlich `uigetfile('*_Camera1.mp4', …, vidDir)`
   → nur dieses Video; sonst alle im Ordner (alphabetisch, `V01, V02, …`).
5. **EINE Trajektorie-`.mat`** (aus `create_trajectory.m`, enthält
   `TipCoordinates` + `cochleaCenter`) wählen (`uigetfile`, Start in `vidDir`)
   — gilt für ALLE Videos im Ordner.

**Ähnlichkeitstransformation (immer angewandt):** bildet Trajektorie +
Mittelpunkt `M` ab. Rotation und Skalierung erfolgen **um `M`** (`M` bewegt sich
nicht), danach Verschiebung um `simTranslation`:
`[x';y'] = simScale * R(simRotationDeg) * ([x;y] - M) + M + simTranslation`.
Wird VOR der Trapez-Berechnung angewendet → Trapeze sind automatisch mit
transformiert. `rectWidth`/`rectHeight` werden zusätzlich mit `simScale`
skaliert. Bei Rotation 0 / Skalierung 1 / Translation `[0,0]` ist der Block ein
**No-op** (Identität) — die frühere Fallunterscheidung Ordner 1/2/3/4 entfällt
dadurch komplett.

**Trapezbasierte Tip-Suche (Kernalgorithmus, pro Video):**
1. Pro Trajektorienpunkt wird ein an Tangente/Normale ausgerichtetes Viereck
   berechnet (Tangente via `gradient(xs,ys)`, Normale = 90°-Rotation der
   Tangente). **Jede der 4 Ecken wird einzeln** nach ihrem Abstand zu `M`
   skaliert (`rectWidth/rectHeight` als Grundmaß bei Abstand 0,
   `widthSlope/heightSlope` als Zuwachs pro Pixel Abstand) → aus Rechtecken
   werden dadurch Trapeze. Statisch, einmal pro Video vorberechnet
   (`allCorners`, `allMasks` via `poly2mask`).
2. **Background Subtraction:** Hintergrund = Mittel der ersten `numBgFrames`
   Frames (statisch, elektrodenfrei). Pro Frame
   `diffImg = |gray − bgGray|/255`, `fg = diffImg > fgThreshold`,
   `bwareaopen(fg, minBlobSize)` (Elektrode = `fg`, `true`/schwarz).
3. **Suchreihenfolge:** global wird einmal festgelegt, ob Trajektorienindex 1
   oder `nP` näher an `M` liegt (`dFirst`/`dLast`) → `searchOrder` +
   `stepDir` (±1). `idxLast` = das vom-`M`-Ende aus zuletzt durchsuchte
   Trajektorienende = der **Eingang** (Fallback-Position).
4. **Lokale Suche pro Frame (WICHTIG, letzte Änderung):** statt jeden Frame
   die komplette Trajektorie ab `M`-Ende zu durchsuchen, startet die Suche ab
   dem Trapez, das `searchAhead` (Default 5) Trapeze näher an `M` liegt als
   das im VORHERIGEN Frame gefundene Trapez (`prevFoundIdx`), und läuft von
   dort in derselben Richtung weiter bis zum Eingang (`localSearchOrder`).
   Grund: Verhindert Fehlzuweisungen an weit entfernten, physikalisch
   unplausiblen Trapezen nahe `M` und reduziert die Anzahl geprüfter Trapeze.
   Deckt Vorwärtssprünge bis `searchAhead` Trapeze UND beliebige
   Rückwärtsbewegung ab (Suche läuft immer bis zum Eingang durch).
5. Im **ersten** Trapez der lokalen Suchreihenfolge mit schwarzen Pixeln wird
   der Schwerpunkt der **größten zusammenhängenden schwarzen Fläche**
   (`bwconncomp` + `regionprops('Area','Centroid')`) als Tip übernommen.
   Findet sich in KEINEM der lokal durchsuchten Trapeze ein schwarzer Pixel,
   wird der Tip auf den **Eingang** (`idxLast`) zurückgesetzt.
6. **Live-Vorschau** (`figure 'Tip-Tracking V0x'`, optional via `showPreview`):
   Bild (RGB oder BW je nach `previewMode`), Trajektorie, alle Trapeze (rot),
   gefundenes Trapez (grün) + Tip-Kreuz werden EINMAL angelegt und nur per
   `set(...,'CData'/'XData'/'YData',...)` aktualisiert (flackerfrei). Wird
   nach jedem Video geschlossen; Ergebnis-Plots bleiben offen.

**Wiedergabe (rückwärts / Startframe):** Bei `reverseVideo` läuft die
Verarbeitung in umgekehrter Bildreihenfolge (`frameOrder = totalFrames:-1:1`);
die Hintergrund-Referenz kommt dann aus den ersten `numBgFrames` **Wiedergabe**-
Frames (= den letzten echten Frames), die CSV-Messdaten werden an die
Wiedergabe-Position gebunden (Zeitachse läuft vorwärts). Das Tracking/die Plots
beginnen ab `startFrame` (`startPosThis = min(max(round(startPos),1),totalFrames)`),
Ergebnisse werden nach Wiedergabe-Position indiziert.

**Berechnete Größen pro Video (nach der Frame-Schleife):**
- **Insertionstiefe:** da die Trajektorienpunkte äquidistant sind (siehe
  `create_trajectory.m`), ergibt sich der Fortschritt entlang der Trajektorie
  (0 = Eingang, 1 = anderes Ende) direkt aus dem Punktindex des gefundenen
  Tips: `insertionDepth = |tipIdxFrame - idxLast| / (nP-1) * insertionDepthMax`
  (`insertionDepthMax` = tatsächliche Tiefe am Trajektorienende in mm). Frames
  ohne gefundene Spitze (`tipIdxFrame==0`) werden auf `NaN` gesetzt.
- **Winkel:** zwischen Referenzlinie (`M`→Eingang) und Tip-Linie (`M`→Tip),
  **gegen den Uhrzeigersinn = positiv** (`atan2d(ay*bx-ax*by, ax*bx+ay*by)`,
  y zeigt im Bild nach unten). Über die gültigen Frames **entfaltet**
  (`unwrap`), kann >180°/360° werden. Null = Tip auf der Referenzlinie.
- **CSV-Messdaten:** passende `<...>_F1.csv` (Videoname ohne `_Camera1`),
  deutsches Format (`;`-getrennt, `,`-Dezimalzeichen, 1 Kopfzeile). Spalte U
  = TimeStamp, Spalte C = Kraft z, Spalte Y = Frame-Nummer. Pro Video-Frame
  wird die ERSTE CSV-Zeile mit passender Frame-Nummer verwendet
  (`find(csvFrameNo==f,1,'first')`).
- **Glättung:** Winkel, Insertionstiefe und Kraft z werden zusätzlich mit
  `smooth(..., smoothSpan)` geglättet (gleitender Mittelwert).

**Plots pro Video:**
- `Tip Trajectory V0x`: grüne Kreuze (Tip je Frame) + Linie, `M` (cyan),
  Eingang (magenta), Referenzlinie, `axis ij`.
- `Übersicht V0x`: EIN Figure mit `subplot(3,2,...)` — 3 Zeilen (Winkel über
  TimeStamp / Insertionstiefe über TimeStamp / Kraft z über Winkel) × 2
  Spalten (roh | geglättet, geglättet mit grauer Roh-Linie + farbiger
  geglätteter Linie + Legende).

**Ergebnis-Struct (pro Video als `<videoname>_results.mat` gespeichert):**
`results` mit Feldern `video`, `label`, `frame`, `timestamp`, `force`,
`forceSmoothed`, `angle`, `angleSmoothed`, `insertionDepth`,
`insertionDepthSmoothed`.

**Lokale Funktion:** `selectTrackingParams(defaults)` — modales Parameterfenster
(`uicontrol` edit/checkbox/popupmenu + „Bestätigen") mit den geschachtelten
Helfern `header`/`editRow`/`onConfirm`/`onClose`; gibt den Parameter-Struct oder
`[]` zurück. Ersetzt die früheren drei Fenster
`selectFolderScenario`/`selectVideoMode`/`selectPreviewMode`.

**Historie der Designentscheidungen für dieses Skript (chronologisch):**
1. Aus `cochlea_model_tracking.m` entstanden: Umstellung von
   Suchradius-Zuweisung + manueller Klick-Korrektur auf **vollautomatische**
   trapezbasierte Suche (kein `reviewTips` mehr).
2. Trapez-Suche vom `M`-nahen Ende zum Eingang, Fallback auf Eingang bei
   Nichtfund; Frame-für-Frame chronologisch statt ab `startFrame`.
3. Mittelpunkt wird in `create_trajectory.m` geklickt und in der `.mat`
   mitgespeichert (`cochleaCenter`), nicht mehr pro Video neu geklickt.
4. Ordner-Stapelverarbeitung (`*_Camera1.mp4`, `V01,V02,…`), EINE Trajektorie
   gilt für alle Videos, RGB-Live-Vorschau, automatischer Videowechsel ohne
   Bestätigungsdialog.
5. Winkel-Plot über TimeStamp/Kraft aus CSV (statt Frame-Nummer), CSV-Frame-
   Zuordnung über Spalte Y.
6. Insertionstiefe (aus Trajektorienindex), Glättung (Winkel/Insertionstiefe/
   Kraft), Zusammenfassung aller Plots in einer `Übersicht`-Subplot-Figure,
   Ergebnis-Struct + `.mat`.
7. Ordner-1/2/3-Auswahl mit je eigenen Background-Subtraction- und
   Ähnlichkeitstransformations-Parametern (Ordner 2/3); Ein-Video/Alle-Videos-
   Auswahl; RGB/BW-Vorschau-Umschalter zum Parameter-Tuning.
8. **Lokale Trapez-Suche** (`searchAhead`, ankert an der Zuweisung des
   Vorframes) statt globaler Suche ab dem `M`-Ende bei jedem Frame — behebt
   Fehlzuweisungen an weit entfernten Trapezen.
9. **Ein Parameterfenster statt Ordner-Buttons:** die drei Popup-Fenster und die
   fest verdrahteten Ordner-1/2/3/4-Parametersätze wurden durch EIN
   `selectTrackingParams`-Fenster ersetzt, dessen Werte pro Ordner in
   `tracking_params.mat` persistiert und beim erneuten Öffnen vorbelegt werden.
   Die Ähnlichkeitstransformation wird seitdem immer (Identität = No-op)
   angewandt. Ergänzend: **Rückwärts-Wiedergabe** (`reverseVideo`) + **Startframe**.

---

## `create_trajectory.m` — Referenztrajektorie per Klick erzeugen (MP4)

**Zweck:** Manuell eine Soll-/Referenztrajektorie auf dem ersten Videoframe
festlegen, sie auf gleiche Abstände umrechnen und als `.mat` speichern.

**Ablauf:**
1. MP4 wählen (`uigetfile`), nur den **ersten Frame** lesen (`read(v,1)`, auf
   RGB gebracht).
2. **Mittelpunkt anklicken** (1 Linksklick, `ginput(1)`) → `cochleaCenter`
   (`[x,y]=[col,row]`, cyan markiert). Wird von `cochlea_model_tracking2.m`
   als `M` verwendet.
3. `collectTrajectory(firstFrame)` (lokale Funktion): zeigt den Frame, per
   **Linksklick** wird ein rotes Kreuz gesetzt (beliebig oft), die Punkte
   werden mit einer Linie verbunden. **"Bestätigen"** (oder Fenster schließen)
   beendet die Eingabe. Event-gesteuert/flackerfrei (Bild + Marker einmal
   anlegen, nur `set(XData/YData)`). Rückgabe `pts = [x,y]` in Klick-Reihenfolge.
4. **Gleiche Abstände, gleiche Punktanzahl:** dichte Spline-Kurve durch die
   Klicks (`spline`, 2000 Punkte), Bogenlänge `s` (streng monoton via `unique`),
   dann `nPts` (= Anzahl Klicks) gleichmäßig über `s` verteilte Punkte
   (`interp1`). Methode angelehnt an die äquidistante Resampling-Logik in
   `tip_track_matching_spline.m`, aber mit **fester Punktanzahl** statt festem
   Abstand `d`.
5. Ergebnis-Plot über dem ersten Frame (Mittelpunkt, rohe Klicks, Spline +
   äquidistante Punkte).
6. Speichern neben dem Video als `<videoname>_trajectory.mat` mit
   `TipCoordinates` (äquidistant, `[row,col]`), `clickedPoints`
   (rohe Klicks, `[x,y]`) und `cochleaCenter` (`[x,y]`).

---

## `segment_wire_sam2.py` — Draht-Segmentierung mit SAM 2 (Python)

**Zweck:** Schritt 1 des zweistufigen Workflows für `kruemung.m`/`kruemung_jinhan.m`.
Segmentiert den Draht mit dem **Segment Anything Model 2 (Meta)** und speichert
pro Frame/Bild eine PNG-Maske (weiß = Draht) in `<name>_sam2_masks\frame_%05d.png`
(1-basiert) neben dem Video bzw. Bilderordner.

**Ablauf:**
1. Auswahlfenster **„Video (.avi)" / „Bilderordner (.jpg)"** → Datei/Ordner
   wählen. Bei Bilderordner werden die JPGs alphabetisch sortiert kopiert (=
   `imageDatastore`-Reihenfolge in MATLAB), bei Video die Frames extrahiert.
2. Am **`PROMPT_FRAME` (Standard: 10.)** Bild interaktiv Klick-Prompts setzen:
   Linksklick = Punkt auf dem Draht (positiv), Rechtsklick = nicht Draht
   (negativ), Taste `u` = letzten Klick rückgängig, Enter = bestätigen. Live-
   Overlay der aktuellen Maske.
3. **Bidirektionale Propagation** durch das ganze Video (`propagate_in_video`
   vorwärts + `reverse=True`), Masken als PNG speichern.
4. `imwrite_unicode()` (imencode + `open`) speichert Unicode-sicher (`cv2.imwrite`
   scheitert still an Umlaut-Pfaden wie `Wöhlken`) und wirft bei Fehler; am Ende
   Verifikation der PNG-Anzahl.

**Konfiguration:** `MODEL_SIZE="auto"` (CUDA-GPU → `base_plus`, nur CPU →
`tiny`); Checkpoint wird beim ersten Start automatisch in `checkpoints/` geladen.

---

## `README_SAM2.md` — Einrichtung & Bedienung des SAM-2-Workflows

Anleitung für `segment_wire_sam2.py`: PowerShell-`venv`-Einrichtung
(`py -m venv`, `Activate.ps1`, ExecutionPolicy-Bypass), Git-freie Installation
über das GitHub-**ZIP** (`pip install https://github.com/.../sam2/.../main.zip`),
Hinweis **`py` statt `python`** (ein von Inkscape o.ä. mitgeliefertes `python`
erzeugt ein kaputtes venv), GPU/CPU-Automatik, sowie Nutzung und häufige
Fehlermeldungen (fehlende Masken, Maskenanzahl ≠ Frameanzahl).

---

## Git / Workflow

- Entwicklungsbranch: **`claude/magical-noether-e66dy1`** (Repo
  `LucaMuskelmasse/mhh`). Commits/Pushes gehen dorthin; keine PRs ohne
  ausdrückliche Aufforderung.
