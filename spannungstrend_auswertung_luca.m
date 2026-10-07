% ========================================================================
% spannungstrend_auswertung_luca.m
% ========================================================================
% Automatische Trendanalyse der Testparameter-Exceldatei, die mit
%   - kruemmung_jinhan_v16_batch_skip_excel.m  ("Neue Metrik", Spalten M:V) und
%   - kruemung_jinhan_v2_luca_batch.m          ("Luca's Metrik", Spalten W:Z)
% gefuellt wurde. Basis: spannungstrend_auswertung_v2.m (ohne Regressionslinien).
%
% Ziel:
%   Fuer jede Kombination aus
%       Pulslaenge [ms] x Pulsanzahl x Pulspause [ms]
%   wird der Einfluss von SPANNUNG und ENERGIE auf folgende Groessen untersucht:
%
%       1) NEU kmax   = "NEU Max k_netto"                    (Excel-Spalte M)
%       2) NEU kend   = "NEU End k_netto"                    (Excel-Spalte N)
%       3) Luca kmax  = "Spline Max mittl. Kruemmung [1/mm]" (Excel-Spalte W)
%       4) Luca kend  = "Spline End-Kruemmung [1/mm]"        (Excel-Spalte X)
%
%   x-Groessen:
%       Spannung [V]  = "Spannung-set/V"   (Excel-Spalte C)
%       Energie [mJ]  = Leistung-FM [W] (Spalte H) * Pulslaenge [ms] * Pulsanzahl
%                       (Gesamtenergie; W * ms = mJ. Fehlt H, wird
%                        Spannung-FM (E) * Strom-messen (G) verwendet.)
%
% Pro Metrik und x-Groesse werden berechnet:
%   - lineare Steigung pro x-Einheit
%   - R^2 der linearen Regression
%   - p-Wert der linearen Steigung
%   - Spearman-rho (monotoner Zusammenhang)
%   - approximativer p-Wert fuer Spearman-rho
%
% Es wird KEINE Statistics and Machine Learning Toolbox benoetigt.
%
% Ausgabe:
%   <Excelname>_Spannungstrend_Luca_YYYYMMDD_HHMMSS.xlsx
%       Blatt "Trend_Ergebnisse"  -> eine Zeile je Parametersatz + Metrik + x-Groesse
%       Blatt "Extrahierte_Daten" -> alle aus der Quelldatei gelesenen Werte
%       Blatt "Info"              -> kurze Dokumentation
%
% Optional pro Parametersatz ein PNG mit 4 Diagrammen (nur Messwerte verbunden,
% keine Regressionsgeraden):
%       oben links : Neue Metrik  ueber Spannung | oben rechts : Luca's Metrik ueber Spannung
%       unten links: Neue Metrik  ueber Energie  | unten rechts: Luca's Metrik ueber Energie
% Die Quelldatei wird NICHT veraendert.
% ========================================================================

clear; clc; close all;

%% --------------------------- Konfiguration -----------------------------
CREATE_PLOTS = true;       % false = nur Excel-Auswertung, keine PNGs
ALPHA = 0.05;              % Signifikanzniveau fuer Trend-Kennzeichnung
MAX_EXCEL_ROWS = 1000;     % gelesener Bereich je Blatt: A1:Z<MAX_EXCEL_ROWS>
N_COLS = 26;               % A..Z

%% ------------------------ Excel-Datei waehlen --------------------------
[xlsxName, xlsxDir] = uigetfile({'*.xlsx;*.xlsm','Excel-Datei (*.xlsx, *.xlsm)'}, ...
    'Testparameter-Excel mit den Krümmungsergebnissen auswählen');
if isequal(xlsxName,0)
    error('Keine Excel-Datei ausgewaehlt.');
end
excelPath = fullfile(xlsxDir,xlsxName);

