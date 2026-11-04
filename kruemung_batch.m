% Function:
% BATCH-Version von kruemung.m:
% Krümmung eines DRAHTS für MEHRERE JPG-Bildsequenzen (SAM-2-Masken) bestimmen.
% 1. Einen Ordner wählen, der mehrere Bilderordner enthält (mit Default-Pfad).
%    Ausgewertet werden alle Unterordner mit .jpg-Bildern (alphabetisch,
%    *_sam2_masks-Ordner werden ignoriert).
% 2. Pro Bilderordner IDENTISCH zu kruemung.m: SAM-2-Maske laden,
%    skelettieren, Least-Squares-Spline, Krümmung im Fenster windowLen_mm ab der
%    Spitze, mittlere Krümmung über die Temperatur und die Aktivierungs-
%    temperaturen As / Af per 3-Segment-Regression.
% 3. Pro Bilderordner EIN Plot (Messung + 3-Segment-Fit + As/Af); FensterName
%    und Titel enthalten den Namen des Bilderordners.
% 4. Ergebnis-CSV (Spalten: Bilderordner, As, Af) im Ordner csvDir:
%       <Name des gewählten Ordners>_kruemung_AsAf.csv
%    Sie wird nach JEDEM Bilderordner neu geschrieben (bricht der Lauf ab,
%    sind die bisherigen Ergebnisse schon gespeichert). Fehlgeschlagene
%    Ordner stehen mit As = Af = NaN darin.
%
% Optional (showCurvatureSlider = true): zusätzlich pro Bilderordner die
% farbliche Krümmungsdarstellung mit Slider wie in kruemung.m (braucht mehr
% Arbeitsspeicher, da alle Bilder im Speicher bleiben).
%
% WICHTIG: vorher pro Bilderordner die SAM-2-Masken erzeugen:
%       python segment_wire_sam2.py
%   -> "Bilderordner (.jpg)" und "Mehrere Bilderordner" wählen, denselben
%      Ordner auswählen (siehe README_SAM2.md).
clear; clc; close all;

% --- Parameter Spline-Fit (IDENTISCH zu kruemung.m halten!) ---
P.knotSpacing  = 40;    % Knotenabstand der Spline [px]: größer = glatter, kleiner = detailreicher
P.nParamIter   = 3;     % Fußpunkt-Iterationen (orthogonaler Abstand Punkt <-> Spline)
P.Neval        = 200;   % Auswertepunkte entlang der Spline (Darstellung + mittlere Krümmung)
P.pxPerMm      = 46.6;  % Maßstab der Bilder [px/mm] (mit imdistline am Lineal gemessen)
P.windowLen_mm = 13.51; % ausgewertete Länge ab der Spitze [mm] = Bogenlänge der 6 Soll-Bögen
P.maxFitRMS    = 2;     % Fit-Qualität: mittlerer Abstand Skelettpixel <-> Spline darüber [px]
                        % -> Frame nicht auswertbar (NaN), normal sind ~0.3-0.5 px

showCurvatureSlider = false;   % true = zusätzlich Slider-Krümmungsdarstellung pro Ordner

% --- Ergebnis-CSV ---
csvDir = 'M:\nascas2\Projects\MemoryCI 2.0\1 Dokumentation\AP01_Iterative Inlay-Entwicklung\AP 1.B BFR-Tests\Testergebnisse\csv';

%% 1. Ordner mit mehreren Bilderordnern wählen
defaultPath = 'M:\nascas2\Projects\MemoryCI 2.0\1 Dokumentation\AP01_Iterative Inlay-Entwicklung\AP 1.B BFR-Tests\Testergebnisse\2026-06-23-MV71-11-MV71-12';
batchDir = uigetdir(defaultPath, 'Ordner mit mehreren Bilderordnern waehlen');
if isequal(batchDir, 0)
    error('No folder selected');
end

folderNames = listImageFolders(batchDir);
if isempty(folderNames)
    error(['Keine Unterordner mit .jpg-Bildern in %s gefunden.\n' ...
           'Für einen einzelnen Bilderordner kruemung.m verwenden.'], batchDir);
end
nFolders = numel(folderNames);

csvFile = makeCsvPath(csvDir, batchDir, '_kruemung_AsAf.csv');

