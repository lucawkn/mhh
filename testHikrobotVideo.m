% TESTHIKROBOTVIDEO  Standalone test of manage_HikrobotVideo (no experiment,
% no Arduino). Records 2 s, stops, checks frame rate / dropped frames, and
% extracts frames at three simulated "pulse OFF" times.
%
% Run in the folder containing manage_HikrobotVideo.m. Results are written to
% .\Testergebnisse\ (video, timestamp file, Frames_<name>\).

clear; clc;

videoName   = 'test_hikrobot.avi';
recordTime  = 2;          % seconds
exposure_us = 500;        % [] = default from the function

% ---- 1) record ------------------------------------------------------------
cam = manage_HikrobotVideo('init', videoName, exposure_us);
src = getselectedsource(cam.vid);
if isprop(src, 'ResultingFrameRate')
    fprintf('Camera reports ResultingFrameRate = %.1f fps\n', src.ResultingFrameRate);
end

% Simulated Arduino zero = now (in the real experiment PulseLog comes from the Arduino)
zeroWallClock = datetime('now');

pause(recordTime);        % pause lets the write callback run

res = manage_HikrobotVideo('save', cam.vid);

% ---- 2) check the recording -----------------------------------------------
folderName = 'Testergebnisse';
videoPath  = fullfile(folderName, videoName);
fileInfo   = dir(videoPath);
fprintf('\n===== Result =====\n');
fprintf('Frames written     : %d\n', res.FrameCount);
fprintf('Measured fps       : %.1f (target 526.5)\n', res.MeasuredFps);
fprintf('Dropped frames     : %d\n', res.DroppedFrames);
fprintf('Wall-clock duration: %.2f s\n', seconds(res.StopTime - cam.recordStartTime));
fprintf('File size          : %.1f MB\n', fileInfo.bytes / 1e6);

vr = VideoReader(videoPath);
fprintf('VideoReader        : %d frames, %dx%d, %.1f fps tag\n', ...
        vr.NumFrames, vr.Width, vr.Height, vr.FrameRate);

S = load(res.TimestampFile, 'Timestamps');
dt_ms = diff(S.Timestamps.FrameTimes_s) * 1000;
figure('Name', 'Frame intervals');
plot(dt_ms, '.'); grid on;
xlabel('Frame'); ylabel('Interval [ms]');
yline(1000/526.5, 'r--', 'ideal 1.90 ms');
title(sprintf('Frame intervals (median %.3f ms, max %.3f ms)', median(dt_ms), max(dt_ms)));

% ---- 3) extract with simulated pulses ---------------------------------------
Messdata.VideoStartTime  = cam.recordStartTime;
Messdata.VideoStopTime   = res.StopTime;
Messdata.VideoFrameCount = res.FrameCount;
Messdata.PulseLog.ZeroWallClock = zeroWallClock;
Messdata.PulseLog.PulseOff_s    = [0.5; 1.0; 1.5];   % seconds after zeroWallClock

manage_HikrobotVideo('extract', videoName, Messdata);

% show the extracted frames
outDir = fullfile(folderName, ['Frames_' erase(videoName, '.avi')]);
imgs   = dir(fullfile(outDir, '*.png'));
figure('Name', 'Extracted frames');
for k = 1:numel(imgs)
    subplot(1, numel(imgs), k);
    imshow(imread(fullfile(outDir, imgs(k).name)));
    title(imgs(k).name, 'Interpreter', 'none');
end

% ---- 4) verdict -------------------------------------------------------------
ok = res.FrameCount > 0.9 * recordTime * 526.5 && res.DroppedFrames == 0;
if ok
    fprintf('\nTEST PASSED: full frame rate, no dropped frames.\n');
else
    fprintf('\nTEST CHECK: see warnings above (frame rate / dropped frames).\n');
end