[~,baseName,~] = fileparts(excelPath);
stamp = datestr(now,'yyyymmdd_HHMMSS');
outPath = fullfile(xlsxDir, sprintf('%s_Spannungstrend_Luca_%s.xlsx',baseName,stamp));
plotDir = fullfile(xlsxDir, sprintf('%s_Spannungstrend_Luca_Plots_%s',baseName,stamp));
if CREATE_PLOTS && ~isfolder(plotDir)
    mkdir(plotDir);
end

fprintf('Quelle : %s\n',excelPath);
fprintf('Ausgabe: %s\n\n',outPath);

%% ---------------------- Alle Messdaten extrahieren ---------------------
allRows = table();
sheets = string(sheetnames(excelPath));
blockGlobal = 0;

for iSheet = 1:numel(sheets)
    sheetName = sheets(iSheet);
    fprintf('Lese Blatt: %s\n',sheetName);

    try
        raw = readcell(excelPath,'Sheet',sheetName, ...
            'Range',sprintf('A1:Z%d',MAX_EXCEL_ROWS));
    catch ME
        warning('Blatt "%s" konnte nicht gelesen werden: %s',sheetName,ME.message);
        continue;
    end

    if isempty(raw)
        continue;
    end
    if size(raw,2) < N_COLS            % readcell kann leere Randspalten weglassen
        raw(:,end+1:N_COLS) = {[]};
    end

    nRows = size(raw,1);
    blockStarts = [];
    for r = 1:nRows
        if isTextEqual(raw{r,2},'Pulslänge/ms') || isTextEqual(raw{r,2},'Pulslaenge/ms')
            blockStarts(end+1) = r; %#ok<SAGROW>
        end
    end

    if isempty(blockStarts)
        continue;
    end

    for ib = 1:numel(blockStarts)
        r0 = blockStarts(ib);
        if r0+4 > nRows
            continue;
        end

        % Markerzeile r0, Parameter in r0+1, Kopfzeile in r0+3, Daten ab r0+4.
        pLen   = cellToNum(raw{r0+1,2});
        pCount = cellToNum(raw{r0+1,3});
        pPause = cellToNum(raw{r0+1,4});
        headerRow = r0+3;
        dataStart = headerRow+1;

        if any(~isfinite([pLen,pCount,pPause]))
            continue;
        end

        if ib < numel(blockStarts)
            dataEnd = blockStarts(ib+1)-1;
        else
            dataEnd = nRows;
        end

        blockGlobal = blockGlobal + 1;

        for r = dataStart:dataEnd
            % Spannung-set steht in Spalte C.
            U = cellToNum(raw{r,3});
            if ~isfinite(U)
                continue;
            end

            % Gemessene elektrische Groessen (C:H)
            U_FM = cellToNum(raw{r,5});   % E: Spannung-FM/V
            I    = cellToNum(raw{r,7});   % G: Strom-messen/A
            P    = cellToNum(raw{r,8});   % H: Leistung-FM/W
            if ~isfinite(P) && isfinite(U_FM) && isfinite(I)
                P = U_FM*I;
            end
            E_mJ = P*pLen*pCount;         % Gesamtenergie: W * ms = mJ

            % Ergebnisse Neue Metrik (v16, M:V) und Luca's Metrik (W:Z)
            neuMax    = cellToNum(raw{r,13});     % M
            neuEnd    = cellToNum(raw{r,14});     % N
            videoNeu  = cellToString(raw{r,22});  % V
            lucaMax   = cellToNum(raw{r,23});     % W
            lucaEnd   = cellToNum(raw{r,24});     % X
            lucaTmax  = cellToNum(raw{r,25});     % Y
            videoLuca = cellToString(raw{r,26});  % Z

            % Nur wirklich ausgewertete Zeilen uebernehmen.
            if ~any(isfinite([neuMax,neuEnd,lucaMax,lucaEnd])) && ...
                    strlength(videoNeu)==0 && strlength(videoLuca)==0
                continue;
            end

            newRow = table( ...
                string(sheetName), blockGlobal, pLen, pCount, pPause, U, ...
                U_FM, I, P, E_mJ, ...
                neuMax, neuEnd, lucaMax, lucaEnd, lucaTmax, videoNeu, videoLuca, ...
                'VariableNames', { ...
                'Sheet','Block','Pulslaenge_ms','Pulsanzahl','Pulspause_ms','Spannung_V', ...
                'SpannungFM_V','Strom_A','Leistung_W','Energie_mJ', ...
                'NeuKmax','NeuKend','LucaKmax','LucaKend','LucaTmax_s', ...
                'VideoDateiNeu','VideoDateiLuca'});

            allRows = [allRows; newRow]; %#ok<AGROW>
        end
    end
