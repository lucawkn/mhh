% Function:
% Krümmung eines DRAHTS aus einem .avi-Video bestimmen (SAM-2-Segmentierung).
% 1. Ein .avi-Video auswählen (mit Default-Pfad)
% 2. Pro Frame die vorberechnete SAM-2-Maske laden, skelettieren und die
%    Krümmung entlang der Mittellinie berechnen:
%    ALLE Skelettpixel (nach Bogenlänge sortiert) werden mit einer kubischen
%    Least-Squares-Spline approximiert (Abstand Punkte <-> Spline minimal),
%    die Krümmung wird dann ANALYTISCH aus den Spline-Ableitungen berechnet
%    (kein Rauschen durch numerisches Differenzieren der Pixelpunkte).
%    Ausgewertet wird nur ein Fenster FESTER LÄNGE (windowLen_mm) ab der
%    Spitze (freies, gekrümmtes Ende) -> Mittelwerte unabhängig davon, wie
%    viel vom Draht sichtbar ist. Zu kurze Frames -> NaN.
% 3. Ausreißerframes (Fehlsegmentierung) durch ihre Nachbarn ersetzen und die
%    mittlere Krümmung über die Zeit plotten (absolut in 1/mm, mit der
%    mittleren Krümmung der Sollform über dasselbe Fenster als Referenzlinie)
%    Zusätzlich Ausschnitt nur für den wichtigen Zeitbereich (zoomTime_s)
% 4. 3D-Plot: Krümmung über Abstand von der Spitze (mm) und Zeit
% 5. Farbliche Krümmungsdarstellung über dem Originalbild (mit Slider)
%
% WICHTIG - zweistufiger Workflow (die HSV-Maske aus kruemung_hai.m schlägt
% bei diesen Videos fehl, daher Segmentierung mit Segment Anything Model 2):
%   Schritt 1 (einmal pro Video, Python):
%       python segment_wire_sam2.py
%     -> segmentiert den Draht mit SAM 2 (Meta) und speichert die Masken als
%        <videoname>_sam2_masks\frame_00001.png, ... neben dem Video.
%        Einrichtung/Details: siehe README_SAM2.md
%   Schritt 2: dieses Skript ausführen (lädt die PNGs statt createMask).
clear; clc; close all;

pxPerMm    = 19.7;     % Kalibrierung des Videos [px/mm]
                       % (z.B. mit imdistline eine bekannte Länge im Frame messen)

% --- Auswertefenster ab der Spitze ---
windowLen_mm = 13.51;  % ausgewertete Länge ab der Spitze [mm] = Bogenlänge der 6 Soll-Bögen
                       % (siehe Längenausgabe in inlayGeometry_v2.m; wie windowLen_mm in v16)
kappaInlay = inlayWindowKappa(windowLen_mm);   % mittlere Krümmung der Sollform über dasselbe
                                               % Fenster [1/mm] -> Referenzlinie im Plot

% --- Parameter Spline-Fit ---
knotSpacing = 40;    % Knotenabstand der Spline [px]: größer = glatter, kleiner = detailreicher
nParamIter  = 3;     % Fußpunkt-Iterationen (0 = Punkte nur über Bogenlänge zuordnen,
                     % >0 = echter orthogonaler Abstand Punkt <-> Spline wird minimiert)
Neval       = 200;   % Auswertepunkte entlang der Spline (Darstellung + mittlere Krümmung)

% --- Zeitausschnitt für den Detail-Plot ---
zoomTime_s = [1.5 2.0];   % besonders wichtiger Zeitbereich [s] (Beginn, Ende)

% --- Ausreißerframes durch Nachbarn ersetzen (IDENTISCH zu kruemung_jinhan_v2_luca_batch.m) ---
outlierWin     = 3;     % Nachbarn je Seite [Frames] (erkennt bis zu 3 Fehlframes am Stück)
outlierNSigma  = 4;     % Schwelle in robusten Standardabweichungen der Nachbarn
outlierMinJump = 0.15;  % Mindestabweichung vom Nachbar-Median [1/mm] (wie v16 absArtifactJump)
kappaPhysMax   = 2;     % mittlere Krümmung darüber = immer Ausreißer [1/mm] (Radius < 0.5 mm)

