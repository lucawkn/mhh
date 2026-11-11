function out = manage_HikrobotVideo(cmd, varargin)
% MANAGE_HIKROBOTVIDEO  Recording + pulse-frame extraction for the
% Hikrobot MV-CS004-10UC (USB3 Vision, Sony IMX287, global shutter).
% Same interface as manage_DinoVideo_v5:
%
%  init:    out = manage_HikrobotVideo('init', fileName [, exposure_us])
%           start recording at max frame rate / full resolution,
%           returns out.vid and out.recordStartTime
%  save:    out = manage_HikrobotVideo('save', vid)
%           stop recording, returns out.StopTime and out.FrameCount
%           (+ MeasuredFps, DroppedFrames, TimestampFile)
%  extract: manage_HikrobotVideo('extract', videoName, Messdata)
%           one frame per pulse OFF, synced to the Arduino master timeline
%           via per-frame timestamps (fallback: average frame rate).
%
% Camera settings (data sheet): 720 x 540, 526.5 fps max in BayerRG8.
% Recording format: raw Bayer mosaic in an uncompressed 8-bit
% 'Grayscale AVI' (~205 MB/s at full speed, about 12 GB per minute -> use an SSD).
% Colour is restored only during 'extract' (demosaic, RGGB pattern).
% Recording in RGB would triple the data rate, and Motion JPEG cannot be
% encoded in real time at 526 fps.
%
% Requirements (Windows):
%  - Hikrobot MVS installed (provides the USB3 Vision GenTL producer
%    MvProducerU3V.cti and sets GENICAM_GENTL64_PATH)
%  - Image Acquisition Toolbox + "Image Acquisition Toolbox Support Package
%    for GenICam Interface" (adaptor 'gentl')
%  - Image Processing Toolbox (demosaic) for colour frames in 'extract'
%  - Close the MVS client before starting: only one program may open the camera.

    out = [];
    switch lower(cmd)
        case 'init'
            finalFileName = varargin{1};
            exposure_us = 500;                     % fixed short exposure against motion blur
            if numel(varargin) >= 2 && ~isempty(varargin{2})
                exposure_us = varargin{2};
            end

            imaqreset; pause(1.5);

            % ---- find the camera by name (enumeration order is not stable) ----
            camName   = 'MV-CS004';                % substring match, case-insensitive
            pixFormat = 'BayerRG8';                % only colour format with 526.5 fps
            try
                info = imaqhwinfo('gentl');
            catch ME
                error(['gentl adaptor not available (%s).\nInstall the "Image Acquisition ' ...
                       'Toolbox Support Package for GenICam Interface" and Hikrobot MVS.'], ME.message);
            end
            devID = []; devName = '';
            for k = 1:numel(info.DeviceIDs)
                if contains(info.DeviceInfo(k).DeviceName, camName, 'IgnoreCase', true)
                    devID   = info.DeviceIDs{k};
                    devName = info.DeviceInfo(k).DeviceName;
                    fmts    = info.DeviceInfo(k).SupportedFormats;
                    break;
                end
            end
            if isempty(devID)
                error(['Hikrobot %s not found among gentl devices. Check USB3 cable, ' ...
                       'close MVS, check imaqsupport for the MVS producer.'], camName);
            end
            if ~any(strcmpi(fmts, pixFormat))
                error('Format %s not offered by the camera. Available: %s', ...
                      pixFormat, strjoin(fmts, ', '));
            end
            fprintf('(using gentl DeviceID %d: %s, %s) ', devID, devName, pixFormat);

            vid = videoinput('gentl', devID, pixFormat);
            vid.ReturnedColorSpace = 'grayscale';  % keep the raw Bayer mosaic (1 byte/pixel)
            res = vid.VideoResolution;             % max resolution 720 x 540
            vid.ROIPosition = [0 0 res];
            triggerconfig(vid, 'immediate');
            vid.LoggingMode       = 'memory';      % frames are written by our callback
            vid.FramesPerTrigger  = Inf;
            vid.FrameGrabInterval = 1;             % keep every frame

            % ---- camera features (GenICam SFNC names, Hikrobot MVS) ----------
            src = getselectedsource(vid);
            trySet(src, 'TriggerMode', 'Off');                  % free run
            trySet(src, 'BinningHorizontal', 1);  trySet(src, 'BinningVertical', 1);
            trySet(src, 'DecimationHorizontal', 1); trySet(src, 'DecimationVertical', 1);
            trySet(src, 'DeviceLinkThroughputLimitMode', 'Off'); % no USB bandwidth cap
            trySet(src, 'ExposureMode', 'Timed');
            trySet(src, 'ExposureAuto', 'Off');
            trySet(src, 'ExposureTime', exposure_us);           % microseconds
            trySet(src, 'GainAuto', 'Continuous');              % brightness through gain
            trySet(src, 'AcquisitionFrameRateEnable', 'True');
            fpsNominal = NaN;
            if isprop(src, 'AcquisitionFrameRate')
                pinfo = propinfo(src, 'AcquisitionFrameRate');
                if isnumeric(pinfo.ConstraintValue) && numel(pinfo.ConstraintValue) == 2
                    trySet(src, 'AcquisitionFrameRate', pinfo.ConstraintValue(2));  % maximum
                end
                fpsNominal = src.AcquisitionFrameRate;
            end
            if isprop(src, 'ResultingFrameRate')                % what the camera really delivers
                fpsNominal = src.ResultingFrameRate;
            end
            % If the exposure (or the USB bandwidth) does not fit into one frame
            % period, the camera silently lowers its frame rate. ResultingFrameRate
            % then drops below the data-sheet maximum -> warn.
            fpsMaxDataSheet = 526.5;
            if ~isnan(fpsNominal) && fpsNominal < 0.99 * fpsMaxDataSheet
                warning(['Camera only reaches %.1f fps (max %.1f): exposure %.0f us too long ' ...
                         'or USB bandwidth limited. Shorten the exposure.'], ...
                        fpsNominal, fpsMaxDataSheet, exposure_us);
            end
            fprintf('\n  %dx%d, %.1f fps, exposure %.0f us\n', res(1), res(2), fpsNominal, exposure_us);

            % ---- video file -------------------------------------------------
            folderName = 'Testergebnisse';
            if ~exist(folderName, 'dir'), mkdir(folderName); end
            [~, baseName] = fileparts(finalFileName);
            writer = VideoWriter(fullfile(folderName, [baseName '.avi']), 'Grayscale AVI');
            if ~isnan(fpsNominal), writer.FrameRate = fpsNominal; end   % correct playback speed
            open(writer);

            ud = struct('writer', writer, 'nWritten', 0, 't', zeros(0,1), ...
                        'tsFile', fullfile(folderName, [baseName '_timestamps.mat']), ...
                        'fpsNominal', fpsNominal, 'exposure_us', exposure_us, ...
                        'pixFormat', pixFormat, 'bayerPattern', 'rggb', ...
                        'deviceName', devName, 'resolution', res);
            vid.UserData = ud;
            vid.FramesAcquiredFcnCount = 50;       % ~10 writes per second
            vid.FramesAcquiredFcn = @(obj, ~) writePendingFrames(obj);

            preview(vid); start(vid);
            fprintf('Starting Hikrobot recording... ');
            tStart = tic;
            while ~islogging(vid) && toc(tStart) < 5, pause(0.05); end
            if ~isempty(vid.InitialTriggerTime)
                actualStartTime = datetime(vid.InitialTriggerTime);  % true acquisition start
            else
                actualStartTime = datetime('now');
            end
            if islogging(vid), fprintf('active.\n'); else, warning('Hikrobot: start timeout.'); end

            out.vid = vid;
            out.recordStartTime = actualStartTime;

        case 'save'
            vidObj = varargin{1};
            fprintf('Hikrobot: stopping... ');
            frameCount = 0; stopTime = datetime('now');
            out.MeasuredFps = NaN; out.DroppedFrames = NaN; out.TimestampFile = '';
            if isvalid(vidObj)
                if isrunning(vidObj), stop(vidObj); end
                stopTime = datetime('now');          % wall clock at stop
                stoppreview(vidObj);
                vidObj.FramesAcquiredFcn = '';
                while vidObj.FramesAvailable > 0     % write what is still in memory
                    writePendingFrames(vidObj);
                end
                ud = vidObj.UserData;
                close(ud.writer);
                frameCount = ud.nWritten;

                % per-frame timestamps for exact sync in 'extract'
                Timestamps.TriggerTime   = datetime(vidObj.InitialTriggerTime);
                Timestamps.FrameTimes_s  = ud.t;    % seconds after TriggerTime
                Timestamps.FpsNominal    = ud.fpsNominal;
                Timestamps.Exposure_us   = ud.exposure_us;
                Timestamps.PixelFormat   = ud.pixFormat;
                Timestamps.BayerPattern  = ud.bayerPattern;
                Timestamps.DeviceName    = ud.deviceName;
                Timestamps.Resolution    = ud.resolution;
                [Timestamps.MeasuredFps, Timestamps.DroppedFrames] = ...
                    frameStats(ud.t, ud.fpsNominal);
                save(ud.tsFile, 'Timestamps');

                out.MeasuredFps   = Timestamps.MeasuredFps;
                out.DroppedFrames = Timestamps.DroppedFrames;
                out.TimestampFile = ud.tsFile;
                delete(vidObj);
            end
            pause(1.0);
            out.StopTime   = stopTime;
            out.FrameCount = frameCount;
            fprintf('done (%d frames, %.1f fps measured, ~%d dropped).\n', ...
                    frameCount, out.MeasuredFps, out.DroppedFrames);

        case 'extract'
            videoName = varargin{1};
            Messdata  = varargin{2};

            folderName = 'Testergebnisse';
            videoPath  = fullfile(folderName, videoName);
            if ~exist(videoPath, 'file'), error('Video not found: %s', videoPath); end
            if ~isfield(Messdata, 'VideoStartTime') || ~isfield(Messdata, 'PulseLog')
                error('Messdata missing VideoStartTime / PulseLog. Cannot sync.');
            end

            vObj = VideoReader(videoPath);
            PulseLog = Messdata.PulseLog;
            [~, baseName] = fileparts(videoName);
            tsFile = fullfile(folderName, [baseName '_timestamps.mat']);

            % Preferred: per-frame timestamps (robust against dropped frames
            % and frame rate jitter). Fallback: average frame rate like v5.
            useTs = exist(tsFile, 'file') == 2;
            bayerPattern = 'rggb';
            if useTs
                S = load(tsFile, 'Timestamps'); TS = S.Timestamps;
                bayerPattern = TS.BayerPattern;
                % Arduino zero expressed in seconds after the first trigger
                offsetToVideo_s = seconds(PulseLog.ZeroWallClock - TS.TriggerTime);
                frameTimes = TS.FrameTimes_s(:);
                fprintf('Sync via per-frame timestamps (%.1f fps measured).\n', TS.MeasuredFps);
            else
                if isfield(Messdata,'VideoStopTime') && isfield(Messdata,'VideoFrameCount') ...
                        && Messdata.VideoFrameCount > 1
                    recDuration = seconds(Messdata.VideoStopTime - Messdata.VideoStartTime);
                    fpsEff = Messdata.VideoFrameCount / recDuration;
                else
                    fpsEff = vObj.NumFrames / vObj.Duration;   % file is tagged with the real fps
                end
                offsetToVideo_s = seconds(PulseLog.ZeroWallClock - Messdata.VideoStartTime);
                fprintf('No timestamp file, using average frame rate: %.2f fps\n', fpsEff);
            end

            outputDir = fullfile(folderName, ['Frames_' baseName]);
            if ~exist(outputDir, 'dir'), mkdir(outputDir); end
            canDemosaic = exist('demosaic', 'file') == 2;
            if ~canDemosaic
                warning('demosaic (Image Processing Toolbox) missing: saving raw Bayer frames.');
            end

            tOff = PulseLog.PulseOff_s;      % one frame per pulse OFF
            for k = 1:numel(tOff)
                if isnan(tOff(k)), continue; end
                videoTime_s = offsetToVideo_s + tOff(k);
                if useTs
                    [~, targetFrame] = min(abs(frameTimes - videoTime_s));
                else
                    targetFrame = round(videoTime_s * fpsEff);
                end
                targetFrame = min(max(targetFrame, 1), vObj.NumFrames);
                try
                    img = read(vObj, targetFrame);
                    if size(img, 3) == 3, img = img(:,:,1); end   % grayscale AVI may read as RGB
                    if canDemosaic, img = demosaic(img, bayerPattern); end
                    imwrite(img, fullfile(outputDir, sprintf('Pulse_%02d_Off_t%.3fs.png', k, tOff(k))));
                    fprintf('  Pulse %d off @ %.3fs -> frame %d\n', k, tOff(k), targetFrame);
                catch
                    warning('Frame %d read failed.', targetFrame);
                end
            end
            fprintf('Extraction complete.\n');
    end