fprintf('\n============================================================\n');
fprintf('BATCH-AUSWERTUNG Krümmung: %d Bilderordner in %s\n', nFolders, batchDir);
fprintf('Ergebnis-CSV: %s\n', csvFile);
fprintf('============================================================\n');
for i = 1:nFolders
    fprintf('  - %s\n', folderNames{i});
end

AsVec  = nan(nFolders, 1);
AfVec  = nan(nFolders, 1);
status = repmat({''}, nFolders, 1);

% EIN Live-Fenster für die Masken (wird für alle Ordner wiederverwendet)
hLive = figure('Name', 'SAM-2-Maske (live)', 'NumberTitle', 'off');

%% 2. Schleife über alle Bilderordner
for iF = 1:nFolders
    folderName = folderNames{iF};
    label = sprintf('[%d/%d] %s', iF, nFolders, folderName);
    fprintf('\n\n============================================================\n');
    fprintf('%s\n', label);
    fprintf('============================================================\n');
    try
        [AsVec(iF), AfVec(iF), msg] = processFolder( ...
            fullfile(batchDir, folderName), folderName, label, P, hLive, showCurvatureSlider);
        status{iF} = msg;
    catch ME
        status{iF} = ['FEHLER: ' ME.message];
        fprintf(2, '%s: %s\n', folderName, status{iF});
    end
    % CSV nach jedem Ordner neu schreiben (Zwischenstand bleibt erhalten)
    writeResultCsv(csvFile, folderNames, AsVec, AfVec);
end

if isvalid(hLive)
    close(hLive);
end

%% 3. Zusammenfassung
fprintf('\n============================================================\n');
fprintf('ZUSAMMENFASSUNG (%d Bilderordner)\n', nFolders);
for iF = 1:nFolders
    fprintf('  %-40s As = %8.2f °C   Af = %8.2f °C   %s\n', ...
        folderNames{iF}, AsVec(iF), AfVec(iF), status{iF});
end
fprintf('CSV gespeichert: %s\n', csvFile);
fprintf('============================================================\n');


