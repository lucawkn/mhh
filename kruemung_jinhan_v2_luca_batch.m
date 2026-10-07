% Function:
% BATCH-Version von kruemung_jinhan_v2_luca.m:
% Krümmung eines DRAHTS für ALLE .avi-Videos eines Ordners bestimmen
% (SAM-2-Segmentierung) und die Kennwerte in die Testlisten-Excel schreiben.
%
% Krümmungsberechnung pro Frame IDENTISCH zu kruemung_jinhan_v2_luca.m:
%   SAM-2-Maske -> bereinigen -> Skelett -> Startpunkt nachverfolgen ->
%   Bogenlänge -> Least-Squares-Spline -> Krümmung analytisch -> Mittelwert.
%   (Details: README_kruemung_jinhan_v2.md)
%
% Batch/Excel-Logik übernommen aus kruemmung_jinhan_v16_batch_skip_excel.m:
%   - Ordner mit AVI-Videos wählen, alle Videos nacheinander auswerten
%   - nur Videos mit vollständigem <videoname>_sam2_masks-Ordner
%   - Testparameter aus dem Dateinamen: ...-<Pulslaenge>-<Pulspause>-<Pulsanzahl>-<Spannung> ...
%   - Excel-Datei nur EINMAL wählen, jedes Ergebnis in die passende Zeile
%   - Spalten W:Z (M:V gehören dem v16-Skript und bleiben unberührt):
%       W = Max mittlere Krümmung [1/mm]
%       X = End-Krümmung (letzter gültiger Frame) [1/mm]
%       Y = Zeitpunkt des Max [s]
%       Z = Video-Datei (wird ZULETZT geschrieben = Abschlussmarker)
%   - Zeilen mit gefülltem Z werden VOR der Auswertung übersprungen
%   - vorhandene Zellen werden nie überschrieben
%   - keine Plots, RGB-Frames werden nicht geladen (nur die Masken)
%
% WICHTIG: vorher pro Video einmal segment_wire_sam2.py ausführen
% (siehe README_SAM2.md).
clear; clc; close all;

pxPerMm = 43;          % Kalibrierung der Videos [px/mm]

% --- Parameter Spline-Fit (IDENTISCH zu kruemung_jinhan_v2_luca.m halten!) ---
knotSpacing = 40;    % Knotenabstand der Spline [px]: größer = glatter, kleiner = detailreicher
nParamIter  = 3;     % Fußpunkt-Iterationen (orthogonaler Abstand Punkt <-> Spline)
Neval       = 200;   % Auswertepunkte entlang der Spline (mittlere Krümmung)

% --- Excel-Export ---
excelFile = "";                  % leer = Datei zu Beginn auswählen; oder festen Pfad eintragen
skipAlreadyImported = true;      % Zeilen mit gefüllter Spalte Z (Video-Datei) überspringen
writeOnlyEmptyExcelCells = true; % vorhandene Werte in W:Z niemals überschreiben

defaultPath = "M:\xcas\_FuE_Work\Projekte\DFG MemoryCI 2.0\Dokumentation\AP01_Iterative Inlay-Entwicklung\AP 1.B BFR-Tests der blanken Inlays\Auswertung Ergebnis\BFR maximale Curl Position";

%% 0. Batch-Eingaben
batchDir = uigetdir(defaultPath, 'Ordner mit AVI-Videos fuer Batch-Auswertung waehlen');
if isequal(batchDir, 0), error('Kein Videoordner gewaehlt.'); end

videoList = dir(fullfile(batchDir, '*.avi'));
if isempty(videoList)
    error('Keine AVI-Dateien in %s gefunden.', batchDir);
end
[~, videoOrder] = sort(lower(string({videoList.name})));
videoList = videoList(videoOrder);

% Excel-Datei genau EINMAL wählen
excelPath = string(excelFile);
if strlength(excelPath) == 0
    [xlsxName, xlsxDir] = uigetfile({'*.xlsx','Excel-Datei (*.xlsx)'}, ...
        'Testparameter-Excel fuer Batch-Export waehlen', defaultPath);
    if isequal(xlsxName, 0), error('Keine Excel-Datei gewaehlt.'); end
    excelPath = string(fullfile(xlsxDir, xlsxName));
end
if ~isfile(excelPath)
    error('Excel-Datei nicht gefunden: %s', excelPath);
end

