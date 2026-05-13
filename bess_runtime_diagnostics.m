function varargout = bess_runtime_diagnostics(action, varargin)
% BESS_RUNTIME_DIAGNOSTICS
%
% Futas kozbeni BESS diagnosztika.
%
% Hasznalat a simulate_candidates_database.m napi ciklusaban:
%
%   diag = bess_runtime_diagnostics('init', data, DB, c, design, cfg);
%
%   diag = bess_runtime_diagnostics( ...
%       'update', diag, dayInput, dayResult, stateBefore, stateAfter, d, cfg);
%
%   diag = bess_runtime_diagnostics('finalize', diag, cfg);
%
% Cel:
%   - Nem evaluation-szintu vizsgalat.
%   - Nem uj szimulacios kornyezetet hoz letre.
%   - A tenyleges futas kozben gyujti az energiaaramlasokat.
%   - Kimutatja, hogy a BESS miert nem ciklizal:
%       1) nincs PV-tobblet,
%       2) van PV-tobblet, de nem tolt,
%       3) van grid import es nem ures BESS, de nem sut ki,
%       4) SoC beragad,
%       5) curtailment van ugy, hogy a BESS nincs tele,
%       6) grid import van ugy, hogy a BESS nincs uresen.

    action = lower(string(action));

    switch action

        case "init"
            data = varargin{1};
            DB = varargin{2};
            candidateIndex = varargin{3};
            design = varargin{4};
            cfg = varargin{5};

            varargout{1} = local_init(data, DB, candidateIndex, design, cfg);

        case "update"
            diag = varargin{1};
            dayInput = varargin{2};
            dayResult = varargin{3};
            stateBefore = varargin{4};
            stateAfter = varargin{5};
            dayIndex = varargin{6};
            cfg = varargin{7};

            varargout{1} = local_update( ...
                diag, ...
                dayInput, ...
                dayResult, ...
                stateBefore, ...
                stateAfter, ...
                dayIndex, ...
                cfg);

        case "finalize"
            diag = varargin{1};
            cfg = varargin{2};

            varargout{1} = local_finalize(diag, cfg);

        otherwise
            error('Unknown bess_runtime_diagnostics action: %s', action);
    end
end


% =========================================================================
% INIT
% =========================================================================
function diag = local_init(data, DB, candidateIndex, design, cfg)

    if ~isfield(cfg, 'diagnostics')
        error('cfg.diagnostics hianyzik.');
    end

    if ~isfield(cfg.diagnostics, 'outputFolder')
        error('cfg.diagnostics.outputFolder hianyzik.');
    end

    savePath = cfg.diagnostics.outputFolder;

    if ~isfolder(savePath)
        mkdir(savePath);
    end

    candidateSavePath = fullfile(savePath, sprintf('candidate_%d', candidateIndex));

    if ~isfolder(candidateSavePath)
        mkdir(candidateSavePath);
    end

    diag = struct();

    diag.candidateIndex = candidateIndex;
    diag.design = design;
    diag.savePath = candidateSavePath;

    diag.nDays = DB.nDays;
    diag.nT = DB.nT;
    diag.dt_h = DB.dt_h;

    if isfield(data, 'info')
        diag.dataInfo = data.info;
    else
        diag.dataInfo = struct();
    end

    diag.cfgSnapshot = cfg;

    % ---------------------------------------------------------------------
    % Idosoros tarolo
    % ---------------------------------------------------------------------
    diag.series = struct();

    diag.series.time_h = [];
    diag.series.dayIndex = [];
    diag.series.stepIndex = [];

    signalNames = local_signal_names();

    for i = 1:numel(signalNames)
        diag.series.(signalNames{i}) = [];
    end

    % ---------------------------------------------------------------------
    % Napi tarolo
    % ---------------------------------------------------------------------
    diag.daily = struct();

    diag.daily.dayIndex = [];
    diag.daily.date = NaT(0, 1);

    diag.daily.loadEnergy_kWh = [];
    diag.daily.pvAvailable_kWh = [];
    diag.daily.pvToLoad_kWh = [];
    diag.daily.pvToBess_kWh = [];
    diag.daily.bessToLoad_kWh = [];
    diag.daily.gridImport_kWh = [];
    diag.daily.gridExport_kWh = [];
    diag.daily.curtailment_kWh = [];

    diag.daily.chargeOpportunity_kWh = [];
    diag.daily.dischargeOpportunity_kWh = [];
    diag.daily.expectedChargeLimited_kWh = [];
    diag.daily.actualBessThroughput_kWh = [];
    diag.daily.actualEquivalentCycles = [];
    diag.daily.expectedEquivalentCycles = [];

    diag.daily.curtailmentWhileBessNotFull_kWh = [];
    diag.daily.gridImportWhileBessNotEmpty_kWh = [];

    diag.daily.socStart = [];
    diag.daily.socEnd = [];
    diag.daily.socMin = [];
    diag.daily.socMax = [];
    diag.daily.socRange = [];

    diag.daily.hoursAtSocMin = [];
    diag.daily.hoursAtSocMax = [];

    diag.daily.maxPvSurplusLike_kW = [];
    diag.daily.maxGridImport_kW = [];
    diag.daily.maxBessCharge_kW = [];
    diag.daily.maxBessDischarge_kW = [];

    fprintf('\nBESS runtime diagnostics initialized.\n');
    fprintf('Candidate index: %d\n', candidateIndex);
    fprintf('P_inv       = %.3f kW\n', local_get_design_value(design, 'P_inv_kW'));
    fprintf('P_PV        = %.3f kW\n', local_get_design_value(design, 'P_PV_kW'));
    fprintf('E_BESS      = %.3f kWh\n', local_get_design_value(design, 'E_BESS_kWh'));
    fprintf('P_BESS      = %.3f kW\n', local_get_design_value(design, 'P_BESS_kW'));
    fprintf('Output path = %s\n\n', candidateSavePath);