end

if isempty(allRows)
    error(['Keine auswertbaren Messwerte gefunden. Erwartet werden die Ergebnis-Spalten ' ...
           'M:N (Neue Metrik) und/oder W:X (Luca''s Metrik).']);
end

% Saubere Sortierung fuer Ausgabe und Plots.
allRows = sortrows(allRows,{'Pulslaenge_ms','Pulsanzahl','Pulspause_ms','Spannung_V'});

fprintf('\n%d Messzeilen aus %d Block/Bloecken extrahiert.\n',height(allRows),blockGlobal);

%% ------------------------ Trendanalyse ---------------------------------
metricDefs = {
    'NeuKmax',  'NEU kmax',  '1/mm';
    'NeuKend',  'NEU kend',  '1/mm';
    'LucaKmax', 'Luca kmax', '1/mm';
    'LucaKend', 'Luca kend', '1/mm'
};
xDefs = {
    'Spannung_V', 'Spannung', 'V';
    'Energie_mJ', 'Energie',  'mJ'
};

% Gruppierung nach den konstant gehaltenen Pulsparametern.
[G, groupLen, groupCount, groupPause] = findgroups( ...
    allRows.Pulslaenge_ms, allRows.Pulsanzahl, allRows.Pulspause_ms);

trendRows = table();

for g = 1:max(G)
    T = allRows(G==g,:);

    for ix = 1:size(xDefs,1)
        X = T.(xDefs{ix,1});

        for im = 1:size(metricDefs,1)
            Y = T.(metricDefs{im,1});
            stats = calcTrend(X,Y,ALPHA);

            tr = table( ...
                groupLen(g), groupCount(g), groupPause(g), ...
                string(metricDefs{im,2}), string(metricDefs{im,3}), ...
                string(xDefs{ix,2}), string(xDefs{ix,3}), ...
                stats.N, stats.Umin, stats.Umax, stats.Ymin, stats.Ymax, ...
                stats.Slope, stats.Intercept, stats.R2, stats.PLinear, ...
                stats.SpearmanRho, stats.PSpearman, ...
                string(stats.LinearTrend), string(stats.MonotonicTrend), ...
                'VariableNames', { ...
                'Pulslaenge_ms','Pulsanzahl','Pulspause_ms','Metrik','Einheit', ...
                'X_Groesse','X_Einheit', ...
                'N','Xmin','Xmax','Ymin','Ymax', ...
                'Steigung_pro_X_Einheit','Intercept','R2_linear','P_linear', ...
                'Spearman_rho','P_Spearman','Linearer_Trend','Monotoner_Trend'});

            trendRows = [trendRows; tr]; %#ok<AGROW>
        end
    end
end

%% ------------------------ Excel-Ausgabe --------------------------------
writetable(trendRows,outPath,'Sheet','Trend_Ergebnisse');
writetable(allRows,outPath,'Sheet','Extrahierte_Daten');