fprintf('\n============================================================\n');
fprintf('BATCH-AUSWERTUNG (Spline-Kruemmung): %d AVI-Dateien gefunden\n', numel(videoList));
fprintf('Videoordner: %s\n', batchDir);
fprintf('Excel:       %s (Spalten W:Z)\n', excelPath);
fprintf('Massstab:    %g px/mm\n', pxPerMm);
fprintf('============================================================\n');

nSuccess = 0;
nSkipped = 0;
nFailed  = 0;
nAlreadyExcel = 0;
skippedNames   = strings(0,1);
failedNames    = strings(0,1);
failedMessages = strings(0,1);

%% 1. Schleife über alle Videos
for batchIdx = 1:numel(videoList)
    vidFile = videoList(batchIdx).name;
    [~, vidName] = fileparts(vidFile);

    fprintf('\n\n============================================================\n');
    fprintf('[%d/%d] %s\n', batchIdx, numel(videoList), vidFile);
    fprintf('============================================================\n');

    try
        % Testparameter aus dem Dateinamen: ...-Pulslaenge-Pulspause-Pulsanzahl-Spannung
        [pLen, pCount, pPause, vSet] = parseVideoTestParams(vidName);
        fprintf('Zuordnung: Pulslänge=%g ms | Pulsanzahl=%g | Pulspause=%g ms | Spannung=%g V\n', ...
            pLen, pCount, pPause, vSet);

        % Schon importiert? (Spalte Z gefüllt) -> VOR der Auswertung überspringen
        if skipAlreadyImported
            excelState = getExcelTargetState(excelPath, pLen, pCount, pPause, vSet);
            if excelState.imported
                fprintf('UEBERSPRUNGEN: Excel bereits befuellt | %s | Zeile %d | Video-Datei=%s\n', ...
                    excelState.sheet, excelState.row, string(excelState.videoCell));
                nSkipped = nSkipped + 1;
                nAlreadyExcel = nAlreadyExcel + 1;
                skippedNames(end+1,1) = string(vidFile);
                continue;
            end
        end

        % SAM-2-Masken prüfen
        maskDir = fullfile(batchDir, [vidName '_sam2_masks']);
        if ~isfolder(maskDir)
            warning('Uebersprungen: kein SAM-2-Maskenordner: %s', maskDir);
            nSkipped = nSkipped + 1;
            skippedNames(end+1,1) = string(vidFile);
            continue;
        end

        % VideoReader nur für Frameanzahl und Bildrate (RGB-Frames werden nicht geladen)
        v = VideoReader(fullfile(batchDir, vidFile));
        ImageNummax = v.NumFrames;
        tVec = (0:ImageNummax-1).' / v.FrameRate;   % Zeit je Frame [s]

        maskListing = dir(fullfile(maskDir, 'frame_*.png'));
        if numel(maskListing) ~= ImageNummax
            warning('Uebersprungen: Maskenanzahl (%d) != Frameanzahl (%d).', ...
                numel(maskListing), ImageNummax);
            nSkipped = nSkipped + 1;
            skippedNames(end+1,1) = string(vidFile);
            continue;
        end

        % --- Krümmung pro Frame (wie kruemung_jinhan_v2_luca.m) ---
        meanKappa_px = nan(ImageNummax, 1);
        fitRMS       = nan(ImageNummax, 1);
        prevStart    = [];   % Startpunkt (Länge = 0) des vorherigen Frames [x y]
        for n = 1:ImageNummax
            maskFile = fullfile(maskDir, sprintf('frame_%05d.png', n));
            mask = imread(maskFile) > 0;   % true = Draht
            [meanKappa_px(n), fitRMS(n), prevStart] = frameMeanCurvature(mask, prevStart, ...
                knotSpacing, nParamIter, Neval);
            if isnan(meanKappa_px(n))
                warning('Frame %d: nicht auswertbar - wird mit NaN gefüllt.', n);
            end
        end

        % --- Kennwerte des Videos ---
        meanKappa_mm = meanKappa_px * pxPerMm;   % 1/px -> 1/mm
        iLast = find(isfinite(meanKappa_mm), 1, 'last');
        if isempty(iLast)
            error('Kein Frame auswertbar.');
        end
        [kMax, iMax] = max(meanKappa_mm, [], 'omitnan');
        tMax = tVec(iMax);
        kEnd = meanKappa_mm(iLast);

        fprintf('Max mittlere Krümmung : %.4f 1/mm (Radius %.2f mm) bei t = %.3f s (Frame %d)\n', ...
            kMax, 1/kMax, tMax, iMax);
        fprintf('End-Krümmung          : %.4f 1/mm (Radius %.2f mm), Frame %d\n', ...
            kEnd, 1/kEnd, iLast);
        fprintf('Gueltige Frames       : %d / %d | Spline-Fit RMS %.2f px (max %.2f px)\n', ...
            nnz(isfinite(meanKappa_mm)), ImageNummax, mean(fitRMS, 'omitnan'), max(fitRMS));

        % --- Excel-Export (W:Z, Z zuletzt) ---
        exportInfo = writeResultsToExcel(excelPath, pLen, pCount, pPause, vSet, vidName, ...
            kMax, kEnd, tMax, writeOnlyEmptyExcelCells);
        fprintf('Excel: %s | Zeile %d | %d neue Zelle(n) geschrieben\n', ...
            exportInfo.sheet, exportInfo.row, exportInfo.nWritten);

        nSuccess = nSuccess + 1;
        fprintf('FERTIG: %s\n', vidFile);

    catch MEbatch
        nFailed = nFailed + 1;
        failedNames(end+1,1) = string(vidFile);
        failedMessages(end+1,1) = string(MEbatch.message);
        warning('FEHLER bei "%s": %s', vidFile, MEbatch.message);
    end