end


% =========================================================================
% UPDATE
% =========================================================================
function diag = local_update(diag, dayInput, dayResult, stateBefore, stateAfter, dayIndex, cfg)

    V = dayResult.dayVectors;

    dt_h = dayInput.dt_h;

    P_load = local_get_signal(V, 'P_load_kW', []);
    N = numel(P_load);

    if N == 0
        error('dayVectors.P_load_kW ures vagy hianyzik.');
    end

    % ---------------------------------------------------------------------
    % Signals
    % ---------------------------------------------------------------------
    signalNames = local_signal_names();

    tDay_h = (0:N-1)' * dt_h;
    tAbs_h = (dayIndex - 1) * 24 + tDay_h;

    diag.series.time_h = [diag.series.time_h; tAbs_h];
    diag.series.dayIndex = [diag.series.dayIndex; dayIndex * ones(N, 1)];
    diag.series.stepIndex = [diag.series.stepIndex; (1:N)'];

    for i = 1:numel(signalNames)

        name = signalNames{i};
        x = local_get_signal(V, name, N);

        diag.series.(name) = [diag.series.(name); x(:)];
    end

    % ---------------------------------------------------------------------
    % Required vectors
    % ---------------------------------------------------------------------
    P_pv = local_get_signal(V, 'P_pv_available_kW', N);
    P_pv_to_load = local_get_signal(V, 'P_pv_to_load_kW', N);
    P_pv_to_bess = local_get_signal(V, 'P_pv_to_bess_kW', N);
    P_bess_to_load = local_get_signal(V, 'P_bess_to_load_kW', N);
    P_grid_import = local_get_signal(V, 'P_grid_import_kW', N);
    P_grid_export = local_get_signal(V, 'P_grid_export_kW', N);
    P_curtailment = local_get_signal(V, 'P_curtailment_kW', N);
    SoC = local_get_signal(V, 'SoC', N);

    % Ha valamelyik nem letezik, legyen nulla, kiveve SoC.
    P_pv(isnan(P_pv)) = 0;
    P_pv_to_load(isnan(P_pv_to_load)) = 0;
    P_pv_to_bess(isnan(P_pv_to_bess)) = 0;
    P_bess_to_load(isnan(P_bess_to_load)) = 0;
    P_grid_import(isnan(P_grid_import)) = 0;
    P_grid_export(isnan(P_grid_export)) = 0;
    P_curtailment(isnan(P_curtailment)) = 0;

    % ---------------------------------------------------------------------
    % BESS SoC limits
    % ---------------------------------------------------------------------
    socMin = local_get_cfg_value(cfg, {'bess', 'SoC_min'});
    socMax = local_get_cfg_value(cfg, {'bess', 'SoC_max'});

    if isfield(cfg.diagnostics, 'socTolerance')
        socTol = cfg.diagnostics.socTolerance;
    else
        socTol = 0.02;
    end

    bessNotFull = SoC < (socMax - socTol);
    bessNotEmpty = SoC > (socMin + socTol);

    bessNotFull(isnan(bessNotFull)) = false;
    bessNotEmpty(isnan(bessNotEmpty)) = false;

    % ---------------------------------------------------------------------
    % Daily energies
    % ---------------------------------------------------------------------
    E_load = sum(P_load, 'omitnan') * dt_h;
    E_pv = sum(P_pv, 'omitnan') * dt_h;
    E_pv_to_load = sum(P_pv_to_load, 'omitnan') * dt_h;
    E_pv_to_bess = sum(P_pv_to_bess, 'omitnan') * dt_h;
    E_bess_to_load = sum(P_bess_to_load, 'omitnan') * dt_h;
    E_grid_import = sum(P_grid_import, 'omitnan') * dt_h;
    E_grid_export = sum(P_grid_export, 'omitnan') * dt_h;
    E_curtailment = sum(P_curtailment, 'omitnan') * dt_h;

    % ---------------------------------------------------------------------
    % Diagnostic opportunity metrics
    % ---------------------------------------------------------------------
    % Ez nem gazdasagi metric, hanem hibakeresesi metric:
    %
    % chargeOpportunity:
    %   amit az algoritmus az adott napon PV-tobbletkent vagy nem hasznositott
    %   PV-kent lat. Ha ez nagy, de P_pv_to_bess kicsi, akkor toltesi hiba.
    %
    % dischargeOpportunity:
    %   amit az algoritmus grid importkent vagy BESS kisuteskent lat.
    %   Ha ez nagy, es SoC > min, de P_bess_to_load kicsi, akkor kisutesi hiba.

    chargeOpportunity_kWh = sum(P_pv_to_bess + P_curtailment + P_grid_export, 'omitnan') * dt_h;
    dischargeOpportunity_kWh = sum(P_bess_to_load + P_grid_import, 'omitnan') * dt_h;

    E_BESS_kWh = local_get_design_value(diag.design, 'E_BESS_kWh');

    usableSocWindow = max(socMax - socMin, 0);

    E_BESS_usable_kWh = E_BESS_kWh * usableSocWindow;

    expectedChargeLimited_kWh = min([ ...
        chargeOpportunity_kWh, ...
        dischargeOpportunity_kWh, ...
        E_BESS_usable_kWh]);

    actualBessThroughput_kWh = E_pv_to_bess + E_bess_to_load;

    if E_BESS_kWh > 0
        actualEquivalentCycles = actualBessThroughput_kWh / (2 * E_BESS_kWh);
        expectedEquivalentCycles = expectedChargeLimited_kWh / E_BESS_kWh;
    else
        actualEquivalentCycles = 0;
        expectedEquivalentCycles = 0;
    end

    % ---------------------------------------------------------------------
    % Critical diagnostic contradictions
    % ---------------------------------------------------------------------
    curtailmentWhileBessNotFull_kWh = ...
        sum(P_curtailment(bessNotFull), 'omitnan') * dt_h;

    gridImportWhileBessNotEmpty_kWh = ...
        sum(P_grid_import(bessNotEmpty), 'omitnan') * dt_h;

    % ---------------------------------------------------------------------
    % SoC
    % ---------------------------------------------------------------------
    if all(isnan(SoC))
        socStart = NaN;
        socEnd = NaN;
        socMinDay = NaN;
        socMaxDay = NaN;
        socRange = NaN;
        hoursAtSocMin = NaN;
        hoursAtSocMax = NaN;
    else
        socStart = SoC(find(~isnan(SoC), 1, 'first'));
        socEnd = SoC(find(~isnan(SoC), 1, 'last'));
        socMinDay = min(SoC, [], 'omitnan');
        socMaxDay = max(SoC, [], 'omitnan');
        socRange = socMaxDay - socMinDay;

        hoursAtSocMin = sum(SoC <= socMin + socTol, 'omitnan') * dt_h;
        hoursAtSocMax = sum(SoC >= socMax - socTol, 'omitnan') * dt_h;
    end

    % ---------------------------------------------------------------------
    % Daily append
    % ---------------------------------------------------------------------
    diag.daily.dayIndex(end+1, 1) = dayIndex;

    if isfield(dayInput, 'date')
        diag.daily.date(end+1, 1) = dayInput.date;
    else
        diag.daily.date(end+1, 1) = NaT;
    end

    diag.daily.loadEnergy_kWh(end+1, 1) = E_load;
    diag.daily.pvAvailable_kWh(end+1, 1) = E_pv;
    diag.daily.pvToLoad_kWh(end+1, 1) = E_pv_to_load;
    diag.daily.pvToBess_kWh(end+1, 1) = E_pv_to_bess;
    diag.daily.bessToLoad_kWh(end+1, 1) = E_bess_to_load;
    diag.daily.gridImport_kWh(end+1, 1) = E_grid_import;
    diag.daily.gridExport_kWh(end+1, 1) = E_grid_export;
    diag.daily.curtailment_kWh(end+1, 1) = E_curtailment;

    diag.daily.chargeOpportunity_kWh(end+1, 1) = chargeOpportunity_kWh;
    diag.daily.dischargeOpportunity_kWh(end+1, 1) = dischargeOpportunity_kWh;
    diag.daily.expectedChargeLimited_kWh(end+1, 1) = expectedChargeLimited_kWh;
    diag.daily.actualBessThroughput_kWh(end+1, 1) = actualBessThroughput_kWh;
    diag.daily.actualEquivalentCycles(end+1, 1) = actualEquivalentCycles;
    diag.daily.expectedEquivalentCycles(end+1, 1) = expectedEquivalentCycles;

    diag.daily.curtailmentWhileBessNotFull_kWh(end+1, 1) = curtailmentWhileBessNotFull_kWh;
    diag.daily.gridImportWhileBessNotEmpty_kWh(end+1, 1) = gridImportWhileBessNotEmpty_kWh;

    diag.daily.socStart(end+1, 1) = socStart;
    diag.daily.socEnd(end+1, 1) = socEnd;
    diag.daily.socMin(end+1, 1) = socMinDay;
    diag.daily.socMax(end+1, 1) = socMaxDay;
    diag.daily.socRange(end+1, 1) = socRange;

    diag.daily.hoursAtSocMin(end+1, 1) = hoursAtSocMin;
    diag.daily.hoursAtSocMax(end+1, 1) = hoursAtSocMax;

    diag.daily.maxPvSurplusLike_kW(end+1, 1) = max(P_pv_to_bess + P_curtailment + P_grid_export, [], 'omitnan');
    diag.daily.maxGridImport_kW(end+1, 1) = max(P_grid_import, [], 'omitnan');
    diag.daily.maxBessCharge_kW(end+1, 1) = max(P_pv_to_bess, [], 'omitnan');
    diag.daily.maxBessDischarge_kW(end+1, 1) = max(P_bess_to_load, [], 'omitnan');

    % ---------------------------------------------------------------------
    % State check
    % ---------------------------------------------------------------------
    diag.lastStateBefore = stateBefore;
    diag.lastStateAfter = stateAfter;
end


% =========================================================================
% FINALIZE
% =========================================================================
function diag = local_finalize(diag, cfg)

    D = local_daily_table(diag);

    E_BESS_kWh = local_get_design_value(diag.design, 'E_BESS_kWh');

    nDays = height(D);
    simYears = nDays / 365.25;

    totalPvToBess_kWh = sum(D.pvToBess_kWh, 'omitnan');
    totalBessToLoad_kWh = sum(D.bessToLoad_kWh, 'omitnan');
    totalBessThroughput_kWh = totalPvToBess_kWh + totalBessToLoad_kWh;

    totalChargeOpportunity_kWh = sum(D.chargeOpportunity_kWh, 'omitnan');
    totalDischargeOpportunity_kWh = sum(D.dischargeOpportunity_kWh, 'omitnan');
    totalExpectedChargeLimited_kWh = sum(D.expectedChargeLimited_kWh, 'omitnan');

    totalCurtailmentWhileBessNotFull_kWh = ...
        sum(D.curtailmentWhileBessNotFull_kWh, 'omitnan');

    totalGridImportWhileBessNotEmpty_kWh = ...
        sum(D.gridImportWhileBessNotEmpty_kWh, 'omitnan');

    if E_BESS_kWh > 0
        totalActualCycles = totalBessThroughput_kWh / (2 * E_BESS_kWh);
        annualActualCycles = totalActualCycles / max(simYears, eps);

        totalExpectedCycles = totalExpectedChargeLimited_kWh / E_BESS_kWh;
        annualExpectedCycles = totalExpectedCycles / max(simYears, eps);
    else
        totalActualCycles = 0;
        annualActualCycles = 0;
        totalExpectedCycles = 0;
        annualExpectedCycles = 0;
    end

    chargeCaptureRatio = local_safe_divide(totalPvToBess_kWh, totalChargeOpportunity_kWh);
    dischargeCaptureRatio = local_safe_divide(totalBessToLoad_kWh, totalDischargeOpportunity_kWh);

    diag.summary = struct();

    diag.summary.nDays = nDays;
    diag.summary.simYears = simYears;

    diag.summary.totalPvToBess_kWh = totalPvToBess_kWh;
    diag.summary.totalBessToLoad_kWh = totalBessToLoad_kWh;
    diag.summary.totalBessThroughput_kWh = totalBessThroughput_kWh;

    diag.summary.totalChargeOpportunity_kWh = totalChargeOpportunity_kWh;
    diag.summary.totalDischargeOpportunity_kWh = totalDischargeOpportunity_kWh;
    diag.summary.totalExpectedChargeLimited_kWh = totalExpectedChargeLimited_kWh;

    diag.summary.totalActualCycles = totalActualCycles;
    diag.summary.annualActualCycles = annualActualCycles;
    diag.summary.totalExpectedCycles = totalExpectedCycles;
    diag.summary.annualExpectedCycles = annualExpectedCycles;

    diag.summary.chargeCaptureRatio = chargeCaptureRatio;
    diag.summary.dischargeCaptureRatio = dischargeCaptureRatio;

    diag.summary.totalCurtailmentWhileBessNotFull_kWh = totalCurtailmentWhileBessNotFull_kWh;
    diag.summary.totalGridImportWhileBessNotEmpty_kWh = totalGridImportWhileBessNotEmpty_kWh;

    diag.dailyTable = D;

    % ---------------------------------------------------------------------
    % Console report
    % ---------------------------------------------------------------------
    fprintf('\n============================================================\n');
    fprintf('BESS RUNTIME DIAGNOSTIC SUMMARY\n');
    fprintf('============================================================\n');

    fprintf('Candidate index: %d\n', diag.candidateIndex);
    fprintf('P_inv       = %.3f kW\n', local_get_design_value(diag.design, 'P_inv_kW'));
    fprintf('P_PV        = %.3f kW\n', local_get_design_value(diag.design, 'P_PV_kW'));
    fprintf('E_BESS      = %.3f kWh\n', local_get_design_value(diag.design, 'E_BESS_kWh'));
    fprintf('P_BESS      = %.3f kW\n', local_get_design_value(diag.design, 'P_BESS_kW'));

    fprintf('\nSimulation length:\n');
    fprintf('  Days      = %d\n', nDays);
    fprintf('  Years     = %.3f\n', simYears);

    fprintf('\nBESS energy use:\n');
    fprintf('  PV -> BESS total        = %.3f MWh\n', totalPvToBess_kWh / 1000);
    fprintf('  BESS -> load total      = %.3f MWh\n', totalBessToLoad_kWh / 1000);
    fprintf('  BESS throughput total   = %.3f MWh\n', totalBessThroughput_kWh / 1000);

    fprintf('\nCycle numbers:\n');
    fprintf('  Actual equivalent cycles total  = %.3f\n', totalActualCycles);
    fprintf('  Actual equivalent cycles / year = %.3f\n', annualActualCycles);
    fprintf('  Expected possible cycles / year = %.3f\n', annualExpectedCycles);

    fprintf('\nOpportunity capture:\n');
    fprintf('  Charge opportunity total     = %.3f MWh\n', totalChargeOpportunity_kWh / 1000);
    fprintf('  Discharge opportunity total  = %.3f MWh\n', totalDischargeOpportunity_kWh / 1000);
    fprintf('  Charge capture ratio         = %.3f %%\n', chargeCaptureRatio * 100);
    fprintf('  Discharge capture ratio      = %.3f %%\n', dischargeCaptureRatio * 100);

    fprintf('\nContradiction checks:\n');
    fprintf('  Curtailment while BESS not full = %.3f MWh\n', ...
        totalCurtailmentWhileBessNotFull_kWh / 1000);

    fprintf('  Grid import while BESS not empty = %.3f MWh\n', ...
        totalGridImportWhileBessNotEmpty_kWh / 1000);

    fprintf('\nSoC behaviour:\n');
    fprintf('  Mean daily SoC range = %.4f\n', mean(D.socRange, 'omitnan'));
    fprintf('  Median daily SoC range = %.4f\n', median(D.socRange, 'omitnan'));
    fprintf('  Mean hours at SoC min / day = %.3f h\n', mean(D.hoursAtSocMin, 'omitnan'));
    fprintf('  Mean hours at SoC max / day = %.3f h\n', mean(D.hoursAtSocMax, 'omitnan'));

    % ---------------------------------------------------------------------
    % Automatic diagnosis
    % ---------------------------------------------------------------------
    warningRatio = 0.30;

    if isfield(cfg, 'diagnostics') && isfield(cfg.diagnostics, 'expectedCycleWarningRatio')
        warningRatio = cfg.diagnostics.expectedCycleWarningRatio;
    end

    fprintf('\nAutomatic diagnosis:\n');

    if annualExpectedCycles > 50 && annualActualCycles < warningRatio * annualExpectedCycles
        fprintf('  PROBLEM: Expected cycles are high, but actual BESS cycles are very low.\n');
        fprintf('  This points to a BESS control / energy-flow issue, not economics.\n');
    else
        fprintf('  Actual cycles are not extremely low compared to diagnostic opportunity estimate.\n');
    end

    if totalCurtailmentWhileBessNotFull_kWh > 0.05 * max(totalChargeOpportunity_kWh, eps)
        fprintf('  PROBLEM: There is significant curtailment while BESS is not full.\n');
        fprintf('  Check charge request logic and SoC limit handling.\n');
    end

    if totalGridImportWhileBessNotEmpty_kWh > 0.05 * max(totalDischargeOpportunity_kWh, eps)
        fprintf('  PROBLEM: There is significant grid import while BESS is not empty.\n');
        fprintf('  Check discharge request logic and inverter/DC-DC limits.\n');
    end

    if median(D.socRange, 'omitnan') < 0.05 && E_BESS_kWh > 0
        fprintf('  PROBLEM: Daily SoC movement is very small.\n');
        fprintf('  The BESS is probably not receiving charge/discharge requests.\n');
    end

    fprintf('============================================================\n\n');

    % ---------------------------------------------------------------------
    % Save
    % ---------------------------------------------------------------------
    if ~isfolder(diag.savePath)
        mkdir(diag.savePath);
    end

    writetable(D, fullfile(diag.savePath, 'daily_bess_diagnostics.csv'));

    if isfield(cfg.diagnostics, 'saveFullTimeSeries') && cfg.diagnostics.saveFullTimeSeries
        S = diag.series; %#ok<NASGU>
        save(fullfile(diag.savePath, 'bess_diagnostic_timeseries.mat'), 'S');
    end

    save(fullfile(diag.savePath, 'bess_runtime_diagnostics.mat'), 'diag');

    local_plot_diagnostics(diag, cfg);
end


% =========================================================================
% PLOTTING
% =========================================================================
function local_plot_diagnostics(diag, cfg)

    D = diag.dailyTable;

    savePath = diag.savePath;

    % ---------------------------------------------------------------------
    % Plot day selection
    % ---------------------------------------------------------------------
    if isfield(cfg.diagnostics, 'plotDayIndices') && ~isempty(cfg.diagnostics.plotDayIndices)
        dayList = cfg.diagnostics.plotDayIndices(:).';
    else
        dayList = local_pick_problem_days(D);
    end

    dayList = unique(dayList);
    dayList = dayList(dayList >= 1 & dayList <= diag.nDays);

    for i = 1:numel(dayList)
        local_plot_day(diag, dayList(i), savePath);
    end

    % ---------------------------------------------------------------------
    % Plot week selection
    % ---------------------------------------------------------------------
    if isfield(cfg.diagnostics, 'plotWeekStartDays') && ~isempty(cfg.diagnostics.plotWeekStartDays)
        weekStartList = cfg.diagnostics.plotWeekStartDays(:).';
    else
        [~, idxWorst] = max( ...
            D.curtailmentWhileBessNotFull_kWh + ...
            D.gridImportWhileBessNotEmpty_kWh);

        if isempty(idxWorst) || isnan(idxWorst)
            weekStartList = 1;
        else
            weekStartList = max(1, D.dayIndex(idxWorst) - 3);
        end
    end

    weekStartList = unique(weekStartList);

    for i = 1:numel(weekStartList)
        local_plot_week(diag, weekStartList(i), savePath);
    end

    local_plot_daily_summary(D, savePath);
end


function local_plot_day(diag, dayIndex, savePath)

    S = diag.series;

    idx = S.dayIndex == dayIndex;

    if ~any(idx)
        return;
    end

    t = S.time_h(idx) - (dayIndex - 1) * 24;

    fig = figure('Color', 'w', ...
        'Name', sprintf('BESS diagnostic day %d', dayIndex), ...
        'Position', [100, 100, 1300, 900]);

    tiledlayout(4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    % ---------------------------------------------------------------------
    % Load / PV / Grid
    % ---------------------------------------------------------------------
    nexttile;
    hold on;
    grid on;

    plot(t, S.P_load_kW(idx), 'LineWidth', 1.4, 'DisplayName', 'Load');
    plot(t, S.P_pv_available_kW(idx), 'LineWidth', 1.4, 'DisplayName', 'PV available');
    plot(t, S.P_grid_import_kW(idx), 'LineWidth', 1.2, 'DisplayName', 'Grid import');
    plot(t, S.P_curtailment_kW(idx), 'LineWidth', 1.2, 'DisplayName', 'Curtailment');

    ylabel('Power [kW]');
    title(sprintf('Day %d: load, PV, grid import, curtailment', dayIndex));
    legend('Location', 'best');
    xlim([0 24]);

    % ---------------------------------------------------------------------
    % BESS flows
    % ---------------------------------------------------------------------
    nexttile;
    hold on;
    grid on;

    plot(t, S.P_pv_to_bess_kW(idx), 'LineWidth', 1.4, 'DisplayName', 'PV -> BESS');
    plot(t, S.P_bess_to_load_kW(idx), 'LineWidth', 1.4, 'DisplayName', 'BESS -> load');

    if isfield(S, 'P_pack_req_kW')
        plot(t, S.P_pack_req_kW(idx), '--', 'LineWidth', 1.0, 'DisplayName', 'Pack request');
    end

    if isfield(S, 'P_pack_actual_kW')
        plot(t, S.P_pack_actual_kW(idx), ':', 'LineWidth', 1.2, 'DisplayName', 'Pack actual');
    end

    ylabel('Power [kW]');
    title('BESS charge/discharge signals');
    legend('Location', 'best');
    xlim([0 24]);

    % ---------------------------------------------------------------------
    % SoC
    % ---------------------------------------------------------------------
    nexttile;
    hold on;
    grid on;

    plot(t, S.SoC(idx) * 100, 'LineWidth', 1.6, 'DisplayName', 'SoC');

    ylabel('SoC [%]');
    title('Battery SoC');
    ylim([0 100]);
    xlim([0 24]);
    legend('Location', 'best');

    % ---------------------------------------------------------------------
    % Contradictions
    % ---------------------------------------------------------------------
    nexttile;
    hold on;
    grid on;

    plot(t, S.P_curtailment_kW(idx), 'LineWidth', 1.3, 'DisplayName', 'Curtailment');
    plot(t, S.P_grid_import_kW(idx), 'LineWidth', 1.3, 'DisplayName', 'Grid import');
    plot(t, S.P_pv_to_bess_kW(idx), 'LineWidth', 1.3, 'DisplayName', 'PV -> BESS');
    plot(t, S.P_bess_to_load_kW(idx), 'LineWidth', 1.3, 'DisplayName', 'BESS -> load');

    xlabel('Time [h]');
    ylabel('Power [kW]');
    title('Contradiction view');
    legend('Location', 'best');
    xlim([0 24]);

    fileName = sprintf('diagnostic_day_%04d.png', dayIndex);
    saveas(fig, fullfile(savePath, fileName));

    fileNameFig = sprintf('diagnostic_day_%04d.fig', dayIndex);
    savefig(fig, fullfile(savePath, fileNameFig));
end


function local_plot_week(diag, startDay, savePath)

    S = diag.series;

    endDay = min(startDay + 6, diag.nDays);

    idx = S.dayIndex >= startDay & S.dayIndex <= endDay;

    if ~any(idx)
        return;
    end

    t = S.time_h(idx) - (startDay - 1) * 24;

    fig = figure('Color', 'w', ...
        'Name', sprintf('BESS diagnostic week %d-%d', startDay, endDay), ...
        'Position', [100, 100, 1400, 900]);

    tiledlayout(4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    nexttile;
    hold on;
    grid on;
    plot(t, S.P_load_kW(idx), 'LineWidth', 1.2, 'DisplayName', 'Load');
    plot(t, S.P_pv_available_kW(idx), 'LineWidth', 1.2, 'DisplayName', 'PV available');
    ylabel('Power [kW]');
    title(sprintf('Week %d-%d: load and PV', startDay, endDay));
    legend('Location', 'best');

    nexttile;
    hold on;
    grid on;
    plot(t, S.P_pv_to_bess_kW(idx), 'LineWidth', 1.2, 'DisplayName', 'PV -> BESS');
    plot(t, S.P_bess_to_load_kW(idx), 'LineWidth', 1.2, 'DisplayName', 'BESS -> load');
    ylabel('Power [kW]');
    title('BESS operation');
    legend('Location', 'best');

    nexttile;
    hold on;
    grid on;
    plot(t, S.SoC(idx) * 100, 'LineWidth', 1.3, 'DisplayName', 'SoC');
    ylabel('SoC [%]');
    ylim([0 100]);
    title('SoC');
    legend('Location', 'best');

    nexttile;
    hold on;
    grid on;
    plot(t, S.P_grid_import_kW(idx), 'LineWidth', 1.2, 'DisplayName', 'Grid import');
    plot(t, S.P_curtailment_kW(idx), 'LineWidth', 1.2, 'DisplayName', 'Curtailment');
    xlabel('Time from week start [h]');
    ylabel('Power [kW]');
    title('Grid import and curtailment');
    legend('Location', 'best');

    fileName = sprintf('diagnostic_week_%04d_%04d.png', startDay, endDay);
    saveas(fig, fullfile(savePath, fileName));

    fileNameFig = sprintf('diagnostic_week_%04d_%04d.fig', startDay, endDay);
    savefig(fig, fullfile(savePath, fileNameFig));
end


function local_plot_daily_summary(D, savePath)

    fig = figure('Color', 'w', ...
        'Name', 'Daily BESS diagnostic summary', ...
        'Position', [120, 120, 1300, 900]);

    tiledlayout(4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    nexttile;
    hold on;
    grid on;
    plot(D.dayIndex, D.chargeOpportunity_kWh, 'LineWidth', 1.2, 'DisplayName', 'Charge opportunity');
    plot(D.dayIndex, D.pvToBess_kWh, 'LineWidth', 1.2, 'DisplayName', 'Actual PV -> BESS');
    ylabel('kWh/day');
    title('Daily charge opportunity vs actual BESS charge');
    legend('Location', 'best');

    nexttile;
    hold on;
    grid on;
    plot(D.dayIndex, D.dischargeOpportunity_kWh, 'LineWidth', 1.2, 'DisplayName', 'Discharge opportunity');
    plot(D.dayIndex, D.bessToLoad_kWh, 'LineWidth', 1.2, 'DisplayName', 'Actual BESS -> load');
    ylabel('kWh/day');
    title('Daily discharge opportunity vs actual BESS discharge');
    legend('Location', 'best');

    nexttile;
    hold on;
    grid on;
    plot(D.dayIndex, D.socMin * 100, 'LineWidth', 1.0, 'DisplayName', 'SoC min');
    plot(D.dayIndex, D.socMax * 100, 'LineWidth', 1.0, 'DisplayName', 'SoC max');
    plot(D.dayIndex, D.socRange * 100, 'LineWidth', 1.2, 'DisplayName', 'SoC range');
    ylabel('[%]');
    title('Daily SoC movement');
    legend('Location', 'best');

    nexttile;
    hold on;
    grid on;
    plot(D.dayIndex, D.curtailmentWhileBessNotFull_kWh, 'LineWidth', 1.2, ...
        'DisplayName', 'Curtailment while BESS not full');
    plot(D.dayIndex, D.gridImportWhileBessNotEmpty_kWh, 'LineWidth', 1.2, ...
        'DisplayName', 'Grid import while BESS not empty');
    xlabel('Day index');
    ylabel('kWh/day');
    title('Contradiction indicators');
    legend('Location', 'best');

    saveas(fig, fullfile(savePath, 'daily_bess_diagnostic_summary.png'));
    savefig(fig, fullfile(savePath, 'daily_bess_diagnostic_summary.fig'));
end


% =========================================================================
% TABLE CONSTRUCTION
% =========================================================================
function T = local_daily_table(diag)

    D = diag.daily;

    T = table();

    T.dayIndex = D.dayIndex;
    T.date = D.date;

    T.loadEnergy_kWh = D.loadEnergy_kWh;
    T.pvAvailable_kWh = D.pvAvailable_kWh;
    T.pvToLoad_kWh = D.pvToLoad_kWh;
    T.pvToBess_kWh = D.pvToBess_kWh;
    T.bessToLoad_kWh = D.bessToLoad_kWh;
    T.gridImport_kWh = D.gridImport_kWh;
    T.gridExport_kWh = D.gridExport_kWh;
    T.curtailment_kWh = D.curtailment_kWh;

    T.chargeOpportunity_kWh = D.chargeOpportunity_kWh;
    T.dischargeOpportunity_kWh = D.dischargeOpportunity_kWh;
    T.expectedChargeLimited_kWh = D.expectedChargeLimited_kWh;
    T.actualBessThroughput_kWh = D.actualBessThroughput_kWh;
    T.actualEquivalentCycles = D.actualEquivalentCycles;
    T.expectedEquivalentCycles = D.expectedEquivalentCycles;

    T.curtailmentWhileBessNotFull_kWh = D.curtailmentWhileBessNotFull_kWh;
    T.gridImportWhileBessNotEmpty_kWh = D.gridImportWhileBessNotEmpty_kWh;

    T.socStart = D.socStart;
    T.socEnd = D.socEnd;
    T.socMin = D.socMin;
    T.socMax = D.socMax;
    T.socRange = D.socRange;

    T.hoursAtSocMin = D.hoursAtSocMin;
    T.hoursAtSocMax = D.hoursAtSocMax;

    T.maxPvSurplusLike_kW = D.maxPvSurplusLike_kW;
    T.maxGridImport_kW = D.maxGridImport_kW;
    T.maxBessCharge_kW = D.maxBessCharge_kW;
    T.maxBessDischarge_kW = D.maxBessDischarge_kW;
end


% =========================================================================
% HELPERS
% =========================================================================
function names = local_signal_names()

    names = { ...
        'P_load_kW', ...
        'P_pv_available_kW', ...
        'P_served_kW', ...
        'P_unserved_kW', ...
        'P_pv_to_load_kW', ...
        'P_pv_to_bess_kW', ...
        'P_bess_to_load_kW', ...
        'P_grid_import_kW', ...
        'P_grid_export_kW', ...
        'P_curtailment_kW', ...
        'P_inv_loss_kW', ...
        'P_dcdc_loss_kW', ...
        'P_internal_network_loss_kW', ...
        'SoC', ...
        'P_bess_cell_loss_kW', ...
        'P_bess_soc_full_loss_kW', ...
        'P_bess_soc_empty_loss_kW', ...
        'P_bess_total_internal_loss_kW', ...
        'P_dcdc_conversion_loss_kW', ...
        'P_dcdc_power_clipped_kW', ...
        'P_inv_conversion_loss_kW', ...
        'P_inv_power_clipped_kW', ...
        'P_inv_pv_conversion_loss_kW', ...
        'P_inv_bess_conversion_loss_kW', ...
        'P_inv_pv_clipped_kW', ...
        'P_inv_bess_clipped_kW', ...
        'P_bess_high_req_kW', ...
        'P_bess_high_actual_kW', ...
        'P_pack_req_kW', ...
        'P_pack_actual_kW'};
end


function x = local_get_signal(V, name, N)

    if isfield(V, name)
        x = double(V.(name)(:));
    else
        if isempty(N)
            x = [];
        else
            x = NaN(N, 1);
        end
        return;
    end

    if isempty(N)
        return;
    end

    if numel(x) < N
        x(end+1:N, 1) = NaN;
    end

    if numel(x) > N
        x = x(1:N);
    end
end


function value = local_get_design_value(design, fieldName)

    if isfield(design, fieldName)
        value = double(design.(fieldName));
        value = value(1);
        return;
    end

    if strcmp(fieldName, 'P_PV_kW') && isfield(design, 'PV_kW')
        value = double(design.PV_kW);
        value = value(1);
        return;
    end

    if strcmp(fieldName, 'PV_kW') && isfield(design, 'P_PV_kW')
        value = double(design.P_PV_kW);
        value = value(1);
        return;
    end

    error('Missing design field: %s', fieldName);
end


function value = local_get_cfg_value(cfg, pathCells)

    current = cfg;

    for k = 1:numel(pathCells)

        fieldName = pathCells{k};

        if ~isstruct(current) || ~isfield(current, fieldName)
            error('Missing cfg field: %s', strjoin(pathCells, '.'));
        end

        current = current.(fieldName);
    end

    value = current;
end


function y = local_safe_divide(a, b)

    if ~isfinite(a) || ~isfinite(b) || abs(b) < 1e-12
        y = NaN;
    else
        y = a / b;
    end
end


function dayList = local_pick_problem_days(D)

    score = ...
        D.curtailmentWhileBessNotFull_kWh + ...
        D.gridImportWhileBessNotEmpty_kWh + ...
        abs(D.expectedEquivalentCycles - D.actualEquivalentCycles);

    score(~isfinite(score)) = -inf;

    [~, order] = sort(score, 'descend');

    order = order(1:min(5, numel(order)));

    dayList = D.dayIndex(order);

    if isempty(dayList)
        dayList = 1:min(5, height(D));
    end
end