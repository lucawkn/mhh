# Krümmungsauswertung `kruemung_jinhan_v2_luca.m`

Diese Datei beschreibt, wie `kruemung_jinhan_v2_luca.m` aus den
Schwarz/Weiß-Masken eines Drahtvideos die Krümmungswerte und Plots erzeugt.

---

## 1. Überblick

Das Skript bestimmt für jeden Frame eines `.avi`-Videos die **Krümmung eines
Drahts entlang seiner Länge** und stellt sie über der Zeit dar.

Es gibt zwei Schritte:

1. **Segmentierung (Python, einmal pro Video):** `segment_wire_sam2.py`
   segmentiert den Draht mit SAM 2 und speichert pro Frame eine
   Schwarz/Weiß-Maske als `<videoname>_sam2_masks\frame_00001.png`, … neben
   dem Video. Weiß bedeutet Draht, schwarz Hintergrund. Einrichtung: siehe
   `README_SAM2.md`.
2. **Auswertung (MATLAB):** `kruemung_jinhan_v2_luca.m` lädt diese Masken und
   berechnet daraus die Krümmung.

### Ablauf pro Frame

```mermaid
flowchart TD
    A[SAM-2-Maske laden<br/>frame_xxxxx.png] --> B[Größte weiße Fläche behalten]
    B --> C[Bereinigen<br/>bwareaopen, imclose]
    C --> D[Draht wählen<br/>größte MajorAxisLength]
    D --> E[Skelett<br/>bwskel = 1 Pixel breite Mittellinie]
    E --> F[Startpunkt wählen<br/>Länge = 0, nachverfolgt]
    F --> G[Skelettpixel nach Bogenlänge ordnen<br/>bwdistgeodesic]
    G --> H[Least-Squares-Spline<br/>durch alle Skelettpixel]
    H --> I[Krümmung analytisch<br/>aus Spline-Ableitungen]
    I --> J[Mittelwert und Verlauf speichern<br/>ImageData]
    J --> K[Plots: Mittelwert über Zeit,<br/>3D Länge × Zeit, Slider]
```

---

## 2. Parameter (oben im Skript)

| Parameter | Standard | Bedeutung |
|---|---|---|
| `pxPerMm` | `1` | Kalibrierung des Videos [px/mm]. **Muss eingetragen werden**, sonst sind die Werte in 1/px statt 1/mm. Messen z. B. mit `imdistline` an einer bekannten Länge im Frame. |
| `kappaInlay` | `0.4252` | Mittlere Krümmung des Inlays [1/mm], exakt aus der Geometrie (`inlayGeometry_v2.m`). Wird nur als Referenzlinie geplottet. |
| `knotSpacing` | `40` | Knotenabstand der Spline [px]. Größer heißt glatter, kleiner heißt detailreicher, aber verrauschter. |
| `nParamIter` | `3` | Anzahl der Fußpunkt-Iterationen beim Spline-Fit (Abschnitt 3.7). `0` ordnet die Pixel nur über die Bogenlänge zu. |
| `Neval` | `200` | Anzahl der Auswertepunkte entlang der Spline je Frame. |
| `outlierWin` | `3` | Ausreißer-Erkennung: Anzahl der Nachbarframes je Seite (Abschnitt 3.10). |
| `outlierNSigma` | `4` | Ausreißer-Erkennung: Schwelle in robusten Standardabweichungen der Nachbarn. |
| `outlierMinJump` | `0.15` | Ausreißer-Erkennung: Mindestabweichung vom Median der Nachbarn [1/mm]. |
| `kappaPhysMax` | `2` | Mittlere Krümmung, ab der ein Frame immer als Ausreißer gilt [1/mm]. |

Diese Werte stehen fest im Code: `bwareaopen(…, 300)`, `gapCloseRadius = 1`
und `bwskel(…, 'MinBranchLength', 25)`.

---

## 3. Von der Maske zur Krümmung (pro Frame)

### 3.1 Vorbereitung (vor der Schleife)

