% This gives the inlay geometry for TB01Lv01
% Written by: N. Suzaly
% Created on: 2019-07-05
%
% Erweiterung v2: Die Krümmung wird mit DERSELBEN Methode wie in
% kruemung_jinhan_v2_luca.m berechnet (kubische Least-Squares-Spline durch
% die Kurvenpunkte + analytische Krümmung aus den Spline-Ableitungen).
% Zusätzlich wird die EXAKTE mittlere Krümmung der Geometrie ausgegeben
% (Kreisbögen: kappa = 1/r, Gerade: kappa = 0). Der exakte Wert in 1/mm ist
% die Referenzlinie kappaInlay in kruemung_jinhan_v2_luca.m; der Spline-Wert
% zeigt, wie nah die Spline-Methode bei diesem Maßstab an die Geometrie kommt.

clear all;
close all;
clc;

% [x,y]-coordinates for specified points in the inlay geometry. Coordinates
% obtained from Inventor
p0 = [0,0];
p1 = [2.5,0];
p2 = [4.7,0.589];
p3 = [5.505,3.595];
p4 = [2.637, 4.363];
p5 = [2.014, 3.741];
p6 = [2.527, 1.829];
p7 = [3.827, 1.829];

p = [p0;p1;p2;p3;p4;p5;p6;p7];

r = [4.4, 2.2 , 2.1, 1.7, 1.4, 1.3]';  % specified radius for the six arcs

% [x,y]-coordinates of the center of the six arcs. Coordinates obtained
% from Inventor
C1 = [2.5, 4.4];
C2 = [3.6,2.495];
C3 = [3.687, 2.545];
C4 = [3.487, 2.891];
C5 = [3.227, 3.041];
C6 = [3.177, 2.955];

C = [C1;C2;C3;C4;C5;C6];

% specified angles [rad] for the six arcs
rad1 = pi/6;
rad2 = pi/2;
rad3 = pi/2;
rad4 = pi/6;
rad5 = pi/2;
rad6 = pi/3;

rad = [rad1;rad2;rad3;rad4;rad5;rad6];

pts = 100;
d = [];
c = [];
a = [];
b= [];
t = [];
lxc = nan(pts, length(r));
lyc = nan(pts, length(r));

% Draw arcs
for n = 2:length(p)-1

    d(:,n-1) = norm(p(n+1,:)'-p(n,:)');  % r has to be larger than d/2
    c(n-1,:) = (p(n+1,:)'+p(n,:)')/2 + sqrt(r(n-1)^2-d(n-1)^2/4)/d(n-1)*[0,-1;1,0]*(p(n+1,:)'-p(n,:)');
    a(:,n-1) = atan2(p(n,2)-c(n-1,2),p(n,1)-c(n-1,1));
    b(:,n-1) = atan2(p(n+1,2)-c(n-1,2),p(n+1,1)-c(n-1,1));
    b(:,n-1) = mod(b(n-1)-a(n-1),2*pi)+a(n-1);
    t(:,n-1) = linspace(a(n-1),b(n-1),pts);
    lxc(:,n-1) = c(n-1,1) + r(n-1)*cos(t(:,n-1));
    lyc(:,n-1) = c(n-1,2) + r(n-1)*sin(t(:,n-1));

end
lx1= linspace(0,2.5,pts)';  %initial line before first arc
ly1= linspace(0,0,pts)';

lx = [lx1;lxc(:,1);lxc(:,2);lxc(:,3);lxc(:,4);lxc(:,5);lxc(:,6)];
ly = [ly1;lyc(:,1);lyc(:,2);lyc(:,3);lyc(:,4);lyc(:,5);lyc(:,6)];

inlay = [lx,ly];

xlswrite('inlayGeometry100.xls',inlay);  %import x,y-coordinates of inlay geometry into excel file

figure;
plot(lx,ly,'.')


%% Mittlere Krümmung per Least-Squares-Spline (Methode wie kruemung_jinhan_v2_luca.m)
% Parameter IDENTISCH zu kruemung_jinhan_v2_luca.m halten, sonst sind die
% Werte nicht vergleichbar!
knotSpacing = 40;    % Knotenabstand der Spline [px]
nParamIter  = 3;     % Fußpunkt-Iterationen (orthogonaler Abstand)
Neval       = 200;   % Auswertepunkte entlang der Spline

% Pixel pro mm des Videos (aus Kalibrierung). 1 = keine Umrechnung.
% WICHTIG: echten Kalibrierwert eintragen! Krümmung ist 1/Länge und skaliert
% mit dem Maßstab; außerdem ist knotSpacing in px angegeben -> ohne richtigen
% Maßstab glättet die Spline die Inlay-Geometrie falsch stark.
pxPerMm = 1;