%% Lokale Funktion: einen Bilderordner auswerten (identisch zu kruemung.m)
function [As, Af, msg] = processFolder(ImgPath, folderName, label, P, hLive, showCurvatureSlider)
    knotSpacing  = P.knotSpacing;
    nParamIter   = P.nParamIter;
    Neval        = P.Neval;
    pxPerMm      = P.pxPerMm;
    windowLen_mm = P.windowLen_mm;
    maxFitRMS    = P.maxFitRMS;
    As = NaN;  Af = NaN;

    %% 1b. SAM-2-Masken prüfen (müssen vorab mit segment_wire_sam2.py erzeugt sein)
    [parentDir, imgFolderName] = fileparts(ImgPath);
    maskDir = fullfile(parentDir, [imgFolderName '_sam2_masks']);
    if ~isfolder(maskDir)
        error(['Keine SAM-2-Masken gefunden: %s - bitte zuerst ' ...
               'segment_wire_sam2.py für diesen Ordner ausführen.'], maskDir);
    end

    %% 2. Create imageDatastore
    imds = imageDatastore(fullfile(ImgPath, '*.jpg'));
    ImageNummax = numel(imds.Files);

    % Maskenanzahl muss exakt zur Bildanzahl passen (sonst falsche Zuordnung)
    maskListing = dir(fullfile(maskDir, 'frame_*.png'));
    if numel(maskListing) ~= ImageNummax
        error(['Maskenanzahl (%d) passt nicht zur Bildanzahl (%d) in %s - ' ...
               'bitte segment_wire_sam2.py für diesen Ordner erneut ausführen.'], ...
            numel(maskListing), ImageNummax, maskDir);
    end

    % Initialize structure array
    ImageData = struct('name', [], 'path', [], 'gray', [], 'bw', []);
    ImageData(ImageNummax).name = [];

    %% 3. Initialisierung
    T = zeros(ImageNummax, 1);
    reset(imds);

    %% 4. Hauptschleife
    for n = 1:ImageNummax
        img = read(imds);

        [~, name, ~] = fileparts(imds.Files{n});   % z.B. '20250917_122541_03-5'
        parts   = strsplit(name, '_');
        tempStr = strrep(parts{end}, '-', '.');    % '03-5' -> '03.5'
        T(n)    = str2double(tempStr);

        % --- Grauwertbild + Filter ---
        if size(img,3) == 3
            grayImg = rgb2gray(img);
        else
            grayImg = img;
        end
        grayImgFiltered = medfilt2(grayImg, [3 3]);

        % --- SAM-2-Segmentierung laden (vorberechnet mit segment_wire_sam2.py) ---
        % PNG-Maske des Bildes: weiß (255) = Draht, schwarz (0) = Hintergrund.
        % Zuordnung über die Position n: imds.Files ist alphabetisch sortiert -
        % identisch zur Sortierung im Python-Skript -> frame_%05d.png passt.
        maskFile = fullfile(maskDir, sprintf('frame_%05d.png', n));
        wireFG   = imread(maskFile) > 0;   % Vordergrund-Konvention: Draht = 1

        if isvalid(hLive)
            hAxLive = gca(hLive);
            imshow(wireFG, 'Parent', hAxLive);
            title(hAxLive, sprintf('%s - Frame %d / %d', texLabel(label), n, ImageNummax));
            drawnow limitrate;
        end

        % --- Skelettierung mit Lückenschließung ---
        wireFG = bwareaopen(wireFG, 300);     % kleine Specks entfernen

        % Lücken schließen (Radius an größte Lücke anpassen, größer = mehr Brücken)
        gapCloseRadius = 1;
        wireFG_closed = imclose(wireFG, strel('disk', gapCloseRadius));

        % Default-Werte, falls der Frame unbrauchbar ist (z.B. zerrissenes Skelett)
        xs     = nan(1, Neval);
        ys     = nan(1, Neval);
        kappa  = nan(1, Neval);
        fitRMS = NaN;
        skel   = false(size(wireFG_closed));

        % Die am stärksten langgestreckte Komponente als Draht wählen
        % -> größte Hauptachsenlänge (MajorAxisLength) statt größter Fläche.
        %    Robust gegen kompakte/runde Blasen, auch wenn diese dunkler sind
        %    oder mehr Fläche haben als ein kurzes Drahtstück.
        cc = bwconncomp(wireFG_closed);
        if cc.NumObjects >= 1
            stats = regionprops(cc, 'MajorAxisLength');
            [~, imax] = max([stats.MajorAxisLength]);
            wireMain = false(size(wireFG_closed));
            wireMain(cc.PixelIdxList{imax}) = true;

            % Skelettieren
            skel = bwskel(wireMain, 'MinBranchLength', 25);

            endpts   = bwmorph(skel, 'endpoints');
            [ey, ex] = find(endpts);
            [yy, xx] = find(skel);

            if ~isempty(ex) && numel(yy) >= 2
                % Spitze = Endpunkt nächst der Bildecke unten rechts. Abgelaufen wird
                % vom ANDEREN Ende (eingespannt, am weitesten von der Ecke): so endet
                % der Weg auch dann an der Spitze, wenn sie beim Einrollen den Draht
                % berührt und kein eigenes Skelett-Ende mehr hat (Schleife).
                [H, W] = size(skel);
                distCorner = hypot(W - ex, H - ey);
                [~, iClamp] = max(distCorner);
                [xx, yy] = orderSkeletonPath(skel, ex(iClamp), ey(iClamp));
                if numel(xx) < 0.9 * nnz(skel)
                    warning('%s Frame %d: nur %d von %d Skelettpixeln abgelaufen.', folderName, n, numel(xx), nnz(skel));
                end
                [~, iTip] = min(distCorner);
                if numel(ex) >= 2 && hypot(xx(end) - ex(iTip), yy(end) - ey(iTip)) > 15
                    warning('%s Frame %d: Weg endet nicht am Ende nächst der Ecke unten rechts.', folderName, n);
                end

                % Reihenfolge umdrehen: Weg beginnt an der Spitze, Länge 0 = Spitze
                xx = flipud(xx);  yy = flipud(yy);
                d = [0; cumsum(hypot(diff(xx), diff(yy)))];   % Weglänge ab der Spitze [px]

                if numel(d) >= 4
                    % Least-Squares-Spline durch alle Skelettpixel (Parameter = Bogenlänge)
                    [ppx, ppy, fitRMS] = fitSplineLSQ(d, xx, yy, knotSpacing, nParamIter);

                    % Nur das Fenster fester Länge ab der Spitze auswerten
                    % (gleichmäßig in Bogenlänge), Krümmung analytisch
                    [xs, ys, kappa, ~, L_px] = tipWindowCurvature(ppx, ppy, ...
                        windowLen_mm * pxPerMm, Neval);
                    if isnan(kappa(1))
                        warning('%s Frame %d: sichtbare Länge %.2f mm < Fenster %.2f mm - wird mit NaN gefüllt.', ...
                            folderName, n, L_px / pxPerMm, windowLen_mm);
                    end

                    if fitRMS > maxFitRMS   % Spline passt nicht zum Skelett -> nicht auswerten
                        warning('%s Frame %d: Spline-Fit schlecht (RMS %.1f px > %.1f px) - wird mit NaN gefüllt.', ...
                            folderName, n, fitRMS, maxFitRMS);
                        xs = nan(1, Neval);  ys = nan(1, Neval);  kappa = nan(1, Neval);
                    end
                else
                    warning('%s Frame %d: zu wenige Skelettpunkte (<4) - wird mit NaN gefüllt.', folderName, n);
                end
            else
                warning('%s Frame %d: kein verwertbares Skelett - wird mit NaN gefüllt.', folderName, n);
            end
        else
            warning('%s Frame %d: kein Vordergrund gefunden - wird mit NaN gefüllt.', folderName, n);
        end


        % --- In Struktur speichern ---
        [~, name, ext] = fileparts(imds.Files{n});
        ImageData(n).name = [name, ext];
        if showCurvatureSlider
            ImageData(n).gray = grayImgFiltered;   % nur für die Slider-Darstellung nötig
        end
        ImageData(n).bw   = [];       % Maske wird im Batch nicht weiter benötigt
        ImageData(n).skel = [];
        ImageData(n).xs = xs;
        ImageData(n).ys = ys;
        ImageData(n).kappa = kappa;
        ImageData(n).mean_kappa = mean(kappa, 'omitnan');
        ImageData(n).fitRMS = fitRMS;         % RMS-Abstand Skelettpixel <-> Spline [px]
        ImageData(n).path = imds.Files{n};

    end

    [Tu, ~, ic] = unique(T(1:end-10));                          % Tu: eindeutige Temperaturen (sortiert)
    mean_kappa_vec = [ImageData.mean_kappa].';
    mean_kappa_vec = mean_kappa_vec/max(mean_kappa_vec, [], 'omitnan');
    kappaMean   = accumarray(ic, mean_kappa_vec(1:end-10), [], @(x) mean(x, 'omitnan'));
    fprintf('%s: Spline-Fit mittlerer RMS-Abstand = %.2f px (max %.2f px)\n', ...
        folderName, mean([ImageData.fitRMS], 'omitnan'), max([ImageData.fitRMS]));

    %% 4b. Aktivierungstemperaturen As / Af (stückweise-lineare 3-Segment-Regression)
    % Wie in kruemung.m: feste Randwerte c1/c2 = gemessenes Anfangs- und
    % Endniveau (Median der ersten/letzten nEdge Temperaturen), Bereich in
    % 1-°C-Schritten bis -25 °C / 90 °C aufgefüllt.
    nEdge = 3;
    validFit = isfinite(Tu) & isfinite(kappaMean);
    Tfit = Tu(validFit);
    Kfit = kappaMean(validFit) * 100;              % mittlere Krümmung [% des Maximums]

    % EIN Plot pro Bilderordner, Name/Titel = Bilderordner
    figure('Name', folderName, 'NumberTitle', 'off');
    if numel(Tfit) < 6
        warning('%s: zu wenige Temperaturen (%d) für die As/Af-Regression - übersprungen.', ...
            folderName, numel(Tfit));
        plot(Tu, kappaMean * 100, 'LineWidth', 2, 'Color', [0.8, 0.2, 0.6]);
        grid on;
        xlabel('Temperatur [°C]');
        ylabel('Mittlere Krümmung [% des Maximums]');
        title({texLabel(folderName), ...
            sprintf('As/Af-Regression übersprungen (nur %d Temperaturen)', numel(Tfit))});
        msg = 'zu wenige Temperaturen';
        return
    end

    c1 = median(Kfit(1:nEdge));                % Anfangsniveau
    c2 = median(Kfit(end-nEdge+1:end));        % Endniveau
    nLo = max(0, ceil(Tfit(1) + 25));          % Auffüllen bis -25 °C
    nHi = max(0, ceil(90 - Tfit(end)));        % Auffüllen bis 90 °C
    Tfit = [Tfit(1) - (nLo:-1:1).'; Tfit; Tfit(end) + (1:nHi).'];
    Kfit = [repmat(c1, nLo, 1); Kfit; repmat(c2, nHi, 1)];

    [paramsA, predictFcn] = fitPlateauRampPlateau(Tfit, Kfit, c1, c2);
    As = paramsA.x1;
    Af = paramsA.x2;

    plot(Tfit, Kfit, 'LineWidth', 2, 'Color', [0.8 0.2 0.6], 'LineStyle', '--', ...
        'DisplayName', 'Messung (aufgefüllt bis -25 / 90 °C)');
    hold on;
    plot(Tfit, predictFcn(Tfit), 'LineWidth', 2, 'Color', [0.2 0.8 0.6], ...
        'DisplayName', '3-Segment-Fit');
    xline(As, ':k', sprintf('A_s = %.1f °C', As), 'HandleVisibility', 'off');
    xline(Af, ':k', sprintf('A_f = %.1f °C', Af), 'HandleVisibility', 'off');
    hold off;
    grid on;
    xlabel('Temperatur [°C]');
    ylabel(sprintf('Mittlere Krümmung [%% des Maximums] (%.2f mm ab Spitze)', windowLen_mm));
    title({texLabel(folderName), ...
        sprintf('A_s = %.1f °C, A_f = %.1f °C (R^2 = %.3f)', As, Af, paramsA.r2)});
    legend('Location', 'best');
    drawnow;

    fprintf('%s: As = %.4f\n', folderName, As);
    fprintf('%s: Af = %.4f\n', folderName, Af);
    fprintf('%s: 3-Segment-Fit R^2 = %.4f, Randwerte %.1f %% / %.1f %%\n', ...
        folderName, paramsA.r2, c1, c2);
    msg = sprintf('OK (R^2 = %.3f)', paramsA.r2);

    %% 5. Optional: farbliche Krümmungsdarstellung (mit Slider) wie kruemung.m
    if showCurvatureSlider
        showSliderFigure(ImageData, folderName);
    end
