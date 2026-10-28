% Function:
% Krümmung eines DRAHTS aus einer JPG-Bildsequenz bestimmen (SAM-2-Masken).
% 1. Ordner mit JPG-Bildern auswählen (mit Default-Pfad)
% 2. Pro Bild die vorberechnete SAM-2-Maske laden, skelettieren und die
%    Krümmung entlang der Mittellinie berechnen:
%    ALLE Skelettpixel (nach Bogenlänge sortiert) werden mit einer kubischen
%    Least-Squares-Spline approximiert, die Krümmung wird ANALYTISCH aus den
%    Spline-Ableitungen berechnet (wie kruemung_jinhan_v2_luca.m, siehe
%    README_kruemung_jinhan_v2.md Abschnitt 3.7/3.8).
%    Ausgewertet wird nur ein Fenster FESTER LÄNGE (windowLen_mm) ab der
%    Spitze = dem Drahtende nächst der Bildecke unten rechts. Zu kurze Bilder -> NaN.
% 3. Mittlere Krümmung über die Temperatur (aus Dateinamen) plotten
% 4. Farbliche Krümmungsdarstellung über dem Originalbild (mit Slider)
%
% WICHTIG - zweistufiger Workflow (Segmentierung mit Segment Anything Model 2,
% ersetzt die frühere Binarisierung + ROI/Polygon-Maske):
%   Schritt 1 (einmal pro Bilderordner, Python):
%       python segment_wire_sam2.py
%     -> Button "Bilderordner (.jpg)" waehlen, den Ordner auswaehlen; die
%        Masken werden als <ordnername>_sam2_masks\frame_00001.png, ...
%        NEBEN dem Bilderordner gespeichert (frame_00001.png = 1. Bild in
%        alphabetischer Reihenfolge = Reihenfolge des imageDatastore).
%        Einrichtung/Details: siehe README_SAM2.md
%   Schritt 2: dieses Skript ausführen (lädt die PNGs statt zu binarisieren).
clear; clc; close all;

% --- Parameter Spline-Fit (wie kruemung_jinhan_v2_luca.m) ---
knotSpacing = 40;    % Knotenabstand der Spline [px]: größer = glatter, kleiner = detailreicher
nParamIter  = 3;     % Fußpunkt-Iterationen (orthogonaler Abstand Punkt <-> Spline)
Neval       = 200;   % Auswertepunkte entlang der Spline (Darstellung + mittlere Krümmung)
pxPerMm     = 46.6;  % Maßstab der Bilder [px/mm] (mit imdistline am Lineal gemessen)
windowLen_mm = 13.51; % ausgewertete Länge ab der Spitze [mm] = Bogenlänge der 6 Soll-Bögen
maxFitRMS   = 2;     % Fit-Qualität: mittlerer Abstand Skelettpixel <-> Spline darüber [px]
                     % -> Frame nicht auswertbar (NaN), normal sind ~0.3-0.5 px

%% 1. Select folder with default path
defaultPath = 'M:\nascas2\Projects\MemoryCI 2.0\1 Dokumentation\AP01_Iterative Inlay-Entwicklung\AP 1.B BFR-Tests\Testergebnisse\2026-06-23-MV71-11-MV71-12';
ImgPath = uigetdir(defaultPath, 'Select folder with images');
if ImgPath == 0
    error('No folder selected');
end

%% 1b. SAM-2-Masken prüfen (müssen vorab mit segment_wire_sam2.py erzeugt sein)
[parentDir, imgFolderName] = fileparts(ImgPath);
maskDir = fullfile(parentDir, [imgFolderName '_sam2_masks']);
if ~isfolder(maskDir)
    error(['Keine SAM-2-Masken gefunden: %s\n' ...
           'Bitte zuerst das Python-Skript ausführen:\n' ...
           '    python segment_wire_sam2.py\n' ...
           'dort "Bilderordner (.jpg)" wählen und diesen Ordner auswählen ' ...
           '(siehe README_SAM2.md).'], maskDir);
end

%% 2. Create imageDatastore
imds = imageDatastore(fullfile(ImgPath, '*.jpg'));
ImageNummax = numel(imds.Files);

% Maskenanzahl muss exakt zur Bildanzahl passen (sonst falsche Zuordnung)
maskListing = dir(fullfile(maskDir, 'frame_*.png'));
if numel(maskListing) ~= ImageNummax
    error(['Maskenanzahl (%d) passt nicht zur Bildanzahl (%d) in %s.\n' ...
           'Bitte segment_wire_sam2.py für diesen Ordner erneut ausführen.'], ...
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

    figure(1)
    imshow(wireFG);

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
                warning('Frame %d: nur %d von %d Skelettpixeln abgelaufen.', n, numel(xx), nnz(skel));
            end
            [~, iTip] = min(distCorner);
            if numel(ex) >= 2 && hypot(xx(end) - ex(iTip), yy(end) - ey(iTip)) > 15
                warning('Frame %d: Weg endet nicht am Ende nächst der Ecke unten rechts.', n);
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
                    warning('Frame %d: sichtbare Länge %.2f mm < Fenster %.2f mm - wird mit NaN gefüllt.', ...
                        n, L_px / pxPerMm, windowLen_mm);
                end

                if fitRMS > maxFitRMS   % Spline passt nicht zum Skelett -> nicht auswerten
                    warning('Frame %d: Spline-Fit schlecht (RMS %.1f px > %.1f px) - wird mit NaN gefüllt.', ...
                        n, fitRMS, maxFitRMS);
                    xs = nan(1, Neval);  ys = nan(1, Neval);  kappa = nan(1, Neval);
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
    [~, name, ext] = fileparts(imds.Files{n});
    ImageData(n).name = [name, ext];
    ImageData(n).gray = grayImgFiltered;
    ImageData(n).bw   = wireFG;   % SAM-2-Maske (nach bwareaopen)
    ImageData(n).skel = skel;     % <-- neu
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
figure(2)
plot(Tu, kappaMean,'LineWidth',2,'Color',[0.8, 0.2, 0.6]);
xlabel('Temperatur [°C]');
ylabel('Mittlere Krümmung');
title(sprintf('Mittlere Krümmung abhängig von Temperatur (%.2f mm ab Spitze)', windowLen_mm));
fprintf('Spline-Fit: mittlerer RMS-Abstand = %.2f px (max %.2f px)\n', ...
    mean([ImageData.fitRMS], 'omitnan'), max([ImageData.fitRMS]));

%% 5. Farbliche Krümmungsdarstellung über dem Originalbild (mit Slider)
cmap = jet(256);
allKappa = [ImageData.kappa];
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

    title(hAx, sprintf('Spline über Originalbild (Frame %d / %d)', n, numel(ImageData)));
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