% Geometrie in den Pixel-Maßstab des Videos bringen (mm -> px)
X = lx(:) * pxPerMm;
Y = ly(:) * pxPerMm;

% Bogenlänge als Kurvenparameter (Analogon zur Geodät-Distanz d im Video).
% Doppelte Punkte an Bogenübergängen -> unique entfernt sie.
s_arc = [0; cumsum(hypot(diff(X), diff(Y)))];
[s_arc, iu] = unique(s_arc);
X = X(iu);  Y = Y(iu);

if s_arc(end) < 4*knotSpacing
    warning(['Inlay-Länge (%.1f px) ist nur %.1f x knotSpacing - die Spline ' ...
             'glättet die Bögen stark. Ist pxPerMm (= %g) richtig gesetzt?'], ...
        s_arc(end), s_arc(end)/knotSpacing, pxPerMm);
end

[ppx, ppy, fitRMS] = fitSplineLSQ(s_arc, X, Y, knotSpacing, nParamIter);
s = linspace(ppx.breaks(1), ppx.breaks(end), Neval);
[xs, ys, kappa] = splineCurvature(ppx, ppy, s);

meanKappa = mean(kappa, 'omitnan');   % mittlere Krümmung Spline [1/px]

%% Exakte Krümmung der Geometrie (zum Vergleich)
% Gerade: kappa = 0; Bogen i: kappa = 1/r_i über die Bogenlänge r_i*(b_i-a_i).
arcAngle = (b - a).';                              % tatsächliche Bogenwinkel [rad]
segLen   = [2.5; r .* arcAngle] * pxPerMm;         % Segmentlängen [px]
segKappa = [0; 1 ./ r] / pxPerMm;                  % Segmentkrümmungen [1/px]
meanKappaExact = sum(segKappa .* segLen) / sum(segLen);

% --- Ausgabe ---
fprintf('\nInlay-Krümmung (Methode wie kruemung_jinhan_v2_luca.m, Maßstab %.4f px/mm):\n', pxPerMm);
fprintf('  knotSpacing = %g px, Spline-Fit RMS = %.4f px\n', knotSpacing, fitRMS);
fprintf('Mittlere Krümmung Spline:            %.4f 1/px = %.4f 1/mm\n', meanKappa, meanKappa*pxPerMm);
fprintf('Mittlere Krümmung exakt (Geometrie): %.4f 1/px = %.4f 1/mm  (= kappaInlay in kruemung_jinhan_v2_luca.m)\n', ...
    meanKappaExact, meanKappaExact*pxPerMm);

% --- Spline im Geometrie-Plot (in mm-Koordinaten für die Anzeige) ---
hold on;
plot(xs/pxPerMm, ys/pxPerMm, 'r-', 'LineWidth', 1.5);
axis equal; grid on;
title(sprintf('Inlay: mittlere Krümmung = %.4f 1/px  (%.4f px/mm)', ...
    meanKappa, pxPerMm));
legend('Geometrie', 'Least-Squares-Spline', 'Location', 'best');
hold off;

% --- Krümmungsverlauf: Spline vs. exakt ---
figure;
stairs([0; cumsum(segLen)], [segKappa; segKappa(end)], 'k-', 'LineWidth', 1.5);
hold on;
plot(s, kappa, 'r-', 'LineWidth', 1.5);
xlabel('Bogenlänge [px]');
ylabel('Krümmung [1/px]');
title('Krümmungsverlauf Inlay');
legend('exakt (1/r)', sprintf('Spline (knotSpacing = %g px)', knotSpacing), 'Location', 'best');
grid on;
hold off;


%% Lokale Funktionen (IDENTISCH zu kruemung_jinhan_v2_luca.m halten!)

% Kubische Least-Squares-Spline durch die Kurvenpunkte
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


% Spline auswerten + Krümmung aus exakten Ableitungen
function [xs, ys, kappa] = splineCurvature(ppx, ppy, s)
    ppdx = ppDeriv(ppx);  ppddx = ppDeriv(ppdx);
    ppdy = ppDeriv(ppy);  ppddy = ppDeriv(ppdy);

    xs  = ppval(ppx, s);    ys  = ppval(ppy, s);
    dx  = ppval(ppdx, s);   dy  = ppval(ppdy, s);
    ddx = ppval(ppddx, s);  ddy = ppval(ppddy, s);

    kappa = abs(dx.*ddy - dy.*ddx) ./ (dx.^2 + dy.^2).^(1.5);
end


% Exakte Ableitung einer stückweisen Polynomfunktion (pp-Form)
function dpp = ppDeriv(pp)
    [breaks, coefs, ~, order, dim] = unmkpp(pp);
    dcoefs = coefs(:, 1:order-1) .* (order-1:-1:1);
    dpp = mkpp(breaks, dcoefs, dim);
end