end


%% Lokale Funktion: Slider-Fenster der Krümmungsdarstellung (wie kruemung.m Abschnitt 5)
function showSliderFigure(ImageData, folderName)
    ImageNummax = numel(ImageData);
    cmap = jet(256);
    allKappa = [ImageData.kappa];
    kMin = min(allKappa);            % min/max ignorieren NaN automatisch
    kMax = max(allKappa);
    if isempty(kMin) || ~isfinite(kMin) || ~(kMax > kMin)   % z.B. alle Frames NaN
        kMin = 0;
        kMax = max([kMax, 1e-6], [], 'omitnan');
    end

    hFig = figure('Name', ['Krümmungsdarstellung: ' folderName], 'NumberTitle', 'off');
    hAx  = axes('Parent', hFig, 'Position', [0.05 0.15 0.9 0.80]);

    if ImageNummax > 1
        smallStep = 1/(ImageNummax-1);
        sliderStep = [smallStep, max(smallStep, 10/(ImageNummax-1))];
    else
        sliderStep = [1 1];
    end
    hSlider = uicontrol('Parent', hFig, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.15 0.03 0.7 0.05], ...
        'Min', 1, 'Max', max(ImageNummax,2), 'Value', 1, ...
        'SliderStep', sliderStep);
    addlistener(hSlider, 'Value', 'PostSet', ...
        @(src, evt) drawFrame(hAx, ImageData, round(hSlider.Value), cmap, kMin, kMax, folderName));
    drawFrame(hAx, ImageData, 1, cmap, kMin, kMax, folderName);