end

%% 2. Batch-Abschluss
fprintf('\n\n============================================================\n');
fprintf('BATCH FERTIG\n');
fprintf('  erfolgreich ausgewertet: %d\n', nSuccess);
fprintf('  uebersprungen gesamt:    %d\n', nSkipped);
fprintf('    davon bereits in Excel: %d\n', nAlreadyExcel);
fprintf('  Fehler:                  %d\n', nFailed);
fprintf('============================================================\n');

if nSkipped > 0
    fprintf('\nUebersprungene Videos (bereits in Excel oder fehlende/unvollstaendige Masken):\n');
    for i = 1:numel(skippedNames), fprintf('  - %s\n', skippedNames(i)); end
end
if nFailed > 0
    fprintf('\nFehlerhafte Videos:\n');
    for i = 1:numel(failedNames)
        fprintf('  - %s\n    %s\n', failedNames(i), failedMessages(i));
    end
end


%% ==================== Lokale Funktionen ====================

%% Krümmung eines Frames (Pipeline IDENTISCH zu kruemung_jinhan_v2_luca.m)
% Rückgabe: mittlere Krümmung [1/px] (NaN = Frame nicht auswertbar),
% RMS-Abstand Skelettpixel <-> Spline [px], aktualisierter Startpunkt.
function [meanKappa, fitRMS, prevStart] = frameMeanCurvature(tubeFG, prevStart, ...
        knotSpacing, nParamIter, Neval)
    meanKappa = NaN;
    fitRMS    = NaN;

    % Nur die größte zusammenhängende Fläche behalten
    bwLargest = false(size(tubeFG));
    ccDisp = bwconncomp(tubeFG);
    if ccDisp.NumObjects >= 1
        areas = cellfun(@numel, ccDisp.PixelIdxList);
        [~, iBig] = max(areas);
        bwLargest(ccDisp.PixelIdxList{iBig}) = true;
    end
    tubeFG = bwLargest;

    tubeFG = bwareaopen(tubeFG, 300);     % kleine Specks entfernen
    gapCloseRadius = 1;                   % Lücken schließen
    tubeFG_closed = imclose(tubeFG, strel('disk', gapCloseRadius));

    % Am stärksten langgestreckte Komponente = Draht
    cc = bwconncomp(tubeFG_closed);
    if cc.NumObjects < 1
        return
    end
    stats = regionprops(cc, 'MajorAxisLength');
    [~, imax] = max([stats.MajorAxisLength]);
    tubeMain = false(size(tubeFG_closed));
    tubeMain(cc.PixelIdxList{imax}) = true;

    % Skelettieren
    skel = bwskel(tubeMain, 'MinBranchLength', 25);
    endpts   = bwmorph(skel, 'endpoints');
    [ey, ex] = find(endpts);
    [yy, xx] = find(skel);
    if isempty(ex) || numel(yy) < 2
        return
    end

    % Startpunkt (Länge = 0) über alle Frames konsistent wählen:
    % erster gültiger Frame -> Endpunkt am nächsten zum Bildrand
    % (eingespanntes Ende), danach -> Endpunkt am nächsten zum
    % Startpunkt des vorherigen Frames (Nachverfolgen).
    if isempty(prevStart)
        [H, W] = size(skel);
        distKey = min([ex-1, ey-1, W-ex, H-ey], [], 2);
    else
        distKey = hypot(ex - prevStart(1), ey - prevStart(2));
    end
    [~, iStart] = min(distKey);
    x0 = ex(iStart); y0 = ey(iStart);
    prevStart = [x0 y0];

    % Skelettpixel nach Bogenlänge ordnen
    D = bwdistgeodesic(skel, x0, y0, 'quasi-euclidean');
    d = D(sub2ind(size(skel), yy, xx));
    valid = isfinite(d);
    d  = d(valid);
    xx = xx(valid);
    yy = yy(valid);
    [d, iu] = unique(d);
    xx = xx(iu);
    yy = yy(iu);
    if numel(d) < 4
        return
    end

    % Least-Squares-Spline + Krümmung analytisch
    [ppx, ppy, fitRMS] = fitSplineLSQ(d, xx, yy, knotSpacing, nParamIter);
    s = linspace(ppx.breaks(1), ppx.breaks(end), Neval);
    [~, ~, kappa] = splineCurvature(ppx, ppy, s);
    meanKappa = mean(kappa, 'omitnan');