%% 1. Video auswählen (mit Default-Pfad)
defaultPath = 'M:\nascas2\Projects\MemoryCI 2.0\1 Dokumentation\AP04_Aktivierungsparameter\3. Kurzimpulsaktivierung\Aktivierungsprogramm_v5\Testergebnisse';
[vidFile, vidDir] = uigetfile({'*.avi','AVI Video (*.avi)'; '*.*','Alle Dateien (*.*)'}, ...
    'Select AVI video', defaultPath);
if isequal(vidFile, 0)
    error('No video selected');
end
videoFullPath = fullfile(vidDir, vidFile);
[~, vidName, ~] = fileparts(vidFile);

%% 1b. SAM-2-Masken prüfen (müssen vorab mit segment_wire_sam2.py erzeugt sein)
maskDir = fullfile(vidDir, [vidName '_sam2_masks']);
if ~isfolder(maskDir)
    error(['Keine SAM-2-Masken gefunden: %s\n' ...
           'Bitte zuerst das Python-Skript ausführen:\n' ...
           '    python segment_wire_sam2.py\n' ...
           'und dieses Video auswählen (siehe README_SAM2.md).'], maskDir);
end

%% 2. Video öffnen
v = VideoReader(videoFullPath);
ImageNummax = v.NumFrames;
frameRate   = v.FrameRate;                       % Bilder pro Sekunde
tVec        = (0:ImageNummax-1).' / frameRate;   % Zeit je Frame [s]

% Maskenanzahl muss exakt zur Frameanzahl passen (sonst falsche Zuordnung)
maskListing = dir(fullfile(maskDir, 'frame_*.png'));
if numel(maskListing) ~= ImageNummax
    error(['Maskenanzahl (%d) passt nicht zur Frameanzahl (%d) in %s.\n' ...
           'Bitte segment_wire_sam2.py für dieses Video erneut ausführen.'], ...
        numel(maskListing), ImageNummax, maskDir);
end

%% 2b. Masken während der Auswertung anzeigen? (kostet Zeit, nur zur Kontrolle)
answer = questdlg('Schwarz/Weiß-Maske jedes Frames anzeigen (Kontrolle der Segmentierung)?', ...
    'Maskenkontrolle', 'Anzeigen', 'Nicht anzeigen', 'Nicht anzeigen');
showMasks = strcmp(answer, 'Anzeigen');   % Fenster geschlossen -> nicht anzeigen

% Initialize structure array
ImageData = struct('name', [], 'path', [], 'rgb', [], 'bw', []);
ImageData(ImageNummax).name = [];

prevStart = [];   % Startpunkt (Länge = 0) des vorherigen Frames [x y]