end


%% Lokale Funktion: ein Frame mit farbiger Krümmung zeichnen
function drawFrame(hAx, ImageData, n, cmap, kMin, kMax, folderName)
    n = min(max(round(n), 1), numel(ImageData));

    % Graustufenbild als RGB anzeigen: sonst würde es über die jet-Colormap
    % und CLim der Krümmungsdarstellung eingefärbt (ganzes Bild blau)
    imshow(repmat(ImageData(n).gray, [1 1 3]), 'Parent', hAx);
    hold(hAx, 'on');

    % Spline als eine Linie mit Farbverlauf nach Krümmung (patch-Trick:
    % NaN am Ende verhindert das Schließen der Fläche)
    patch(hAx, [ImageData(n).xs NaN], [ImageData(n).ys NaN], [ImageData(n).kappa NaN], ...
        'EdgeColor', 'interp', 'FaceColor', 'none', 'LineWidth', 3);
    colormap(hAx, cmap);
    set(hAx, 'CLim', [kMin kMax]);

    title(hAx, sprintf('%s: Spline über Originalbild (Frame %d / %d)', ...
        texLabel(folderName), n, numel(ImageData)));
    hold(hAx, 'off');
end


%% Lokale Funktion: Unterordner mit .jpg-Bildern auflisten (alphabetisch)
function names = listImageFolders(batchDir)
    d = dir(batchDir);
    d = d([d.isdir]);
    names = {};
    for i = 1:numel(d)
        nm = d(i).name;
        if any(strcmp(nm, {'.', '..'})) || endsWith(nm, '_sam2_masks')
            continue
        end
        if ~isempty(dir(fullfile(batchDir, nm, '*.jpg')))
            names{end+1, 1} = nm; %#ok<AGROW>
        end
    end
    names = sort(names);
