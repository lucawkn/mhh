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
% Camera settings (data sheet): 720 x 540, 526.5 fps max (8-bit ADC).
% Recording format: Mono8 (grayscale, computed in the camera) in an
% uncompressed 8-bit 'Grayscale AVI' (~205 MB/s at full speed, about
% 12 GB per minute -> use an SSD).
% Colour is not recorded: with BayerRG8 the gentl adaptor converts every
% frame to RGB (3 bytes/pixel, ~615 MB/s), which the disk cannot sustain,
% and Motion JPEG cannot be encoded in real time at 526 fps.
%
% Requirements (Windows):
%  - Hikrobot MVS installed (provides the USB3 Vision GenTL producer
%    MvProducerU3V.cti and sets GENICAM_GENTL64_PATH)
%  - Image Acquisition Toolbox + "Image Acquisition Toolbox Support Package
%    for GenICam Interface" (adaptor 'gentl')
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
            pixFormat = 'Mono8';                   % 1 byte/pixel -> full 527 fps to disk
            % Adaptor name: 'gentl' normally, 'mwgentlimaq' if the adaptor was
            % registered by hand with imaqregister(...\mwgentlimaq.dll).
            hw = imaqhwinfo; adaptors = hw.InstalledAdaptors;
            adaptor  = '';
            if any(strcmpi(adaptors, 'gentl'))
                adaptor = 'gentl';
            elseif any(contains(adaptors, 'gentl', 'IgnoreCase', true))
                adaptor = adaptors{find(contains(adaptors, 'gentl', 'IgnoreCase', true), 1)};
            end
            if isempty(adaptor)
                error(['GenTL adaptor not available. Install the "Image Acquisition Toolbox ' ...
                       'Support Package for GenICam Interface" or register it with ' ...
                       'imaqregister(''...\\gentl\\adaptor\\win64\\mwgentlimaq.dll'').']);
            end
            info = imaqhwinfo(adaptor);
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
                error(['Hikrobot %s not found among GenTL devices. Check USB3 cable, ' ...
                       'close MVS, check imaqsupport for the MVS producer.'], camName);
            end
            aviProfile = 'Grayscale AVI';
            if ~any(strcmpi(fmts, pixFormat))
                % fallback: colour, delivered as RGB by the adaptor (3x data rate)
                warning(['Mono8 not offered (formats: %s). Falling back to BayerRG8 -> RGB ' ...
                         '(~615 MB/s at full speed, frames will likely be lost).'], strjoin(fmts, ', '));
                pixFormat  = 'BayerRG8';
                aviProfile = 'Uncompressed AVI';
            end
            fprintf('(using %s DeviceID %d: %s, %s) ', adaptor, devID, devName, pixFormat);

            vid = videoinput(adaptor, devID, pixFormat);
            res = vid.VideoResolution;             % max resolution 720 x 540
            vid.ROIPosition = [0 0 res];
            triggerconfig(vid, 'immediate');
            % Disk logging runs inside the toolbox, outside the MATLAB main loop, so
            % the experiment script keeps running. 'memory' is used in parallel only
            % to read the per-frame timestamps (the frames are thrown away).
            vid.LoggingMode       = 'disk&memory';
            vid.FramesPerTrigger  = Inf;
            vid.FrameGrabInterval = 1;             % keep every frame

            % ---- camera features (GenICam SFNC names, Hikrobot MVS) ----------
            src = getselectedsource(vid);
            trySet(src, 'TriggerMode', 'Off');                  % free run
            trySet(src, 'BinningHorizontal', 1);  trySet(src, 'BinningVertical', 1);
            trySet(src, 'DecimationHorizontal', 1); trySet(src, 'DecimationVertical', 1);
            trySet(src, 'DeviceLinkThroughputLimitMode', 'Off'); % no USB bandwidth cap
            trySet(src, 'ADCBitDepth', 'Bits_8');                % 12-bit ADC caps the sensor at ~323 fps
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
            writer = VideoWriter(fullfile(folderName, [baseName '.avi']), aviProfile);
            if ~isnan(fpsNominal), writer.FrameRate = fpsNominal; end   % correct playback speed
            vid.DiskLogger = writer;               % the toolbox opens and closes it

            ud = struct('t', zeros(0,1), ...
                        'tsFile', fullfile(folderName, [baseName '_timestamps.mat']), ...
                        'fpsNominal', fpsNominal, 'exposure_us', exposure_us, ...
                        'pixFormat', pixFormat, ...
                        'deviceName', devName, 'resolution', res);
            vid.UserData = ud;
            vid.FramesAcquiredFcnCount = 100;      % ~5 short callbacks per second
            vid.FramesAcquiredFcn = @(obj, ~) collectTimestamps(obj);

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
                while vidObj.FramesAvailable > 0     % timestamps still in memory
                    collectTimestamps(vidObj);
                end
                % wait until the disk logger has written every acquired frame
                nAcq = vidObj.FramesAcquired; tWait = tic;
                while vidObj.DiskLoggerFrameCount < nAcq && toc(tWait) < 120
                    pause(0.2);
                end
                frameCount = vidObj.DiskLoggerFrameCount;
                if frameCount < nAcq
                    warning('Only %d of %d frames reached the AVI.', frameCount, nAcq);
                end
                ud = vidObj.UserData;
                if numel(ud.t) ~= frameCount
                    warning('%d timestamps for %d frames: frame sync may be off.', numel(ud.t), frameCount);
                end

                % per-frame timestamps for exact sync in 'extract'
                Timestamps.TriggerTime   = datetime(vidObj.InitialTriggerTime);
                Timestamps.FrameTimes_s  = ud.t;    % seconds after TriggerTime
                Timestamps.FpsNominal    = ud.fpsNominal;
                Timestamps.Exposure_us   = ud.exposure_us;
                Timestamps.PixelFormat   = ud.pixFormat;
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
            if useTs
                S = load(tsFile, 'Timestamps'); TS = S.Timestamps;
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
function collectTimestamps(vid)
% Take the frames out of the memory buffer (the disk logger writes them to
% the AVI on its own) and keep only their timestamps. Keeps RAM usage flat.
    n = vid.FramesAvailable;
    if n == 0, return; end
    [~, t] = getdata(vid, n);
    ud = vid.UserData;
    ud.t = [ud.t; t(:)];
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
        if isnumeric(value)                  % enum feature: pick the option with that number
            pinfo = propinfo(src, name); opts = pinfo.ConstraintValue;
            if iscell(opts)
                hit = opts(~cellfun(@isempty, regexp(opts, ['(^|\D)' num2str(value) '($|\D)'])));
                if ~isempty(hit)
                    try, src.(name) = hit{1}; return; catch, end  %#ok<NOCOM>
                end
                warning('Could not set %s = %g (options: %s)', name, value, strjoin(opts, ' | '));
                return;
            end
        end
        warning('Could not set %s: %s', name, ME.message);
    end
end