end


%% Excel: Ergebnisse in W:Z der passenden Testlisten-Zeile schreiben
% (angepasst aus writeResultsToTestExcel in kruemmung_jinhan_v16_batch_skip_excel.m)
% Nur leere Zellen werden beschrieben; Z (Video-Datei) wird ZULETZT geschrieben
% und dient als Abschlussmarker für den nächsten Batchlauf.
function info = writeResultsToExcel(excelPath, pLen, pCount, pPause, vSet, vidName, ...
        kMax, kEnd, tMax, writeOnlyEmpty)
    firstCol = 23;   % W
    nCols    = 4;    % W:Z

    state = getExcelTargetState(excelPath, pLen, pCount, pPause, vSet);
    sheetName = state.sheet;
    targetRow = state.row;
    headerRow = state.headerRow;
    colRange  = @(r) sprintf('%s%d:%s%d', excelColumnName(firstCol), r, ...
                             excelColumnName(firstCol+nCols-1), r);

    headers = {'Spline Max mittl. Kruemmung [1/mm]', 'Spline End-Kruemmung [1/mm]', ...
               'Spline Zeitpunkt Max [s]', 'Spline Video-Datei'};

    % Header nur dort eintragen, wo er noch fehlt
    rawHeader = readcell(excelPath, 'Sheet', sheetName, 'Range', colRange(headerRow));
    for j = 1:nCols
        if j > numel(rawHeader) || isExcelCellEmpty(rawHeader{j})
            col = excelColumnName(firstCol + j - 1);
            writecell(headers(j), excelPath, 'Sheet', sheetName, 'Range', sprintf('%s%d', col, headerRow));
        end
    end

    values = {kMax, kEnd, tMax, char(vidName)};

    existing = readcell(excelPath, 'Sheet', sheetName, 'Range', colRange(targetRow));
    if numel(existing) < nCols
        existing(end+1:nCols) = {[]};
    end

    % W:Y zuerst, Z (Video-Datei) ABSICHTLICH zuletzt
    nWritten = 0;
    for j = 1:nCols
        if ~writeOnlyEmpty || isExcelCellEmpty(existing{j})
            col = excelColumnName(firstCol + j - 1);
            writecell(values(j), excelPath, 'Sheet', sheetName, 'Range', sprintf('%s%d', col, targetRow));
            nWritten = nWritten + 1;
        end
    end

    info = struct('sheet', sheetName, 'row', targetRow, 'file', char(excelPath), ...
                  'nWritten', nWritten);
end