end


%% Lokale Funktion: Pfad der Ergebnis-CSV (Ordner bei Bedarf anlegen)
% Dateiname = Name des gewählten Ordners + suffix. Ist csvDir nicht
% erreichbar (z.B. Laufwerk M: nicht verbunden), wird die CSV stattdessen im
% gewählten Ordner gespeichert.
function csvFile = makeCsvPath(csvDir, batchDir, suffix)
    [~, batchName] = fileparts(regexprep(batchDir, '[\\/]+$', ''));
    if isempty(batchName)
        batchName = 'batch';
    end
    if ~isfolder(csvDir)
        [ok, ~] = mkdir(csvDir);
        if ~ok
            warning('CSV-Ordner nicht erreichbar: %s\nCSV wird stattdessen in %s gespeichert.', ...
                csvDir, batchDir);
            csvDir = batchDir;
        end
    end
    csvFile = fullfile(csvDir, [batchName suffix]);
end


%% Lokale Funktion: Ergebnis-CSV schreiben (Bilderordner, As, Af)
function writeResultCsv(csvFile, folderNames, AsVec, AfVec)
    resultTable = table(folderNames(:), AsVec(:), AfVec(:), ...
        'VariableNames', {'Bilderordner', 'As', 'Af'});
    try
        writetable(resultTable, csvFile);
    catch ME
        warning('CSV konnte nicht geschrieben werden (%s): %s', csvFile, ME.message);
    end
end


%% Lokale Funktion: Text für TeX-Titel escapen (z.B. '_' in Ordnernamen)
function s = texLabel(s)
    s = regexprep(s, '([\\_^{}])', '\\$1');
end


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


%% Lokale Funktion: Skelett ab (x0,y0) Pixel für Pixel in Drahtreihenfolge ablaufen
% Liefert die Skelettpixel in der Reihenfolge entlang des Drahts. An
% Verzweigungen wird jeder mögliche Weg probeweise abgelaufen und der
% LÄNGSTE gewählt (Seitenäste z.B. an Luftblasen sind Sackgassen); bei
% gleicher Länge (z.B. Schleife, wenn die Spitze den Draht berührt) die
% geradeste Fortsetzung der letzten ~8 Pixel. Ersetzt das Sortieren aller
% Skelettpixel nach geodätischer Distanz: das mischt bei einer Schleife beide
% Seiten (Punktsprünge bis ~200 px) und lässt die Krümmung explodieren.
function [xp, yp] = orderSkeletonPath(skel, x0, y0)
    [xp, yp] = walkSkeleton(skel, false(size(skel)), x0, y0, true);
end