- Ein Dialog fragt, welches `.avi` ausgewertet werden soll.
- Das Skript prüft, ob der Ordner `<videoname>_sam2_masks` existiert und ob die
  Anzahl der Masken genau der Anzahl der Frames entspricht. Andernfalls bricht
  es mit einem `error` ab, damit keine Maske dem falschen Frame zugeordnet wird.
- Der Zeitvektor ist `tVec = (0:N-1)/frameRate` in Sekunden.
- Der Dialog **„Maskenkontrolle“** fragt, ob die Maske jedes Frames angezeigt
  werden soll. Standard ist „Nicht anzeigen“, das ist schneller.

### 3.2 Maske laden

```matlab
tubeFG = imread(maskFile) > 0;   % true = Draht
```

Nur die **größte zusammenhängende weiße Fläche** bleibt erhalten. Kleine
Fehlsegmentierungen fallen damit weg. Wenn im Dialog „Anzeigen“ gewählt wurde,
erscheint diese Maske in `figure(1)`.

### 3.3 Bereinigen und Draht auswählen

- `bwareaopen(tubeFG, 300)` entfernt Flächen mit weniger als 300 Pixeln.
- `imclose(…, strel('disk', 1))` schließt kleine Lücken im Draht.
- Bleiben mehrere Flächen übrig, wird die mit der **größten Hauptachsenlänge**
  (`MajorAxisLength`) als Draht gewählt, also die am stärksten langgestreckte.
  Das ist robuster als die größte Fläche, weil z. B. runde Luftblasen viel
  Fläche haben können, aber kurz sind.

### 3.4 Skelettieren

```matlab
skel = bwskel(tubeMain, 'MinBranchLength', 25);
```

Das Skelett ist die **Mittellinie** des Drahts, ein Pixel breit. Kurze
Seitenäste unter 25 px werden entfernt. Am Ende der Linie ist das Skelett etwa
um die halbe Drahtbreite kürzer als der Draht selbst.

### 3.5 Startpunkt (Länge = 0) festlegen

Die Endpunkte des Skeletts liefert `bwmorph(skel, 'endpoints')`. Als
Startpunkt wählt das Skript:

- **im ersten verwertbaren Frame** den Endpunkt mit dem kleinsten Abstand zum
  Bildrand. Das wird als eingespanntes Ende angenommen.
- **in jedem weiteren Frame** den Endpunkt, der dem Startpunkt des vorherigen
  Frames am nächsten liegt (`prevStart`).

So zeigt „Länge = 0“ über das ganze Video auf dieselbe Stelle am Draht. Das ist
für den 3D-Plot wichtig.

### 3.6 Skelettpixel nach Bogenlänge ordnen

```matlab
D = bwdistgeodesic(skel, x0, y0, 'quasi-euclidean');
```

Für jedes Skelettpixel wird der Weg **entlang des Skeletts** vom Startpunkt
berechnet, die geodätische Distanz $d$ in px. Damit sind alle Pixel entlang
des Drahts geordnet. Unerreichbare Pixel (`Inf`) und doppelte Distanzen
(`unique`) werden entfernt.

Das Ergebnis ist eine geordnete Punktfolge $(d_i,\, x_i,\, y_i)$, also **alle**
Skelettpixel mit ihrer Position entlang des Drahts.

### 3.7 Least-Squares-Spline durch alle Skelettpixel (`fitSplineLSQ`)

**Problem:** Die Skelettpixel liegen auf einem ganzzahligen Pixelraster. Ein
glatter Bogen wird dadurch zu einer Treppe. Leitet man die Pixelpunkte direkt
numerisch zweimal ab, misst man die Treppe und nicht den Draht. Die Krümmung
ist dann reines Rauschen, im Test etwa 45-mal zu groß.

**Lösung:** Durch die Pixel wird eine glatte, parametrische, kubische Spline
gelegt:

$$
S(t) = \begin{pmatrix} S_x(t) \\ S_y(t) \end{pmatrix}, \qquad t = \text{Bogenlänge in px}
$$