info = {
    'Spannungstrend-Auswertung (Neue Metrik vs. Luca''s Metrik)', 'Automatisch erzeugt';
    'Quelle', excelPath;
    'Erstellt', datestr(now,'yyyy-mm-dd HH:MM:SS');
    'Signifikanzniveau alpha', ALPHA;
    'NEU kmax', 'NEU Max k_netto (M), kruemmung_jinhan_v16_batch_skip_excel.m';
    'NEU kend', 'NEU End k_netto (N)';
    'Luca kmax', 'Spline Max mittl. Kruemmung (W), kruemung_jinhan_v2_luca_batch.m';
    'Luca kend', 'Spline End-Kruemmung (X)';
    'Spannung', 'Spannung-set/V (C)';
    'Energie', 'Leistung-FM/W (H) * Pulslaenge/ms * Pulsanzahl = Gesamtenergie in mJ';
    'Steigung', 'Aenderung der Zielgroesse pro 1 V bzw. 1 mJ (Spalte X_Einheit)';
    'R2_linear', 'Erklaerter Varianzanteil des linearen Modells';
    'Spearman_rho', 'Monotoner Zusammenhang zwischen x-Groesse und Zielgroesse';
    'P_Spearman', 'Approx. zweiseitiger p-Wert aus t-Approximation';
    'Quelldatei veraendert', 'Nein'
};
writecell(info,outPath,'Sheet','Info','Range','A1');

%% ------------------------ Diagramme ------------------------------------
if CREATE_PLOTS
    fprintf('Erzeuge Trenddiagramme ...\n');

    for g = 1:max(G)
        T = allRows(G==g,:);
        T = sortrows(T,'Spannung_V');

        pLen   = groupLen(g);
        pCount = groupCount(g);
        pPause = groupPause(g);

        fig = figure('Visible','off','Color','w', ...
            'Name',sprintf('%g ms | %g Pulse | %g ms Pause',pLen,pCount,pPause), ...
            'Position',[100 100 1250 850]);
        tl = tiledlayout(fig,2,2,'TileSpacing','compact','Padding','compact');
        title(tl,sprintf('Spannungs-/Energietrend | Pulslaenge %g ms | %g Pulse | Pause %g ms', ...
            pLen,pCount,pPause),'Interpreter','none');

        % --- Neue Metrik ueber Spannung ---
        ax1 = nexttile(tl,1); hold(ax1,'on'); grid(ax1,'on'); box(ax1,'on');
        plotSeriesOnly(ax1,T.Spannung_V,T.NeuKmax,'kmax NEU');
        plotSeriesOnly(ax1,T.Spannung_V,T.NeuKend,'kend NEU');
        xlabel(ax1,'Spannung [V]'); ylabel(ax1,'kappa netto [1/mm]');
        title(ax1,'Neue Metrik (k_{netto})'); legend(ax1,'Location','best');

        % --- Luca's Metrik ueber Spannung ---
        ax2 = nexttile(tl,2); hold(ax2,'on'); grid(ax2,'on'); box(ax2,'on');
        plotSeriesOnly(ax2,T.Spannung_V,T.LucaKmax,'kmax Luca');
        plotSeriesOnly(ax2,T.Spannung_V,T.LucaKend,'kend Luca');
        xlabel(ax2,'Spannung [V]'); ylabel(ax2,'mittl. Kruemmung [1/mm]');
        title(ax2,'Luca''s Metrik (Spline, mittl. Kruemmung)'); legend(ax2,'Location','best');

        % --- Neue Metrik ueber Energie ---
        ax3 = nexttile(tl,3); hold(ax3,'on'); grid(ax3,'on'); box(ax3,'on');
        plotSeriesOnly(ax3,T.Energie_mJ,T.NeuKmax,'kmax NEU');
        plotSeriesOnly(ax3,T.Energie_mJ,T.NeuKend,'kend NEU');
        xlabel(ax3,'Energie [mJ]'); ylabel(ax3,'kappa netto [1/mm]');
        title(ax3,'Neue Metrik (k_{netto})'); legend(ax3,'Location','best');

        % --- Luca's Metrik ueber Energie ---
        ax4 = nexttile(tl,4); hold(ax4,'on'); grid(ax4,'on'); box(ax4,'on');
        plotSeriesOnly(ax4,T.Energie_mJ,T.LucaKmax,'kmax Luca');
        plotSeriesOnly(ax4,T.Energie_mJ,T.LucaKend,'kend Luca');
        xlabel(ax4,'Energie [mJ]'); ylabel(ax4,'mittl. Kruemmung [1/mm]');
        title(ax4,'Luca''s Metrik (Spline, mittl. Kruemmung)'); legend(ax4,'Location','best');

        fileStem = sprintf('Trend_%gms_%gPulse_%gmsPause',pLen,pCount,pPause);
        fileStem = regexprep(fileStem,'[^A-Za-z0-9_-]','_');
        pngPath = fullfile(plotDir,[fileStem '.png']);

        try
            exportgraphics(fig,pngPath,'Resolution',180);
        catch
            saveas(fig,pngPath);
        end
        close(fig);
    end