%% 3. Hauptschleife über alle Frames
for n = 1:ImageNummax
    img = read(v, n);

    % --- RGB sicherstellen ---
    if size(img,3) == 3
        rgbImg = img;
    else
        rgbImg = repmat(img, [1 1 3]);
    end

    % --- SAM-2-Segmentierung laden (vorberechnet mit segment_wire_sam2.py) ---
    % PNG-Maske des Frames: weiß (255) = Draht, schwarz (0) = Hintergrund.
    maskFile = fullfile(maskDir, sprintf('frame_%05d.png', n));
    tubeFG   = imread(maskFile) > 0;   % true = Draht

    % --- Nur die größte zusammenhängende Fläche behalten (weiß), Rest schwarz ---
    bwLargest = false(size(tubeFG));
    ccDisp = bwconncomp(tubeFG);
    if ccDisp.NumObjects >= 1
        areas = cellfun(@numel, ccDisp.PixelIdxList);
        [~, iBig] = max(areas);
        bwLargest(ccDisp.PixelIdxList{iBig}) = true;
    end
    tubeFG = bwLargest;

    if showMasks
        figure(1)
        imshow(tubeFG);
        title(sprintf('Maske Frame %d / %d', n, ImageNummax));
        drawnow;
    end

    % --- Skelettierung mit Lückenschließung ---

    tubeFG = bwareaopen(tubeFG, 300);     % kleine Specks entfernen

    % Lücken schließen (Radius an größte Lücke anpassen, größer = mehr Brücken)
    gapCloseRadius = 1;
    tubeFG_closed = imclose(tubeFG, strel('disk', gapCloseRadius));

    % Default-Werte, falls der Frame unbrauchbar ist (z.B. zerrissenes Skelett)
    xs     = nan(1, Neval);
    ys     = nan(1, Neval);
    kappa  = nan(1, Neval);
    s      = nan(1, Neval);
    fitRMS = NaN;
    skel   = false(size(tubeFG_closed));

    % Die am stärksten langgestreckte Komponente als Schlauch wählen
    % -> größte Hauptachsenlänge (MajorAxisLength) statt größter Fläche.
    %    Robust gegen kompakte/runde Blasen, auch wenn diese dunkler sind
    %    oder mehr Fläche haben als ein kurzes Schlauchstück.
    cc = bwconncomp(tubeFG_closed);
    if cc.NumObjects >= 1
        stats = regionprops(cc, 'MajorAxisLength');
        [~, imax] = max([stats.MajorAxisLength]);
        tubeMain = false(size(tubeFG_closed));
        tubeMain(cc.PixelIdxList{imax}) = true;

        % Skelettieren
        skel = bwskel(tubeMain, 'MinBranchLength', 25);

        endpts   = bwmorph(skel, 'endpoints');
        [ey, ex] = find(endpts);
        [yy, xx] = find(skel);

        if ~isempty(ex) && numel(yy) >= 2
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

            D = bwdistgeodesic(skel, x0, y0, 'quasi-euclidean');
            d = D(sub2ind(size(skel), yy, xx));

            valid = isfinite(d);          % unerreichbare Pixel rausfiltern
            d  = d(valid);
            xx = xx(valid);
            yy = yy(valid);

            % unique sortiert aufsteigend UND entfernt doppelte Distanzen
            [d, iu] = unique(d);
            xx = xx(iu);
            yy = yy(iu);

            if numel(d) >= 4
                % Least-Squares-Spline durch alle Skelettpixel (Parameter = Bogenlänge)
                [ppx, ppy, fitRMS] = fitSplineLSQ(d, xx, yy, knotSpacing, nParamIter);

                % Nur das Fenster fester Länge ab der Spitze auswerten
                % (gleichmäßig in Bogenlänge), Krümmung analytisch
                [xs, ys, kappa, s, L_px] = tipWindowCurvature(ppx, ppy, ...
                    windowLen_mm * pxPerMm, Neval);
                if isnan(kappa(1))
                    s = nan(1, Neval);
                    warning('Frame %d: sichtbare Länge %.2f mm < Fenster %.2f mm - wird mit NaN gefüllt.', ...
                        n, L_px / pxPerMm, windowLen_mm);
                end
            else
                warning('Frame %d: zu wenige Skelettpunkte (<4) - wird mit NaN gefüllt.', n);
            end
        else
            warning('Frame %d: kein verwertbares Skelett - wird mit NaN gefüllt.', n);
        end
    else
        warning('Frame %d: kein Vordergrund gefunden - wird mit NaN gefüllt.', n);
    end

    % --- In Struktur speichern ---
    ImageData(n).name = sprintf('%s_frame%04d', vidName, n);
    ImageData(n).rgb  = rgbImg;
    ImageData(n).bw   = tubeFG;
    ImageData(n).skel = skel;
    ImageData(n).xs = xs;
    ImageData(n).ys = ys;
    ImageData(n).kappa = kappa;
    ImageData(n).s = s;                   % Abstand von der Spitze [px] (Fenster)
    ImageData(n).mean_kappa = mean(kappa, 'omitnan');
    ImageData(n).fitRMS = fitRMS;         % RMS-Abstand Skelettpixel <-> Spline [px]
    ImageData(n).path = videoFullPath;

end

%% 4. Mittlere Krümmung über die Zeit (absolut in 1/mm)
if pxPerMm == 1
    warning('pxPerMm = 1: Krümmung wird in 1/px statt 1/mm angezeigt - Kalibrierwert eintragen!');
end
mean_kappa_raw_mm = [ImageData.mean_kappa].' * pxPerMm;   % 1/px -> 1/mm