- **Knoten:** gleichmäßig im Abstand `knotSpacing` über die Drahtlänge,
  mindestens 4 Knoten. Zwischen zwei Knoten ist die Spline ein kubisches
  Polynom. Die Spline hat damit **deutlich weniger Freiheitsgrade als es Pixel
  gibt**. Sie kann der Form des Drahts folgen, aber nicht jeder Treppenstufe.
- **Fit:** Die Spline-Koeffizienten $c$ werden so bestimmt, dass der quadratische
  Abstand aller Pixel zur Spline minimal ist:

  $$
  \min_{c}\ \sum_i \bigl\lVert P_i - S(t_i) \bigr\rVert^2
  $$

  Das ist ein **lineares** Least-Squares-Problem. Die Basismatrix $B$ entsteht
  aus `spline(knots, eye(nKnots))`: Spalte $j$ ist die kubische Spline, die im
  Knoten $j$ den Wert 1 und in allen anderen Knoten den Wert 0 hat. Damit gilt
  $S_x(t) = B(t)\,c_x$ und die Lösung ist `cx = B \ x`, für $y$ genauso. Dafür
  ist keine Toolbox nötig.
- **Fußpunkt-Korrektur (`nParamIter` = 3):** Nach jedem Fit wird der Parameter
  $t_i$ jedes Pixels auf den **nächstgelegenen Punkt der Spline** verschoben
  (ein Gauss-Newton-Schritt), danach wird neu gefittet. Dadurch wird der echte
  **senkrechte Abstand** der Pixel zur Kurve minimiert und nicht nur der
  Abstand bei fester Bogenlänge:

  $$
  t_i \leftarrow t_i + \frac{(P_i - S(t_i)) \cdot S'(t_i)}{\lVert S'(t_i) \rVert^2}
  $$

- **Kontrollwert `fitRMS`:** der mittlere Abstand der Pixel zur Spline in px.
  Etwa 0,3–0,4 px ist normal, das ist das Rauschen durch das Pixelraster.
  Deutlich über 0,5 px heißt, die Spline ist zu steif (`knotSpacing`
  verkleinern). Deutlich darunter heißt, sie folgt der Treppe (`knotSpacing`
  vergrößern).

### 3.8 Krümmung analytisch berechnen (`splineCurvature`)

Die Spline ist stückweise ein Polynom. Ihre Ableitungen werden deshalb **exakt**
gebildet (`ppDeriv`: Polynomkoeffizienten ableiten) und nicht numerisch
geschätzt. An `Neval = 200` gleichmäßig verteilten Stellen $s$ entlang des
Drahts gilt:

$$
\kappa(s) = \frac{\lvert x'(s)\, y''(s) - y'(s)\, x''(s) \rvert}{\bigl(x'(s)^2 + y'(s)^2\bigr)^{3/2}}
\qquad [1/\text{px}]
$$

- $\kappa = 1/R$, wobei $R$ der Radius des Kreises ist, der den Draht an dieser
  Stelle am besten annähert. Eine Gerade hat $\kappa = 0$.
- Es wird der **Betrag** genommen, die Biegerichtung (links/rechts) geht also
  nicht ein.
- Die **mittlere Krümmung** des Frames ist der Mittelwert über die 200 Punkte.
  Weil die Punkte gleichmäßig entlang der Länge verteilt sind, ist das der
  Mittelwert über die Bogenlänge.

### 3.9 Gespeicherte Daten (`ImageData(n)`)

| Feld | Inhalt |
|---|---|
| `rgb` | Originalbild des Frames |
| `bw` | bereinigte Maske |
| `skel` | Skelett |
| `xs`, `ys` | Spline-Punkte (200) in Bildkoordinaten [px] |
| `s` | Bogenlänge dieser Punkte ab dem Startpunkt [px] |
| `kappa` | Krümmung an diesen Punkten [1/px] |
| `mean_kappa` | mittlere Krümmung des Frames [1/px] |
| `fitRMS` | RMS-Abstand Skelettpixel ↔ Spline [px] |