end

%% ------------------------ Konsolenzusammenfassung ----------------------
fprintf('\n============================================================\n');
fprintf('TRENDANALYSE FERTIG\n');
fprintf('============================================================\n');
fprintf('Messzeilen        : %d\n',height(allRows));
fprintf('Parametergruppen  : %d\n',max(G));
fprintf('Trendzeilen       : %d\n',height(trendRows));
fprintf('Ergebnisdatei     : %s\n',outPath);
if CREATE_PLOTS
    fprintf('Diagrammordner    : %s\n',plotDir);
end

% Kompakte Anzeige nur der statistisch auffaelligen Trends.
sigMask = (trendRows.P_linear < ALPHA) | (trendRows.P_Spearman < ALPHA);
if any(sigMask)
    fprintf('\nTrends mit p < %.3f in mindestens einem Test:\n',ALPHA);
    disp(trendRows(sigMask,{'Pulslaenge_ms','Pulsanzahl','Pulspause_ms','Metrik','X_Groesse', ...
        'Steigung_pro_X_Einheit','R2_linear','P_linear','Spearman_rho','P_Spearman'}));
else
    fprintf('\nKein Trend erreicht p < %.3f. Die Effektgroessen/Plots trotzdem pruefen.\n',ALPHA);
end

%% ======================================================================
% Lokale Funktionen
% =======================================================================
function stats = calcTrend(x,y,alpha)
    good = isfinite(x) & isfinite(y);
    x = double(x(good));
    y = double(y(good));

    stats = struct('N',numel(x),'Umin',NaN,'Umax',NaN,'Ymin',NaN,'Ymax',NaN, ...
        'Slope',NaN,'Intercept',NaN,'R2',NaN,'PLinear',NaN, ...
        'SpearmanRho',NaN,'PSpearman',NaN, ...
        'LinearTrend','zu wenig Daten','MonotonicTrend','zu wenig Daten');

    if isempty(x)
        return;
    end

    stats.Umin = min(x);
    stats.Umax = max(x);
    stats.Ymin = min(y);
    stats.Ymax = max(y);

    if numel(x) < 3 || numel(unique(x)) < 2
        return;
    end

    % ----- lineare Regression ohne Statistics Toolbox -----
    p = polyfit(x,y,1);
    yhat = polyval(p,x);
    slope = p(1);
    intercept = p(2);

    sse = sum((y-yhat).^2);
    sst = sum((y-mean(y)).^2);
    if sst > 0
        r2 = 1-sse/sst;
    else
        r2 = NaN;
    end

    n = numel(x);
    df = n-2;
    sxx = sum((x-mean(x)).^2);
    pLinear = NaN;
    if df > 0 && sxx > 0
        mse = sse/df;
        seSlope = sqrt(mse/sxx);
        if seSlope > 0
            tval = abs(slope/seSlope);
            pLinear = twoSidedTPvalue(tval,df);
        elseif abs(slope) > 0
            pLinear = 0;
        end
    end

    % ----- Spearman ohne Statistics Toolbox -----
    rx = rankWithTies(x);
    ry = rankWithTies(y);
    rho = pearsonSimple(rx,ry);
    pSpearman = NaN;
    if isfinite(rho) && n > 2
        if abs(rho) >= 1
            pSpearman = 0;
        else
            tRho = abs(rho)*sqrt((n-2)/max(eps,1-rho^2));
            pSpearman = twoSidedTPvalue(tRho,n-2);
        end
    end

    stats.Slope = slope;
    stats.Intercept = intercept;
    stats.R2 = r2;
    stats.PLinear = pLinear;
    stats.SpearmanRho = rho;
    stats.PSpearman = pSpearman;

    if isfinite(pLinear) && pLinear < alpha
        if slope > 0
            stats.LinearTrend = 'signifikant zunehmend';
        elseif slope < 0
            stats.LinearTrend = 'signifikant abnehmend';
        else
            stats.LinearTrend = 'kein linearer Trend';
        end
    else
        stats.LinearTrend = 'kein signif. linearer Trend';
    end

    if isfinite(pSpearman) && pSpearman < alpha
        if rho > 0
            stats.MonotonicTrend = 'signifikant zunehmend';
        elseif rho < 0
            stats.MonotonicTrend = 'signifikant abnehmend';
        else
            stats.MonotonicTrend = 'kein monotoner Trend';
        end
    else
        stats.MonotonicTrend = 'kein signif. monotoner Trend';
    end