function [xp, yp] = walkSkeleton(skel, visited, x, y, lookahead)
    [H, W] = size(skel);
    nMax = nnz(skel);
    xp = zeros(nMax, 1);
    yp = zeros(nMax, 1);
    k = 0;
    while true
        k = k + 1;
        xp(k) = x;  yp(k) = y;
        visited(y, x) = true;

        % unbesuchte 8-Nachbarn im Skelett
        cand = zeros(0, 2);
        for dy = -1:1
            for dx = -1:1
                xn = x + dx;  yn = y + dy;
                if (dx ~= 0 || dy ~= 0) && xn >= 1 && xn <= W && yn >= 1 && yn <= H ...
                        && skel(yn, xn) && ~visited(yn, xn)
                    cand(end+1, :) = [xn yn]; %#ok<AGROW>
                end
            end
        end
        if isempty(cand) || k == nMax
            break
        end

        if size(cand, 1) > 1
            % Geradheit: Fortsetzung der Richtung der letzten ~8 Pixel
            j = max(1, k - 8);
            dirv = [x - xp(j), y - yp(j)];
            if all(dirv == 0)
                dirv = cand(1, :) - [x y];
            end
            step  = cand - [x y];
            score = (step * dirv.') ./ sqrt(sum(step.^2, 2));   % cos(Winkel), -1..1
            if lookahead
                % jeden Weg probeweise ablaufen (andere Kandidaten gesperrt)
                len = zeros(size(cand, 1), 1);
                for c = 1:size(cand, 1)
                    vis = visited;
                    others = setdiff(1:size(cand, 1), c);
                    vis(sub2ind([H W], cand(others, 2), cand(others, 1))) = true;
                    len(c) = numel(walkSkeleton(skel, vis, cand(c, 1), cand(c, 2), false));
                end
                [~, iBest] = max(len + 0.1 * score);   % längster Weg, bei Gleichstand geradester
            else
                [~, iBest] = max(score);
            end
        else
            iBest = 1;
        end
        x = cand(iBest, 1);  y = cand(iBest, 2);
    end
    xp = xp(1:k);
    yp = yp(1:k);
end


%% Lokale Funktion: Krümmung in einem Fenster fester Länge ab der Spitze
% Die Spitze ist der Anfang der Spline (t = breaks(1)), weil die Bogenlänge ab
% dem Skelett-Endpunkt nächst der Ecke unten rechts gezählt wird. Die Länge wird
% ENTLANG DER GLATTEN SPLINE gemessen (nicht über die Pixelkette, die bei
% schrägem Draht durch die Treppe länger ist).
% Rückgabe an Neval Punkten, gleichmäßig in Bogenlänge: Position, Krümmung [1/px],
% Abstand von der Spitze sTip [px] und sichtbare Spline-Länge L [px].
% Ist der sichtbare Draht kürzer als winLen, sind xs/ys/kappa NaN.
function [xs, ys, kappa, sTip, L] = tipWindowCurvature(ppx, ppy, winLen, Neval)
    tDense = linspace(ppx.breaks(1), ppx.breaks(end), 2000);
    arc = [0, cumsum(hypot(diff(ppval(ppx, tDense)), diff(ppval(ppy, tDense))))];
    L = arc(end);
    sTip = linspace(0, winLen, Neval);   % Abstand von der Spitze [px]

    if L < winLen
        xs = nan(1, Neval);  ys = nan(1, Neval);  kappa = nan(1, Neval);
        return
    end

    [arc, iu] = unique(arc);             % streng monoton für interp1
    t = interp1(arc, tDense(iu), sTip);       % Kurvenparameter der Auswertepunkte
    [xs, ys, kappa] = splineCurvature(ppx, ppy, t);
end


%% Lokale Funktion: stueckweise-lineare 3-Segment-Regression
function [params, predictFcn] = fitPlateauRampPlateau(x, y, c1, c2)
%FITPLATEAURAMPPLATEAU  Stueckweise-lineare 3-Segment-Regression mit festen Randwerten.
%   Fittet eine STETIGE, stueckweise lineare Funktion mit DREI linearen
%   Segmenten an die Daten (x,y). Alle drei Segmente duerfen eine Steigung
%   haben; festgehalten werden nur die Randwerte: f(xmin) = c1 und
%   f(xmax) = c2 (Default: c1 = 0, c2 = 100).
%
%   Das Modell verlaeuft linear durch die Stuetzpunkte
%       (xmin, c1) - (x1, y1) - (x2, y2) - (xmax, c2)
%   mit den Knickstellen x1 < x2 und den freien Knickwerten y1, y2.
%   Bei festen Knickstellen sind y1, y2 per linearer Ausgleichsrechnung
%   exakt loesbar; optimiert werden daher nur die Knickstellen x1 < x2.
%
%   [params, predictFcn] = fitPlateauRampPlateau(x, y)        % c1=0, c2=100
%   [params, predictFcn] = fitPlateauRampPlateau(x, y, c1, c2)
%     params     : struct mit c1, c2, x1, x2, y1, y2, m1, m2, m3, sse, r2
%     predictFcn : Function-Handle, predictFcn(xq) -> Modellwerte

    if nargin < 3 || isempty(c1), c1 = 0;   end
    if nargin < 4 || isempty(c2), c2 = 100; end

    x = x(:);  y = y(:);
    xmin = min(x);  xmax = max(x);

    % --- 1) Grobe globale Suche ueber die Knickstellen (Grid) -----------
    % Fuer feste (x1,x2) werden die optimalen Knickwerte (y1,y2) intern per
    % linearer Ausgleichsrechnung bestimmt -> SSE direkt minimal bewertet.
    ng   = 80;
    cand = linspace(xmin, xmax, ng);
    bestSSE = inf;  bx1 = cand(2);  bx2 = cand(end-1);
    for i = 2:ng-1
        for j = i+1:ng-1                      % erzwingt xmin < x1 < x2 < xmax
            sse = sseFixed(x, y, cand(i), cand(j), xmin, xmax, c1, c2);
            if sse < bestSSE
                bestSSE = sse;  bx1 = cand(i);  bx2 = cand(j);
            end
        end
    end

    % --- 2) Lokale Verfeinerung (Reparam. x1, w = x2-x1 > 0) ------------
    obj  = @(p) objective(p, x, y, xmin, xmax, c1, c2);
    p0   = [bx1, bx2 - bx1];
    opts = optimset('TolX',1e-9, 'TolFun',1e-11, ...
                    'MaxFunEvals',4000, 'MaxIter',4000);
    popt = fminsearch(obj, p0, opts);
    x1 = popt(1);  x2 = popt(1) + popt(2);

    % --- 3) Optimale Knickwerte und abgeleitete Groessen ---------------
    [sse, y1, y2] = sseFixed(x, y, x1, x2, xmin, xmax, c1, c2);
    m1  = (y1 - c1) / (x1 - xmin);   % Steigung Segment 1
    m2  = (y2 - y1) / (x2 - x1);     % Steigung Segment 2 (Rampe)
    m3  = (c2 - y2) / (xmax - x2);   % Steigung Segment 3
    sst = sum((y - mean(y)).^2);
    r2  = 1 - sse/sst;

    params = struct('c1',c1, 'c2',c2, 'x1',x1, 'x2',x2, ...
                    'y1',y1, 'y2',y2, 'm1',m1, 'm2',m2, 'm3',m3, ...
                    'sse',sse, 'r2',r2);

    predictFcn = @(xq) modelEval(xq, xmin, xmax, x1, x2, c1, c2, y1, y2);