% Ausreißerframes (Fehlsegmentierung) durch ihre Nachbarn ersetzen
[mean_kappa_mm, isOutlier] = replaceOutlierFrames(mean_kappa_raw_mm, tVec, ...
    outlierWin, outlierNSigma, outlierMinJump, kappaPhysMax);
for n = 1:ImageNummax
    ImageData(n).isOutlier = isOutlier(n);
end
if any(isOutlier)
    fprintf('Ersetzte Ausreisserframes: %d\n', nnz(isOutlier));
    for i = find(isOutlier).'
        fprintf('  Frame %4d: %10.4f -> %.4f 1/mm\n', i, mean_kappa_raw_mm(i), mean_kappa_mm(i));
    end
else
    fprintf('Keine Ausreisserframes erkannt.\n');
end

iLast = find(isfinite(mean_kappa_mm), 1, 'last');   % letzter gültiger Frame
if isempty(iLast), iLast = ImageNummax; end         % kein Frame auswertbar -> NaN-Ausgabe
figure(2)
plot(tVec, mean_kappa_mm, 'LineWidth', 2, 'Color', [0.8, 0.2, 0.6]);
yline(kappaInlay, '--k', 'Inlay (Ziel)');
xlabel('Zeit [s]');
ylabel('Mittlere Krümmung [1/mm]');
title(sprintf('Mittlere Krümmung über die Zeit (%.2f mm ab Spitze)', windowLen_mm));
fprintf('max_kappa = %.4f 1/mm (Radius %.2f mm)\n', max(mean_kappa_mm), 1/max(mean_kappa_mm));
fprintf('end_kappa = %.4f 1/mm (Radius %.2f mm)\n', mean_kappa_mm(iLast), 1/mean_kappa_mm(iLast));
fprintf('Inlay     = %.4f 1/mm (Radius %.2f mm), Sollform über %.2f mm ab Spitze\n', ...
    kappaInlay, 1/kappaInlay, windowLen_mm);
fprintf('Spline-Fit: mittlerer RMS-Abstand = %.2f px (max %.2f px)\n', ...
    mean([ImageData.fitRMS], 'omitnan'), max([ImageData.fitRMS]));

%% 4a. Detail-Plot: mittlere Krümmung nur im Zeitbereich zoomTime_s
inZoom = tVec >= zoomTime_s(1) & tVec <= zoomTime_s(2);
if ~any(inZoom)
    warning('Keine Frames zwischen %.2f s und %.2f s - Detail-Plot wird übersprungen.', ...
        zoomTime_s(1), zoomTime_s(2));
else
    figure(4)
    plot(tVec(inZoom), mean_kappa_mm(inZoom), 'o-', 'LineWidth', 2, ...
        'Color', [0.8, 0.2, 0.6], 'MarkerFaceColor', [0.8, 0.2, 0.6], 'DisplayName', 'mittlere Krümmung');
    hold on;
    zoomOut = inZoom & isOutlier;            % ersetzte Ausreißerframes kennzeichnen
    if any(zoomOut)
        plot(tVec(zoomOut), mean_kappa_mm(zoomOut), 'kx', 'MarkerSize', 10, 'LineWidth', 2, ...
            'DisplayName', 'Ausreißer (ersetzt)');
    end
    yline(kappaInlay, '--k', 'Inlay (Ziel)', 'HandleVisibility', 'off');
    hold off;
    xlim(zoomTime_s);
    grid on;
    xlabel('Zeit [s]');
    ylabel('Mittlere Krümmung [1/mm]');
    title(sprintf('Mittlere Krümmung %.2f - %.2f s (%.2f mm ab Spitze)', ...
        zoomTime_s(1), zoomTime_s(2), windowLen_mm));
    legend('Location', 'best');

    [kZoomMax, iZoomMax] = max(mean_kappa_mm(inZoom), [], 'omitnan');
    tZoom = tVec(inZoom);
    fprintf('Zeitbereich %.2f-%.2f s: %d Frames, max %.4f 1/mm bei t = %.3f s\n', ...
        zoomTime_s(1), zoomTime_s(2), nnz(inZoom), kZoomMax, tZoom(iZoomMax));
end

