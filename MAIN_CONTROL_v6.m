%% MAIN CONTROL v6: Bestromung von aktiven Funktionsmustern (FM)
% v6: PicoScope 4444 replaces the Tektronix TPS2014.
%     - PicoScope record window derived from the protocol parameters
%     - electrical analysis with process_Pico_v6 (current, power, resistance, energy)
%     - plots with plot_ExperimentResults_v6 (t = 0 at the first current onset)
if exist('hPico', 'var')
    try
        manage_Pico_v6('close', hPico);
    catch
    end
end

clc; clear; close all;

%% --- 1. USER PARAMETERS ---
arduinoPort       = 'COM9';
numActiveChannels = 5;                 % TC-08 channels
tcType            = 'T';

% --- Run mode: pick ONE ---
runMode = "classic";                   % "classic" | "pwm" | "ramp"

% --- Hardware toggles ---
useTC08   = false;
useCamera = true;                      % enable after the first PicoScope test
usePico   = false;

% --- Post-processing toggles ---
saveData      = true;                  % PicoScope data is lost if not saved
usePlotting   = true;
extractFrames = false;

% --- Pulse settings (classic / pwm): arrays hold ONE value PER SET ---
NumSets        = 3;
PulseCounts    = [3 3 3];
PulseDurations = [30 30 30];           % ms
Pauses         = [15 15 15];           % ms
SetGaps        = [500 500];            % ms, NumSets-1 values
DutyCycles     = [100 100 100];
Voltages       = [3.0 3.0 3.0];        % one value per set
Currents       = [2 2 2];              % one value per set
Powers         = Voltages .* Currents; % nominal only; actual power comes from the PicoScope

% --- Ramp settings (ramp only) ---
ramp_trigDur_ms    = 500;              % full-power trigger pulse
ramp_rampDur_ms    = 10000;            % ramp duration
ramp_dutyStart_pct = 70;
ramp_dutyEnd_pct   = 90;

% --- Phase durations [s] ---
preMeas_s  = 5;                        % wait before the protocol starts
postMeas_s = 5;                        % wait after the protocol ends

% --- Camera window (Hikrobot, ~615 MB/s into RAM): records only around the pulses ---
camPre_s  = 0.3;                         % camera starts this long before the protocol
camPost_s = 0.3;                         % camera keeps running this long after the last pulse
% -> video length = camPre_s + protocol + margin + camPost_s (fixed frame count, see 1b)

% --- PicoScope ---
pico.channels     = [0 1];             % 0=A, 1=B, 2=C, 3=D
pico.names        = {'V_FM', 'V_shunt'};
pico.ranges       = [8 5];             % 8 = ±5 V (FM voltage), 5 = ±500 mV (shunt)
pico.coupling     = 1;                 % DC
pico.resolution   = 14;                % bits
pico.trigCh       = 0;                 % trigger on the FM voltage (channel B)
pico.trigLevel    = 300;               % mV, rising edge of the first pulse
pico.trigDir      = 2;                 % rising
pico.useBwLimit   = true;              % 1 MHz (short) / 100 kHz (long)
pico.shortLimit_s = 10;                % record < 10 s -> short mode (1 us output)
pico.pre_s        = 1.0;               % recorded before the trigger
pico.post_s       = 1.0;               % recorded after the last pulse
pico.shunt_Ohm    = 0.1;               % shunt resistor

fileName = ['TEST-KP-MV71-11-30-15-3-2.4 ', char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))];

%% --- 1b. PROTOCOL DURATION AND PICOSCOPE RECORD WINDOW ---
prm = struct('NumSets', NumSets, 'PulseCounts', PulseCounts, ...
    'PulseDurations', PulseDurations, 'Pauses', Pauses, 'SetGaps', SetGaps, ...
    'DutyCycles', DutyCycles, 'ramp_trigDur_ms', ramp_trigDur_ms, ...
    'ramp_rampDur_ms', ramp_rampDur_ms);
act_s    = calc_ProtocolDuration_v6(runMode, prm);       % also validates the arrays
margin_s = 0.05 + 0.02 * act_s;                           % Arduino overhead, clock tolerance
total_s  = pico.pre_s + act_s + margin_s + pico.post_s;
fprintf('Protocol: %.3f s activation | PicoScope record: %.3f s\n', act_s, total_s);
camDuration_s = camPre_s + act_s + margin_s + camPost_s;   % fixed video length
if useCamera
    fprintf('Camera: %.2f s video (%.1f s before, %.1f s after the protocol)\n', ...
            camDuration_s, camPre_s, camPost_s);