Ist ein Frame nicht auswertbar (keine Fläche, kein Skelett, weniger als 4
Skelettpunkte), werden die Werte mit `NaN` gefüllt und es erscheint eine
`warning`. Das Skript läuft dann weiter.

### 3.10 Ausreißerframes durch Nachbarn ersetzen (`replaceOutlierFrames`)

Nach der Schleife liegt für jeden Frame eine mittlere Krümmung vor. Einzelne
Frames können dabei völlig falsche Werte haben, z. B. wenn die Maske nur ein
winziges Drahtstück enthält und die Spline sich dadurch extrem krümmt. In
einem Datensatz traten so Werte bis über 8000 1/mm auf. Solche Frames würden
das Maximum bestimmen.

Ein Frame gilt deshalb als **Ausreißer**, wenn eine dieser Bedingungen zutrifft:

1. **Physikalisch unmöglich:** Die mittlere Krümmung ist größer als
   `kappaPhysMax` = 2 1/mm. Das entspricht einem mittleren Radius unter
   0,5 mm, wie die Grenze `Rmin_physMin` im v16-Skript.
2. **Weicht stark von den Nachbarn ab:** Verglichen wird mit den gültigen
   Frames in ±`outlierWin` = 3 Frames, ohne den Frame selbst:

   $$
   \lvert \kappa_i - \operatorname{median}(\text{Nachbarn}) \rvert
   > \max\bigl(\texttt{outlierMinJump},\ \texttt{outlierNSigma} \cdot 1{,}4826 \cdot \text{MAD}(\text{Nachbarn})\bigr)
   $$

   mit `outlierMinJump` = 0,15 1/mm (wie `absArtifactJump` im v16-Skript) und
   `outlierNSigma` = 4. Die Prüfung läuft bis zu dreimal, damit auch mehrere
   Fehlframes hintereinander erkannt werden.

Ausreißer werden **durch ihre Nachbarn ersetzt**, und zwar durch lineare
Interpolation über die Zeit zwischen dem nächsten gültigen Frame davor und
danach. Am Anfang oder Ende des Videos wird der nächste gültige Wert
übernommen. In der Konsole steht für jeden ersetzten Frame der alte und der
neue Wert.

**Was erhalten bleibt (getestet):**
- echte Sprünge, z. B. von 0,20 auf 0,35 1/mm innerhalb eines Frames
- ein kurzer echter Peak, z. B. +0,08 1/mm über 3 Frames

Bei einem Sprung ist die Streuung der Nachbarn groß, deshalb greift das
Kriterium dort nicht.

**Grenzen:**
- Ab 4 Fehlframes hintereinander unter 2 1/mm wertet das Skript die Werte als
  echtes Plateau und ersetzt sie nicht.
- Ein echter Peak, der nur einen einzigen Frame dauert und mehr als 0,15 1/mm
  über seinen Nachbarn liegt, würde ebenfalls ersetzt.

---

## 4. Plots und Ausgaben

Intern rechnet das Skript in Pixeln. Erst für die Plots wird umgerechnet:

$$
\kappa_{\text{mm}} = \kappa_{\text{px}} \cdot \texttt{pxPerMm},
\qquad s_{\text{mm}} = s_{\text{px}} / \texttt{pxPerMm}
$$

### `figure(1)`: Maskenkontrolle (optional)

Die Schwarz/Weiß-Maske jedes Frames während der Auswertung. Sie erscheint nur,
wenn im Dialog „Anzeigen“ gewählt wurde.

### `figure(2)`: Mittlere Krümmung über der Zeit

- Die Kurve zeigt `mean_kappa` jedes Frames in **1/mm** über der Zeit in s,
  nach der Ausreißer-Ersetzung (Abschnitt 3.10).
- Die gestrichelte Linie **„Inlay (Ziel)“** liegt bei `kappaInlay`, der
  mittleren Krümmung der Inlay-Form. Erreicht die Kurve diese Linie, ist der
  Draht im Mittel so stark gekrümmt wie das Inlay.

### `figure(3)`: Krümmung über Länge und Zeit (3D)