%% 4b. Krümmung über Länge und Zeit (3D)
sEnd = arrayfun(@(D) max(D.s), ImageData);   % Länge je Frame [px], NaN = ungültig
sEnd(isOutlier) = NaN;                        % Ausreißerframes = Lücke im 3D-Plot
if nnz(~isnan(sEnd)) < 2
    warning('Weniger als 2 gültige Frames - 3D-Plot wird übersprungen.');
else
    % Gemeinsame Längsachse [mm]; kürzere Frames bekommen am Ende NaN (Lücke)
    sGrid = linspace(0, max(sEnd) / pxPerMm, Neval);
    K = nan(Neval, ImageNummax);              % Krümmung [1/mm]: Zeile = Länge, Spalte = Frame
    for n = find(~isnan(sEnd))
        K(:, n) = interp1(ImageData(n).s / pxPerMm, ImageData(n).kappa * pxPerMm, ...
            sGrid, 'linear', NaN).';
    end

    figure(3)
    surf(tVec, sGrid, K);
    shading interp;
    colormap(jet);
    colorbar;
    xlabel('Zeit [s]');
    ylabel('Abstand von der Spitze [mm]');
    zlabel('Krümmung [1/mm]');
    title('Krümmung über Länge und Zeit (von oben: view(2) = Heatmap)');
    view(3);
end


%% 5. Farbliche Krümmungsdarstellung über dem Originalbild (mit Slider)
cmap = jet(256);
allKappa = [ImageData(~isOutlier).kappa];   % Farbskala ohne Ausreißerframes
kMin = min(allKappa);            % min/max ignorieren NaN automatisch
kMax = max(allKappa);
if isempty(kMin) || ~isfinite(kMin) || ~(kMax > kMin)   % z.B. alle Frames NaN
    kMin = 0;
    kMax = max([kMax, 1e-6], [], 'omitnan');
end

hFig = figure('Name', 'Krümmungsdarstellung', 'NumberTitle', 'off');
hAx  = axes('Parent', hFig, 'Position', [0.05 0.15 0.9 0.80]);

% Slider zum Vor- und Zurückspulen durch die Frames
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

% Live-Aktualisierung beim Ziehen des Sliders
addlistener(hSlider, 'Value', 'PostSet', ...
    @(src, evt) drawFrame(hAx, ImageData, round(hSlider.Value), cmap, kMin, kMax));

% Erstes Bild anzeigen
drawFrame(hAx, ImageData, 1, cmap, kMin, kMax);


%% Lokale Funktion: ein Frame mit farbiger Krümmung zeichnen
function drawFrame(hAx, ImageData, n, cmap, kMin, kMax)
    n = min(max(round(n), 1), numel(ImageData));

    imshow(ImageData(n).rgb, 'Parent', hAx);
    hold(hAx, 'on');

    if ImageData(n).isOutlier
        % Ausreißerframe: Spline ausblenden
        title(hAx, sprintf('Frame %d / %d: Ausreißer - ausgeblendet', n, numel(ImageData)));
    else
        % Spline als eine Linie mit Farbverlauf nach Krümmung (patch-Trick:
        % NaN am Ende verhindert das Schließen der Fläche)
        patch(hAx, [ImageData(n).xs NaN], [ImageData(n).ys NaN], [ImageData(n).kappa NaN], ...
            'EdgeColor', 'interp', 'FaceColor', 'none', 'LineWidth', 3);
        colormap(hAx, cmap);
        set(hAx, 'CLim', [kMin kMax]);
        title(hAx, sprintf('Spline über Originalbild (Frame %d / %d)', n, numel(ImageData)));
    end
    hold(hAx, 'off');
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