end

% -----------------------------------------------------------------------
function plotSeriesOnly(ax,x,y,labelText)
    good = isfinite(x) & isfinite(y);
    xg = double(x(good));
    yg = double(y(good));

    if isempty(xg)
        return;
    end

    % Nur die tatsaechlichen Messwerte in aufsteigender Spannung darstellen.
    % Keine Regressionsgerade und keine Formel/Kennzahlen in der Legende.
    [xs,ord] = sort(xg);
    ys = yg(ord);
    plot(ax,xs,ys,'o-','LineWidth',1.2,'MarkerSize',5,'DisplayName',labelText);
end

% -----------------------------------------------------------------------
function r = rankWithTies(x)
    x = x(:);
    n = numel(x);
    [sx,order] = sort(x);
    rSorted = zeros(n,1);
    i = 1;
    while i <= n
        j = i;
        while j < n && sx(j+1)==sx(i)
            j = j+1;
        end
        avgRank = (i+j)/2;
        rSorted(i:j) = avgRank;
        i = j+1;
    end
    r = zeros(n,1);
    r(order) = rSorted;
end

% -----------------------------------------------------------------------
function rho = pearsonSimple(a,b)
    a = a(:); b = b(:);
    if numel(a)~=numel(b) || numel(a)<2
        rho = NaN;
        return;
    end
    da = a-mean(a);
    db = b-mean(b);
    den = sqrt(sum(da.^2)*sum(db.^2));
    if den <= eps
        rho = NaN;
    else
        rho = sum(da.*db)/den;
        rho = max(-1,min(1,rho));
    end
end

% -----------------------------------------------------------------------
function p = twoSidedTPvalue(tAbs,df)
% Zweiseitiger p-Wert der t-Verteilung ueber betainc.
% Entspricht fuer t>=0: p = 2*(1-tcdf(t,df)), benoetigt aber keine Stats-Toolbox.
    if ~isfinite(tAbs) || ~isfinite(df) || df<=0
        p = NaN;
        return;
    end
    x = df/(df+tAbs^2);
    p = betainc(x,df/2,0.5);
    p = max(0,min(1,p));
end

% -----------------------------------------------------------------------
function tf = isTextEqual(x,txt)
    tf = false;
    if ischar(x) || isstring(x)
        tf = strcmpi(strtrim(string(x)),strtrim(string(txt)));
    end
end

% -----------------------------------------------------------------------
function v = cellToNum(x)
    if isnumeric(x) && isscalar(x)
        v = double(x);
    elseif islogical(x) && isscalar(x)
        v = double(x);
    elseif ischar(x) || isstring(x)
        s = strtrim(string(x));
        if strlength(s)==0
            v = NaN;
        else
            v = str2double(strrep(s,',','.'));
        end
    else
        v = NaN;
    end
end

% -----------------------------------------------------------------------
function s = cellToString(x)
    if ischar(x) || isstring(x)
        s = strtrim(string(x));
    elseif isnumeric(x) && isscalar(x) && isfinite(x)
        s = string(x);
    else
        s = "";
    end
end