%% Excel: Blatt/Block/Spannungszeile finden und Abschlussmarker (Spalte Z) prüfen
% (angepasst aus kruemmung_jinhan_v16_batch_skip_excel.m: Marker Z statt V)
function state = getExcelTargetState(excelPath, pLen, pCount, pPause, vSet)
    markerCol = 26;   % Z = Spline Video-Datei

    sheetName = sprintf('Pulslänge-%gms', pLen);
    sheets = string(sheetnames(excelPath));
    if ~any(strcmp(sheets, sheetName))
        error('Excel-Blatt "%s" nicht gefunden.', sheetName);
    end

    raw = readcell(excelPath, 'Sheet', sheetName, 'Range', 'A1:Z300');
    if size(raw, 2) < markerCol            % readcell kann leere Randspalten weglassen
        raw(:, end+1:markerCol) = {[]};
    end
    nRows = size(raw, 1);
    blockParamRow = NaN;
    headerRow = NaN;

    for r = 1:nRows-3
        if isTextEqual(raw{r,2}, 'Pulslänge/ms')
            lenVal = cellToNum(raw{r+1,2});
            cntVal = cellToNum(raw{r+1,3});
            pauVal = cellToNum(raw{r+1,4});
            if isfinite(lenVal) && isfinite(cntVal) && isfinite(pauVal) && ...
               abs(lenVal-pLen) < 1e-9 && abs(cntVal-pCount) < 1e-9 && abs(pauVal-pPause) < 1e-9
                blockParamRow = r+1;
                headerRow = r+3;
                break;
            end
        end
    end
    if ~isfinite(blockParamRow)
        error('Kein Block fuer %g ms, %g Pulse, %g ms Pause gefunden.', pLen, pCount, pPause);
    end

    dataStart = headerRow+1;
    dataEnd = min(nRows, headerRow+16);   % Testliste: 2.6 .. 5.6 V in 0.2-V-Schritten
    targetRow = NaN;
    for r = dataStart:dataEnd
        cVal = cellToNum(raw{r,3});
        if isfinite(cVal) && abs(cVal-vSet) < 1e-6
            targetRow = r;
            break;
        end
    end
    if ~isfinite(targetRow)
        error('Spannung-set %.3g V im passenden Block nicht gefunden.', vSet);
    end

    videoCell = raw{targetRow, markerCol};
    imported = ~isExcelCellEmpty(videoCell);

    state = struct('sheet', sheetName, 'row', targetRow, 'headerRow', headerRow, ...
                   'imported', imported, 'videoCell', {videoCell});
end


%% Testparameter aus dem Dateinamen lesen (aus v16)
% Erwartetes Schema: ...-<Pulslaenge>-<Pulspause>-<Pulsanzahl>-<Spannung> ...
% Beispiel: KP-MV71-11-15-15-2-3.4 20260908_170422_video
%   -> 15 ms, Pause 15 ms, 2 Pulse, 3.4 V. Punkt und Komma als Dezimaltrenner.
function [pLen, pCount, pPause, vSet] = parseVideoTestParams(vidName)
    s = strrep(char(vidName), ',', '.');
    tok = regexp(s, ...
        '-(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)(?=[ _]|$)', ...
        'tokens');
    if isempty(tok)
        error(['Testparameter konnten nicht aus dem Dateinamen gelesen werden. ' ...
               'Erwartet wird am Ende des Versuchscodes: -Pulslaenge-Pulspause-Pulsanzahl-Spannung. ' ...
               'Datei: %s'], vidName);
    end

    vals = str2double(tok{end});
    pLen   = vals(1);
    pPause = vals(2);
    pCount = vals(3);
    vSet   = vals(4);

    if any(~isfinite([pLen, pCount, pPause, vSet]))
        error('Ungueltige Testparameter im Dateinamen: %s', vidName);
    end
    if abs(pCount-round(pCount)) > 1e-9 || pCount < 1
        error('Pulsanzahl ist im Dateinamen nicht plausibel: %g (%s)', pCount, vidName);
    end
    pCount = round(pCount);
end


%% Excel-Hilfsfunktionen (aus v16)
function tf = isExcelCellEmpty(x)
% Robust für leere readcell-Werte, missing und Leerstrings.
% Numerisches NaN gilt NICHT als leer (kann ein bewusst gespeichertes Ergebnis sein).
    if isempty(x)
        tf = true;
        return;
    end
    if isstring(x)
        if ismissing(x)
            tf = true;
        else
            tf = strlength(strtrim(x)) == 0;
        end
        return;
    end
    if ischar(x)
        tf = isempty(strtrim(x));
        return;
    end
    if isnumeric(x) || islogical(x)
        tf = false;
        return;
    end
    try
        m = ismissing(x);
        if isscalar(m) && m
            tf = true;
            return;
        end
    catch
    end
    tf = false;