end

% ---------------------------------------------------------------------------
function writePendingFrames(vid)
% Move all frames waiting in memory into the AVI and keep their timestamps.
    n = vid.FramesAvailable;
    if n == 0, return; end
    [frames, t] = getdata(vid, n);           % frames: H x W x 1 x n uint8 (Bayer)
    ud = vid.UserData;
    writeVideo(ud.writer, frames);
    ud.t = [ud.t; t(:)];
    ud.nWritten = ud.nWritten + n;
    vid.UserData = ud;
end

function [fpsMeas, nDropped] = frameStats(t, fpsNominal)
% Measured frame rate and estimated number of missing frames (gaps in t).
    fpsMeas = NaN; nDropped = 0;
    if numel(t) < 2, return; end
    fpsMeas = (numel(t) - 1) / (t(end) - t(1));
    if isnan(fpsNominal), fpsNominal = fpsMeas; end
    gaps = round(diff(t) * fpsNominal) - 1;
    nDropped = sum(gaps(gaps > 0));
end

function trySet(src, name, value)
% Set a GenICam feature if the camera exposes it; warn instead of failing.
    if ~isprop(src, name), return; end
    try
        src.(name) = value;
    catch ME
        if ischar(value) && any(strcmpi(value, {'True','False'}))
            try, src.(name) = strcmpi(value, 'True'); return; catch, end  %#ok<NOCOM>
        end
        warning('Could not set %s: %s', name, ME.message);
    end
end
