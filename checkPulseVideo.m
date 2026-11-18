function checkPulseVideo(matFile)
% CHECKPULSEVIDEO  Shows whether the current pulses are visible in the
% Hikrobot video and whether the pulse times fall inside the recording.
%
%   checkPulseVideo('Testergebnisse\<name>.mat')
%
% Reads the video frame by frame (low RAM), computes per frame
%   - mean brightness
%   - change to the previous frame (motion / flicker)
% and plots both over the Arduino time axis with the pulses shaded.
% Also shows frames just before, during and after the first pulse.

    S = load(matFile, 'Messdata'); M = S.Messdata;
    [~, name] = fileparts(matFile);
    videoName = [name '_video.avi'];

    % prefer the local copy (fast), then Testergebnisse
    srcDir = 'C:\HikrobotVideos';
    if ~exist(fullfile(srcDir, videoName), 'file'), srcDir = 'Testergebnisse'; end
    aviFile = fullfile(srcDir, videoName);
    tsFile  = fullfile(srcDir, [name '_video_timestamps.mat']);
    T = load(tsFile, 'Timestamps'); TS = T.Timestamps;

    % frame times on the Arduino time axis (0 = Arduino zero)
    PL = M.PulseLog;
    offset_s = seconds(PL.ZeroWallClock - TS.TriggerTime);
    tFrame   = TS.FrameTimes_s(:) - offset_s;

    tOff = PL.PulseOff_s(:);
    if isfield(PL, 'PulseOn_s')
        tOn = PL.PulseOn_s(:);
    else
        tOn = tOff - M.Settings.PulseDurations(1) / 1000;   % from the nominal width
    end

    fprintf('Video: %d frames, %.2f s ... %.2f s on the Arduino axis\n', ...
            numel(tFrame), tFrame(1), tFrame(end));
    fprintf('Pulses: %.3f s ... %.3f s\n', tOn(1), tOff(end));
    if tOn(1) < tFrame(1) || tOff(end) > tFrame(end)
        warning('Pulses lie (partly) OUTSIDE the video -> sync / timing problem.');
    end

    % ---- per-frame brightness and change --------------------------------
    vr = VideoReader(aviFile);
    n  = min(vr.NumFrames, numel(tFrame));
    meanI = nan(n, 1); diffI = nan(n, 1);
    prev = [];
    fprintf('Reading %d frames ... ', n);
    for k = 1:n
        f = double(rgb2grayIfNeeded(readFrame(vr)));
        meanI(k) = mean(f(:));
        if ~isempty(prev), diffI(k) = mean(abs(f(:) - prev(:))); end
        prev = f;
    end
    fprintf('done.\n');
    tFrame = tFrame(1:n);

    figure('Name', 'Pulse visibility');
    subplot(2,1,1); hold on;
    plot(tFrame, meanI, 'k'); grid on; shadePulses(tOn, tOff);
    ylabel('mean brightness'); title('Grey = pulse (Arduino time axis)');
    subplot(2,1,2); hold on;
    plot(tFrame, diffI, 'b'); grid on; shadePulses(tOn, tOff);
    ylabel('change to previous frame'); xlabel('time [s] (0 = Arduino zero)');

    % ---- frames around the first pulse -----------------------------------
    tShow  = [tOn(1) - 0.010, (tOn(1) + tOff(1)) / 2, tOff(1), tOff(1) + 0.050];
    labels = {'10 ms before', 'mid pulse', 'pulse end', '50 ms after'};
    vr = VideoReader(aviFile);
    figure('Name', 'First pulse');
    for k = 1:numel(tShow)
        [~, idx] = min(abs(tFrame - tShow(k)));
        subplot(1, numel(tShow), k);
        imshow(read(vr, idx));
        title(sprintf('%s\nframe %d (t = %.3f s)', labels{k}, idx, tFrame(idx)));
    end
end

function g = rgb2grayIfNeeded(f)
    if size(f, 3) == 3, g = rgb2gray(f); else, g = f; end
end

function shadePulses(tOn, tOff)
% grey bands for the pulses behind the already plotted curve
    yl = ylim;
    for k = 1:numel(tOn)
        h = patch([tOn(k) tOff(k) tOff(k) tOn(k)], [yl(1) yl(1) yl(2) yl(2)], ...
                  [0.85 0.85 0.85], 'EdgeColor', 'none', 'HandleVisibility', 'off');
        uistack(h, 'bottom');
    end
    ylim(yl);
end