end

% ----------------------------------------------------------------------
function yhat = modelEval(x, xmin, xmax, x1, x2, c1, c2, y1, y2)
% Modellauswertung: lineare Interpolation durch die vier Stuetzpunkte.
    x  = x(:);
    xk = [xmin, x1, x2, xmax];
    yk = [c1,   y1, y2, c2  ];
    yhat = interp1(xk, yk, x, 'linear', 'extrap');
end

function [sse, y1, y2] = sseFixed(x, y, x1, x2, xmin, xmax, c1, c2)
% Optimale Knickwerte y1,y2 (lineare Ausgleichsrechnung) bei festen
% Knickstellen und festen Randwerten c1,c2 sowie zugehoeriger SSE.
    xk   = [xmin, x1, x2, xmax];
    b    = interp1(xk, [0 1 0 0], x, 'linear', 'extrap');   % Basisfkt. fuer y1
    d    = interp1(xk, [0 0 1 0], x, 'linear', 'extrap');   % Basisfkt. fuer y2
    base = interp1(xk, [c1 0 0 c2], x, 'linear', 'extrap'); % fester Randanteil
    A    = [b, d];
    yk   = A \ (y - base);            % LS-Loesung [y1; y2]
    y1   = yk(1);  y2 = yk(2);
    resid = y - (base + A*yk);
    sse   = resid.' * resid;
end

function val = objective(p, x, y, xmin, xmax, c1, c2)
% Zielfunktion fuer fminsearch: SSE ueber (x1, w), mit Penalty ausserhalb.
    x1 = p(1);  w = p(2);
    x2 = x1 + w;
    eps0 = 1e-6 * (xmax - xmin);
    if w <= eps0 || x1 <= xmin + eps0 || x2 >= xmax - eps0
        val = 1e12;  return;          % ungueltiger Bereich
    end
    val = sseFixed(x, y, x1, x2, xmin, xmax, c1, c2);
end