end

if runMode == "pwm" && any(Pauses(PulseCounts > 1) <= 3)
    warning('PWM pauses <= 3 ms cannot be separated from PWM off-phases in the analysis.');
end
if useCamera && (camPre_s > preMeas_s || camPost_s > postMeas_s)
    error('camPre_s / camPost_s must not exceed preMeas_s / postMeas_s.');
end
if usePico && preMeas_s < pico.pre_s + 0.1
    error('preMeas_s must exceed pico.pre_s so the pre-trigger buffer can fill.');
end

%% --- 2. HARDWARE INITIALIZATION ---
fprintf('--- Initializing Hardware ---\n');

sObj = [];
vidStruct = [];
hPico = [];
hTC08 = [];
GlobalStartTime = datetime('now');

try
    % Step 1/4: Arduino
    fprintf('Step 1/4: Opening Arduino... ');

    if ~isempty(sObj)
        try
            if isvalid(sObj)
                delete(sObj);
            end
        catch
        end
        clear sObj
    end

    sObj = serialport(arduinoPort, 115200);
    sObj.Timeout = 30;
    configureTerminator(sObj, "LF");
    flush(sObj);

    readyFound = false;
    tStart = tic;
    fprintf('Waiting for READY... ');
    while toc(tStart) < 5
        if sObj.NumBytesAvailable > 0
            msg = strtrim(readline(sObj));
            fprintf('Arduino says: %s\n', msg);
            if contains(msg, "READY")
                readyFound = true;
                break;
            end
        end
        pause(0.05);
    end

    if ~readyFound
        error('Arduino not READY');
    end
    fprintf('OK.\n');

    % Step 2/4: Hikrobot camera (configured now, recording starts in Phase 1)
    if useCamera
        fprintf('Step 2/4: Preparing Hikrobot camera... ');
        vidStruct = manage_HikrobotVideo('init', [fileName, '_video.avi'], [], false);
        fprintf('OK.\n');
    else
        fprintf('Step 2/4: Camera disabled by user.\n');
    end

    % Step 3/4: PicoScope (connect and configure; armed at the start of Phase 1)
    if usePico
        fprintf('Step 3/4: Connecting to PicoScope...\n');
        hPico = manage_Pico_v6('connect');
        % set(hPico, 'displayOutput', 0);
        Ppico = manage_Pico_v6('config', hPico, pico, total_s, pico.pre_s);
    else
        fprintf('Step 3/4: PicoScope disabled by user.\n');
    end

    % Step 4/4: TC-08
    if useTC08
        fprintf('Step 4/4: Connecting & Starting TC-08... ');
        [hTC08, GlobalStartTime] = collect_TC08_data_v5('start', numActiveChannels, tcType);
        fprintf('OK.\n');
    else
        fprintf('Step 4/4: TC-08 disabled by user.\n');
        GlobalStartTime = datetime('now');
    end

    %% --- 3. SYNCHRONIZED EXECUTION ---
    disp('--- EXPERIMENT RUNNING ---');

    % --- Phase 1: Pre-measurement (PicoScope armed first: pre-trigger buffer fills) ---
    if usePico
        Ppico = manage_Pico_v6('arm', hPico, Ppico);
    end
    fprintf('Phase 1/3: Pre-measurement (%d s)\n', preMeas_s);
    tPhase1 = tic;
    camLead_s = 0;
    if useCamera, camLead_s = camPre_s; end
    lastSec = -1;
    while toc(tPhase1) < preMeas_s - camLead_s
        if floor(toc(tPhase1)) > lastSec
            lastSec = floor(toc(tPhase1));
            fprintf('  %d s remaining (elapsed %.1f s)\n', ceil(preMeas_s - toc(tPhase1)), toc(tPhase1));
        end
        drawnow;
        pause(0.05);
    end
    if useCamera                       % camera runs only from here on, for camDuration_s
        vidStruct.recordStartTime = manage_HikrobotVideo('start', vidStruct.vid, camDuration_s);
        % send the protocol camPre_s after the REAL camera start (start() itself takes time)
        while toc(tPhase1) < preMeas_s || datetime('now') < vidStruct.recordStartTime + seconds(camPre_s)
            pause(0.005);
        end
    end
    fprintf('Phase 1 done after %.1f s.\n', toc(tPhase1));

    % --- Phase 2: Execute the selected protocol ---
    fprintf('Phase 2/3: Executing (mode = %s)...\n', runMode);
    switch runMode
        case "pwm"
            arduinoCmd = generate_PWM_Cmd_v5(NumSets, PulseCounts, PulseDurations, Pauses, SetGaps, DutyCycles);
        case "ramp"
            arduinoCmd = generate_Ramp_Cmd_v5(ramp_trigDur_ms, ramp_rampDur_ms, ramp_dutyStart_pct, ramp_dutyEnd_pct);
        otherwise   % "classic"
            arduinoCmd = generate_Arduino_Cmd_v5(NumSets, PulseCounts, PulseDurations, Pauses, SetGaps);
    end

    pulseStartSysTime = datetime('now');

    if isempty(sObj) || ~isvalid(sObj)
        error('sObj ist nicht initialisiert. Step 1/4 ist fehlgeschlagen.');
    end

    fprintf('Sending command: %s\n', arduinoCmd);
    writeline(sObj, arduinoCmd);
    fprintf('Command sent\n');

    PulseLog = [];   % stays empty in ramp mode
    RampLog  = [];   % stays empty in pulse modes

    if runMode == "ramp"
        fprintf('Collecting ramp results...\n');
        [RampLog, status] = collect_Ramp_Results_v5(sObj, ramp_trigDur_ms, ramp_rampDur_ms, ...
                                                    ramp_dutyStart_pct, ramp_dutyEnd_pct);
        fprintf('Collect returned\n');
    else
        fprintf('Collecting Arduino results...\n');
        [PulseLog, status] = collect_Arduino_Results_v5(sObj, NumSets, PulseCounts, Powers, Pauses);
        fprintf('Collect returned\n');
    end

    pulseEndSysTime = datetime('now');
    fprintf('Sequence completed (status = %d).\n', status);

    % --- Phase 3: Post-measurement ---
    fprintf('Phase 3/3: Post-measurement (%d s)\n', postMeas_s);
    tPhase3 = tic;
    if useCamera                       % camera stops by itself after camDuration_s;
        sv = manage_HikrobotVideo('save', vidStruct.vid);   % wait, write to C:, copy to M:
    end
    while toc(tPhase3) < postMeas_s
        pause(0.1);
    end
    fprintf('Phase 3 done after %.1f s.\n', toc(tPhase3));

    %% --- 4. CLEANUP & SAVING ---
    disp('--- CLEANUP & SAVING ---');
    Messdata = struct();

    % 1. Camera footage
    if useCamera                       % saved at the start of Phase 3
        Messdata.VideoStartTime  = vidStruct.recordStartTime;
        Messdata.VideoStopTime   = sv.StopTime;
        Messdata.VideoFrameCount = sv.FrameCount;
    end

    % 2. TC-08 data
    if useTC08
        [Messdata_TC08, ~] = collect_TC08_data_v5('stop', hTC08, numActiveChannels);
        Messdata.Time        = Messdata_TC08.Time;
        Messdata.Channels    = Messdata_TC08.Channels;
        Messdata.Average     = Messdata_TC08.Average;
        Messdata.Unit        = Messdata_TC08.Unit;
        Messdata.MinInterval = Messdata_TC08.MinInterval;
    end

    % 3. PicoScope data (read waits until the capture is complete) + analysis
    if usePico
        Dpico = manage_Pico_v6('read', hPico, Ppico, total_s + 10);
        Dpico.shunt_Ohm = pico.shunt_Ohm;
        manage_Pico_v6('close', hPico);
        clear hPico;
        Messdata.Pico = Dpico;                              % raw waveforms

        if Dpico.ok
            procOpts = struct('shunt_Ohm', pico.shunt_Ohm, 'keepSignals', false);
            if runMode == "classic"
                procOpts.mergeGap_s = 0.1e-3;               % no chopping: bridge single-sample dips
            else
                procOpts.mergeGap_s = 3e-3;                 % bridge PWM off-phases (~2.04 ms period)
            end
            if runMode ~= "ramp"
                procOpts.PulseLog = PulseLog;
            end
            Messdata.PicoResults = process_Pico_v6(Dpico, procOpts);
            if isfield(Messdata.PicoResults, 'arduinoCheck')
                disp(Messdata.PicoResults.arduinoCheck);
            end
        end
    end

    % 4. Basic parameters + timeline metadata
    if saveData || usePlotting || extractFrames
        Messdata.RunMode           = runMode;
        Messdata.GlobalStartTime   = GlobalStartTime;
        Messdata.PulseStartSysTime = pulseStartSysTime;
        Messdata.PulseEndSysTime   = pulseEndSysTime;

        if runMode == "ramp"
            Messdata.RampLog = RampLog;
            if ~isempty(RampLog) && isfield(RampLog, 'ZeroWallClock')
                zeroWC = RampLog.ZeroWallClock;
            else
                zeroWC = pulseStartSysTime;      % fallback
            end
        else
            Messdata.PulseLog = PulseLog;
            if ~isempty(PulseLog) && isfield(PulseLog, 'ZeroWallClock')
                zeroWC = PulseLog.ZeroWallClock;
            else
                zeroWC = pulseStartSysTime;      % fallback
            end
        end

        % Sync metadata (PC wall clock); PicoScope t = 0 is its trigger sample
        Messdata.Sync.ArduinoZeroWallClock = zeroWC;
        if useCamera
            Messdata.Sync.VideoTimeOffset_s = seconds(zeroWC - Messdata.VideoStartTime);
        end
        if useTC08
            Messdata.Sync.TC08TimeOffset_s = seconds(GlobalStartTime - zeroWC);
        end
        if usePico
            Messdata.Sync.PicoArmTime = Ppico.armTime;
        end

        % Settings block
        Messdata.Settings.Timestamp        = datetime('now');
        Messdata.Settings.fileName         = fileName;
        Messdata.Settings.ThermocoupleType = tcType;
        Messdata.Settings.Pico             = pico;
        Messdata.Settings.Window = struct('pre_s', pico.pre_s, 'activation_s', act_s, ...
            'margin_s', margin_s, 'post_s', pico.post_s, 'total_s', total_s);
        if runMode == "ramp"
            Messdata.Settings.Ramp = struct( ...
                'trigDur_ms', ramp_trigDur_ms, 'rampDur_ms', ramp_rampDur_ms, ...
                'dutyStart_pct', ramp_dutyStart_pct, 'dutyEnd_pct', ramp_dutyEnd_pct);
        else
            Messdata.Settings.NumSets        = NumSets;
            Messdata.Settings.Voltages       = Voltages;
            Messdata.Settings.Currents       = Currents;
            Messdata.Settings.Powers         = Powers;   % nominal (supply settings)
            Messdata.Settings.PulseCounts    = PulseCounts;
            Messdata.Settings.PulseDurations = PulseDurations;
            if runMode == "pwm"
                Messdata.Settings.DutyCycles = DutyCycles;
            end
            Messdata.Settings.Pauses         = Pauses;
            Messdata.Settings.SetGaps        = SetGaps;
        end
    end

    % 5. Plot
    if usePlotting
        if usePico && isfield(Messdata, 'PicoResults') && Messdata.PicoResults.ok
            plot_ExperimentResults_v6(Messdata, Messdata.PicoResults);
        else
            fprintf('Plotting skipped: no processed PicoScope data.\n');
        end
    else
        fprintf('Plotting disabled by user.\n');
    end

    % 6. Save + extract frames
    if saveData
        if ~exist('Testergebnisse', 'dir')
            mkdir('Testergebnisse');
        end
        savePath = fullfile('Testergebnisse', [fileName, '.mat']);
        save(savePath, 'Messdata', '-v7.3');
        fprintf('Data saved to: %s\n', savePath);
    else
        fprintf('Data saving disabled by user.\n');
    end

    if extractFrames
        if useCamera
            fprintf('Starting auto-extraction of frames...\n');
            manage_HikrobotVideo('extract', [fileName, '_video.avi'], Messdata);
        else
            fprintf('Frame extraction skipped: Camera was disabled.\n');
        end
    else
        fprintf('Frame extraction disabled by user.\n');
    end

catch ME
    % Full cleanup so no COM port, USB device or DLL is left locked on error.
    if exist('sObj', 'var') && ~isempty(sObj)
        try
            if isvalid(sObj)
                delete(sObj);
            end
        catch
        end
    end

    if exist('hPico', 'var') && ~isempty(hPico)
        try
            manage_Pico_v6('close', hPico);
        catch
        end
    end

    if exist('hTC08', 'var') && ~isempty(hTC08) && hTC08 > 0
        try
            calllib('usbtc08', 'usb_tc08_stop', hTC08);
            calllib('usbtc08', 'usb_tc08_close_unit', hTC08);
        catch
        end
    end

    if libisloaded('usbtc08')
        unloadlibrary('usbtc08');
    end

    imaqreset;
    fprintf('\nERROR OCCURRED: %s\n', ME.message);
    rethrow(ME);
end

disp('--- ALL EXPERIMENT PHASES COMPLETED ---');