%% Lokale Funktion: Ausreißerframes erkennen und durch Nachbarn ersetzen
% k = mittlere Krümmung je Frame [1/mm], tVec = Zeit je Frame [s].
% Ausreißer, wenn
%   (a) k > kappaPhysMax (physikalisch unmöglich) ODER
%   (b) |k - Median der Nachbarn| > max(minJump, nSigma * 1.4826 * MAD der Nachbarn)
%       (Nachbarn = gültige Frames in +-win, ohne den Frame selbst und ohne
%        bereits markierte Ausreißer; bis zu 3 Durchläufe).
% Echte schnelle Änderungen (Sprünge) bleiben erhalten, weil die Streuung der
% Nachbarn dann groß ist. Ersetzt wird durch lineare Interpolation zwischen dem
% nächsten gültigen Frame davor und danach (am Rand: nächster gültiger Wert).
function [kClean, isOut] = replaceOutlierFrames(k, tVec, win, nSigma, minJump, kappaPhysMax)
    k = k(:);  tVec = tVec(:);
    kClean = k;
    isOut  = isfinite(k) & k > kappaPhysMax;

    for pass = 1:3
        newOut = false(size(k));
        for i = find(isfinite(k) & ~isOut).'
            nb = [max(1, i-win):i-1, i+1:min(numel(k), i+win)];
            nb = nb(isfinite(k(nb)) & ~isOut(nb));
            if numel(nb) < 2
                continue
            end
            med = median(k(nb));
            sig = 1.4826 * median(abs(k(nb) - med));
            if abs(k(i) - med) > max(minJump, nSigma * sig)
                newOut(i) = true;
            end
        end
        if ~any(newOut)
            break
        end
        isOut = isOut | newOut;
    end

    good = isfinite(k) & ~isOut;
    if nnz(good) >= 2
        kClean(isOut) = interp1(tVec(good), k(good), tVec(isOut), 'linear');
        atEdge = isOut & isnan(kClean);            % vor erstem / nach letztem gültigen Frame
        kClean(atEdge) = interp1(tVec(good), k(good), tVec(atEdge), 'nearest', 'extrap');
    elseif nnz(good) == 1
        kClean(isOut) = k(good);
    else
        kClean(isOut) = NaN;
    end
end


%% Lokale Funktion: Krümmung in einem Fenster fester Länge ab der Spitze
% Die Spitze ist das Spline-Ende, das am weitesten vom Startpunkt (eingespanntes
% Ende) entfernt ist. Die Länge wird ENTLANG DER GLATTEN SPLINE gemessen (nicht
% über die Pixelkette, die bei schrägem Draht durch die Treppe länger ist).
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
    t = interp1(arc, tDense(iu), L - sTip);   % Kurvenparameter der Auswertepunkte
    [xs, ys, kappa] = splineCurvature(ppx, ppy, t);
end


%% Lokale Funktion: Referenz-Krümmung der Inlay-Sollform über das Fenster ab der Spitze
% Sollform TB01Lv01 (Geometrie wie inlayGeometry_v2.m): gerade Einlaufstrecke
% (kappa = 0) + 6 Kreisbögen (kappa = 1/r). Rückgabe: mittlere Krümmung [1/mm]
% über die letzten windowLen_mm ab der Spitze (Ende des 6. Bogens).
function kRef = inlayWindowKappa(windowLen_mm)
    p = [0,0; 2.5,0; 4.7,0.589; 5.505,3.595; 2.637,4.363; 2.014,3.741; 2.527,1.829; 3.827,1.829];
    r = [4.4, 2.2, 2.1, 1.7, 1.4, 1.3]';

    arcAngle = zeros(size(r));
    for n = 2:size(p,1)-1
        d = norm(p(n+1,:) - p(n,:));
        c = (p(n+1,:)' + p(n,:)')/2 + sqrt(r(n-1)^2 - d^2/4)/d*[0,-1;1,0]*(p(n+1,:)' - p(n,:)');
        a = atan2(p(n,2) - c(2), p(n,1) - c(1));
        b = atan2(p(n+1,2) - c(2), p(n+1,1) - c(1));
        arcAngle(n-1) = mod(b - a, 2*pi);
    end
    segLen   = [norm(p(2,:) - p(1,:)); r .* arcAngle];   % Gerade + 6 Bögen [mm]
    segKappa = [0; 1 ./ r];                               % [1/mm]

    % Von der Spitze aus rückwärts über windowLen_mm integrieren
    L = min(windowLen_mm, sum(segLen));
    remaining = L;
    integral  = 0;
    for i = numel(segLen):-1:1
        take = min(segLen(i), remaining);
        integral  = integral + segKappa(i) * take;
        remaining = remaining - take;
        if remaining <= 0
            break
        end
    end
    kRef = integral / L;
end