- Achsen: Zeit [s], Länge ab Startpunkt [mm] und Krümmung [1/mm]. Die
  Krümmung ist zusätzlich farbcodiert.
- Alle Frames werden per `interp1` auf eine **gemeinsame Längsachse** von 0 bis
  zur größten gemessenen Länge gelegt. Ist der Draht in einem Frame kürzer,
  bleibt dahinter eine Lücke (`NaN`).
- Ausreißerframes erscheinen als Lücke.
- Der Plot ist mit der Maus drehbar. Mit `view(2)` siehst du ihn von oben als
  Heatmap. Darin erkennt man gut, **wo** und **wann** sich der Draht biegt.

### Fenster „Krümmungsdarstellung“: Slider

Das Originalbild jedes Frames, darüber die Spline als farbige Linie (jet,
blau = schwach, rot = stark gekrümmt). Mit dem Slider blätterst du durch die
Frames. Die Farbskala reicht von der kleinsten bis zur größten Krümmung im
ganzen Video, ohne Ausreißerframes. Bei einem Ausreißerframe wird keine Linie
gezeichnet, und der Titel zeigt „Ausreißer – ausgeblendet“.

### Konsolenausgabe

- die ersetzten Ausreißerframes mit altem und neuem Wert
- größte und letzte mittlere Krümmung in 1/mm, jeweils mit Radius in mm, nach
  der Ausreißer-Ersetzung
- die Inlay-Referenz
- der mittlere und der größte `fitRMS` über alle Frames
- eine Warnung, solange `pxPerMm = 1` gesetzt ist

---

## 5. Referenz: `inlayGeometry_v2.m`

`inlayGeometry_v2.m` erzeugt die Inlay-Geometrie: eine gerade Einlaufstrecke
und sechs Kreisbögen. Es berechnet daraus

- die **exakte** mittlere Krümmung (Gerade $\kappa = 0$, Bogen $\kappa = 1/r$,
  gewichtet mit der Bogenlänge): **0,4252 1/mm**, also ein mittlerer Radius von
  ≈ 2,35 mm. Dieser Wert steht als `kappaInlay` im Auswerteskript.
- zum Vergleich die Krümmung mit **derselben Spline-Methode**. Daran sieht man,
  wie genau die Methode bei dem gewählten Maßstab und `knotSpacing` ist.

Die Hilfsfunktionen `fitSplineLSQ`, `splineCurvature` und `ppDeriv` sind dort
als Kopie enthalten. Wer sie oder `knotSpacing` ändert, muss das in **beiden**
Dateien tun.

---

## 6. Genauigkeit und Grenzen

- **Test** an künstlich auf Pixel gerundeten Kreisen und Spiralen mit
  Radius 80–330 px und `knotSpacing = 40`:
  - mittlere Krümmung: etwa **2 %** Fehler
  - lokale Krümmung in der Drahtmitte: etwa **7 %**
  - Inlay bei 30 px/mm: Spline 0,4346 gegenüber exakt 0,4252 1/mm
- **Drahtenden:** Dort ist die lokale Krümmung ungenauer, weil die Spline nur
  auf einer Seite Punkte hat. Ausreißer am Anfang oder Ende der Längsachse im
  3D-Plot sind meist ein Messfehler.
- **`knotSpacing`** ist der Regler zwischen Glätten und Detail. Ohne diese
  Begrenzung, also mit einer Spline durch jedes Pixel, kommt das
  Pixelrauschen vollständig zurück. Wählen über `fitRMS` (Abschnitt 3.7).
- **2D-Projektion:** Die Kamera sieht nur die Bildebene. Biegt sich der Draht
  aus dieser Ebene heraus, wird die Krümmung unterschätzt.
- **Startpunkt:** Das Skript nimmt an, dass im ersten Frame das eingespannte
  Ende dem Bildrand am nächsten liegt und dass sich das Ende von Frame zu Frame
  nur wenig bewegt. Das sollte man bei einem neuen Versuchsaufbau einmal prüfen.