end

function col = excelColumnName(n)
% 1 -> A, 23 -> W, 26 -> Z, 27 -> AA
    col = '';
    while n > 0
        r = mod(n-1, 26);
        col = [char('A'+r) col]; %#ok<AGROW>
        n = floor((n-1)/26);
    end
end

function tf = isTextEqual(x, txt)
    tf = false;
    if ischar(x) || isstring(x)
        tf = strcmp(strtrim(string(x)), string(txt));
    end
end

function v = cellToNum(x)
    if isnumeric(x) && isscalar(x)
        v = double(x);
    elseif ischar(x) || isstring(x)
        v = str2double(strrep(string(x), ',', '.'));
    else
        v = NaN;
    end
end


%% Spline-Funktionen (Kopie aus kruemung_jinhan_v2_luca.m - IDENTISCH halten!)

%% Lokale Funktion: kubische Least-Squares-Spline durch die Skelettpunkte
% Parametrische Kurve S(t) = [Sx(t), Sy(t)], t = Bogenlänge [px].
% Knoten gleichmäßig im Abstand ~knotSpacing. Die Koeffizienten werden so
% bestimmt, dass sum_i |P_i - S(t_i)|^2 minimal ist (lineares Least Squares).
% Mit nParamIter > 0 wird t_i danach jeweils auf den Fußpunkt (nächster
% Punkt der Spline zu P_i) korrigiert und neu gefittet -> minimiert den
% orthogonalen Abstand der Punkte zur Kurve.
function [ppx, ppy, rms] = fitSplineLSQ(t, x, y, knotSpacing, nParamIter)
    t = t(:); x = x(:); y = y(:);

    nKnots = max(4, round((t(end) - t(1)) / knotSpacing) + 1);
    nKnots = min(nKnots, numel(t));          % nie mehr Knoten als Datenpunkte
    knots  = linspace(t(1), t(end), nKnots);

    % Basis: Spalte j = kubische Spline (not-a-knot), die in Knoten j den
    % Wert 1 und in allen anderen Knoten 0 hat. Da spline() linear in den
    % Knotenwerten ist, gilt S(t) = B(t) * c  ->  c = B \ x (Least Squares).
    ppBasis = spline(knots, eye(nKnots));

    for it = 0:nParamIter
        B   = reshape(ppval(ppBasis, t.'), nKnots, []).';   % numel(t) x nKnots
        ppx = spline(knots, (B \ x).');
        ppy = spline(knots, (B \ y).');

        ex = x - ppval(ppx, t);
        ey = y - ppval(ppy, t);
        if it == nParamIter
            break
        end

        % Fußpunkt-Korrektur (Gauss-Newton-Schritt auf |P_i - S(t_i)|^2)
        dx = ppval(ppDeriv(ppx), t);
        dy = ppval(ppDeriv(ppy), t);
        t  = t + (ex.*dx + ey.*dy) ./ (dx.^2 + dy.^2);
        t  = min(max(t, knots(1)), knots(end));
    end

    rms = sqrt(mean(ex.^2 + ey.^2));
end


%% Lokale Funktion: Spline auswerten + Krümmung aus exakten Ableitungen
function [xs, ys, kappa] = splineCurvature(ppx, ppy, s)
    ppdx = ppDeriv(ppx);  ppddx = ppDeriv(ppdx);
    ppdy = ppDeriv(ppy);  ppddy = ppDeriv(ppdy);

    xs  = ppval(ppx, s);    ys  = ppval(ppy, s);
    dx  = ppval(ppdx, s);   dy  = ppval(ppdy, s);
    ddx = ppval(ppddx, s);  ddy = ppval(ppddy, s);

    kappa = abs(dx.*ddy - dy.*ddx) ./ (dx.^2 + dy.^2).^(1.5);
end


%% Lokale Funktion: exakte Ableitung einer stückweisen Polynomfunktion (pp-Form)
function dpp = ppDeriv(pp)
    [breaks, coefs, ~, order, dim] = unmkpp(pp);
    dcoefs = coefs(:, 1:order-1) .* (order-1:-1:1);
    dpp = mkpp(breaks, dcoefs, dim);
end
