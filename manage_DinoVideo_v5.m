function out = manage_DinoVideo_v5(cmd, varargin)
% MANAGE_DINOVIDEO_V5
%  init:    start disk recording, return start wall-clock time
%  save:    stop recording, return actual stop time + final frame count
%  extract: pull one frame per pulse OFF, using the true (measured) frame rate
%           and the Arduino master timeline.

    out = [];
    switch lower(cmd)
        case 'init'
            finalFileName = varargin{1};
            imaqreset; pause(1.5);
        
            % Find the Dino-Lite by name, not by a hard-coded DeviceID: the winvideo
            % enumeration order is not stable (it can swap with the built-in webcam
            % across replug/reboot), so a fixed ID may silently select the wrong camera.
            camName = 'Dino-Lite';                     % substring match, case-insensitive
            info = imaqhwinfo('winvideo');
            devID = [];
            for k = 1:numel(info.DeviceIDs)
                if contains(info.DeviceInfo(k).DeviceName, camName, 'IgnoreCase', true)
                    devID = info.DeviceIDs{k};
                    break;
                end
            end
            if isempty(devID)
                error('Dino-Lite not found among winvideo devices. Check USB / close DinoCapture.');
            end
            fprintf('(using DeviceID %d: %s) ', devID, info.DeviceInfo(k).DeviceName);
        
            vid = videoinput('winvideo', devID, 'MJPG_640x480');
            triggerconfig(vid, 'immediate');
            vid.LoggingMode      = 'disk';
            vid.FrameGrabInterval = 1;          % ~15 fps to save disk space
            vid.FramesPerTrigger  = 100000;

            folderName = 'Testergebnisse';
            if ~exist(folderName, 'dir'), mkdir(folderName); end
            vid.DiskLogger = VideoWriter(fullfile(folderName, finalFileName), 'Motion JPEG AVI');

            preview(vid); start(vid);
            fprintf('Starting Dino-Lite recording... ');
            tStart = tic;
            while ~islogging(vid) && toc(tStart) < 5, pause(0.1); end
            actualStartTime = datetime('now');
            if islogging(vid), fprintf('active.\n'); else, warning('Dino-Lite: start timeout.'); end

            out.vid = vid;
            out.recordStartTime = actualStartTime;

        case 'save'
            vidObj = varargin{1};
            fprintf('Dino-Lite: stopping... ');
            frameCount = 0; stopTime = datetime('now');
            if isvalid(vidObj)
                if isrunning(vidObj), stop(vidObj); end
                stopTime = datetime('now');          % wall clock at stop
                stoppreview(vidObj);
                while islogging(vidObj), pause(0.1); end
                frameCount = vidObj.DiskLoggerFrameCount;
                delete(vidObj);
            end
            pause(1.0);
            out.StopTime   = stopTime;
            out.FrameCount = frameCount;
            fprintf('done (%d frames).\n', frameCount);

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

            % True frame rate = total frames / actual recording time.
            % Do NOT trust vObj.FrameRate: VideoWriter tags the file 30 fps
            % regardless of FrameGrabInterval, which halves the real rate.
            if isfield(Messdata,'VideoStopTime') && isfield(Messdata,'VideoFrameCount') ...
                    && Messdata.VideoFrameCount > 1
                recDuration = seconds(Messdata.VideoStopTime - Messdata.VideoStartTime);
                fpsEff = Messdata.VideoFrameCount / recDuration;
            else
                fpsEff = vObj.NumFrames / vObj.Duration;      % fallback from the file
            end
            fprintf('Effective frame rate: %.2f fps\n', fpsEff);

            % Arduino time -> video time offset.
            PulseLog = Messdata.PulseLog;
            offsetToVideo_s = seconds(PulseLog.ZeroWallClock - Messdata.VideoStartTime);

            outputDir = fullfile(folderName, ['Frames_' erase(videoName, '.avi')]);
            if ~exist(outputDir, 'dir'), mkdir(outputDir); end

            tOff = PulseLog.PulseOff_s;      % one frame per pulse OFF
            for k = 1:numel(tOff)
                if isnan(tOff(k)), continue; end
                videoTime_s = offsetToVideo_s + tOff(k);
                targetFrame = round(videoTime_s * fpsEff);
                targetFrame = min(max(targetFrame, 1), vObj.NumFrames);
                try
                    img = read(vObj, targetFrame);
                    imwrite(img, fullfile(outputDir, sprintf('Pulse_%02d_Off_t%.2fs.jpg', k, tOff(k))));
                    fprintf('  Pulse %d off @ %.2fs -> frame %d\n', k, tOff(k), targetFrame);
                catch
                    warning('Frame %d read failed.', targetFrame);
                end
            end
            fprintf('Extraction complete.\n');
    end
end