- **Maßstab:** Absolute Werte in mm und 1/mm stimmen nur mit einem korrekt
  eingetragenen `pxPerMm` für genau diese Kameraeinstellung.

---

## 7. Batch-Version mit Excel-Export: `kruemung_jinhan_v2_luca_batch.m`

Die Batch-Version wertet **alle `.avi`-Videos eines Ordners** nacheinander aus.
Die Krümmung pro Frame wird genau wie oben berechnet (Abschnitt 3). Statt Plots
schreibt das Skript pro Video drei Kennwerte in die Testlisten-Excel.

**Ablauf:**

1. Ordner mit den Videos wählen und die Excel-Datei einmal wählen.
2. Für jedes Video die Testparameter aus dem Dateinamen lesen:
   `...-<Pulslänge>-<Pulspause>-<Pulsanzahl>-<Spannung>`. Beispiel:
   `KP-MV71-11-15-15-2-3.4 20260908_170422_video` bedeutet 15 ms Pulslänge,
   15 ms Pause, 2 Pulse und 3,4 V.
3. Die passende Zeile suchen: Blatt `Pulslänge-15ms`, dann der Block mit
   passender Pulsanzahl und Pause, dann die Zeile mit der passenden Spannung.
4. Ist Spalte **Z** dieser Zeile schon gefüllt, wird das Video **übersprungen**,
   ohne es auszuwerten. So kann man einen abgebrochenen Lauf einfach neu
   starten.
5. Alle Masken auswerten, **Ausreißerframes durch ihre Nachbarn ersetzen**
   (Abschnitt 3.10, gleiche Parameter wie im Einzelskript) und daraus die
   Kennwerte bilden (siehe Tabelle). Die ersetzten Frames stehen in der
   Konsole.
6. Die Kennwerte eintragen. Es werden **nur leere Zellen** beschrieben, Z kommt
   zuletzt.

| Spalte | Inhalt |
|---|---|
| W | größte mittlere Krümmung über alle Frames [1/mm] |
| X | mittlere Krümmung im letzten auswertbaren Frame [1/mm] |
| Y | Zeitpunkt der größten mittleren Krümmung [s] |
| Z | Name des Videos (Abschlussmarker) |

Die Spalten M:V gehören dem v16-Skript und werden nicht angefasst.

**Feste Einstellungen:** `pxPerMm = 43`. Die Bildrate kommt aus der Videodatei.
Es entstehen keine Plots, und die RGB-Frames werden nicht geladen.

**Ausgabe am Ende:** wie viele Videos ausgewertet, übersprungen oder
fehlgeschlagen sind, jeweils mit Namen.

---

## 8. Variante mit Ausschluss-Rechteck: `kruemung_jinhan_v2_luca_rect.m`

Diese Variante rechnet genau wie `kruemung_jinhan_v2_luca.m`, mit einem
zusätzlichen Schritt vor der Auswertung:

1. Nach dem Dialog „Maskenkontrolle“ erscheint der **erste Frame des Videos**.
2. Du ziehst mit der Maus ein **Rechteck**. Es lässt sich noch verschieben und
   in der Größe ändern. Ein **Doppelklick ins Rechteck** bestätigt es. Schließt
   du das Fenster, ohne zu bestätigen, wird kein Rechteck verwendet.
3. In **allen Frames** wird die SAM-2-Maske innerhalb des Rechtecks auf schwarz
   gesetzt, so als wäre dort kein Draht. Das passiert direkt nach dem Laden der
   Maske. Dort entstehen also weder Skelett noch Krümmungswerte.
4. Im Slider-Fenster ist das Rechteck rot gestrichelt eingezeichnet.

Typischer Einsatz: Halter, Einspannung oder Spiegelungen, die SAM 2
fälschlich zum Draht zählt.

**Hinweis Startpunkt:** Schneidet das Rechteck den Draht ab, entsteht an der
Rechteckkante ein neues Drahtende. Der Startpunkt (Länge = 0) wird weiterhin
als das Ende gewählt, das dem **Bildrand** am nächsten liegt (Abschnitt 3.5).

