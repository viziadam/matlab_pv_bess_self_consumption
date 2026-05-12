function diagnostics = run_simulation_diagnostics(cfg, options)
% RUN_SIMULATION_DIAGNOSTICS
%
% Minimalis, skalazhato diagnosztikai template a PV+BESS szimulacios
% algoritmus ellenorzesere. Szintetikus, kontrollalt fogyasztasi/PV profilon
% futtat egy BESS-es candidate-et DC- es AC-csatolt topologiaval, majd:
%   - ellenorzi az energiaaramlasi alapinvariansokat,
%   - ellenorzi a candidateTable/frissitett metrikak es finalSoH/finalSoC
%     jelenletet,
%   - ellenorzi az akkumulator allapotvaltozokat (SoC/SoH),
%   - opcionálisan plottolja a teljesitmenyaramlasokat es akkuallapotokat.
%
% Hasznalat:
%   diagnostics = run_simulation_diagnostics();
%   diagnostics = run_simulation_diagnostics(cfg);
%   diagnostics = run_simulation_diagnostics(cfg, struct('makePlots', false));
%
% A fuggveny szandekosan kulonallo template: mas felhasznalasi esetekhez a
% local_build_synthetic_data, local_apply_single_candidate és local_run_case
% reszek cserelhetok/altalanosithatok anelkul, hogy a fo szimulacios
% fuggvenyeket modositani kellene.

    if nargin < 1 || isempty(cfg)
        basePath = fileparts(mfilename('fullpath'));
        cfg = create_configurations(basePath);
    end

    if nargin < 2 || isempty(options)
        options = struct();
    end

    options = local_default_options(options, cfg);

    data = local_build_synthetic_data(options.dt_h, options.nDays);
    cfg = local_apply_single_candidate(cfg, options.design);

    couplings = string(options.couplings(:)).';

    diagnostics = struct();
    diagnostics.createdAt = datetime('now');
    diagnostics.description = "PV+BESS DC/AC coupling diagnostic template";
    diagnostics.options = options;
    diagnostics.dataInfo = data.info;
    caseCells = cell(1, numel(couplings));

    for i = 1:numel(couplings)
        caseCells{i} = local_run_case(data, cfg, couplings(i), options);
    end

    diagnostics.cases = [caseCells{:}];
    diagnostics.summaryTable = local_build_summary_table(diagnostics.cases);

    if any(~diagnostics.summaryTable.passed)
        warning('run_simulation_diagnostics:failedChecks', ...
            'Egy vagy tobb diagnosztikai ellenorzes sikertelen. Lasd diagnostics.summaryTable.');
    end
end


function options = local_default_options(options, cfg)

    if ~isfield(options, 'dt_h')
        options.dt_h = 0.25;
    end

    if ~isfield(options, 'nDays')
        options.nDays = 3;
    end

    if ~isfield(options, 'couplings')
        options.couplings = ["dc", "ac"];
    end

    if ~isfield(options, 'makePlots')
        options.makePlots = true;
    end

    if ~isfield(options, 'figureVisible')
        options.figureVisible = "off";
    end

    if ~isfield(options, 'tolerance_kW')
        options.tolerance_kW = 1e-6;
    end

    if ~isfield(options, 'design')
        options.design = struct();
    end

    if ~isfield(options.design, 'P_inv_kW')
        options.design.P_inv_kW = 500;
    end

    if ~isfield(options.design, 'DCAC_ratio')
        options.design.DCAC_ratio = 1.2;
    end

    if ~isfield(options.design, 'BESS_PV_ratio')
        options.design.BESS_PV_ratio = 1.5;
    end

    if ~isfield(options.design, 'bessDuration_h')
        options.design.bessDuration_h = 3;
    end

    options.design.P_PV_kW = options.design.P_inv_kW * options.design.DCAC_ratio;
    options.design.PV_kW = options.design.P_PV_kW;
    options.design.E_BESS_kWh = options.design.BESS_PV_ratio * options.design.P_PV_kW;
    options.design.P_BESS_kW = options.design.E_BESS_kWh / options.design.bessDuration_h;

    if ~isfield(options, 'outputDir')
        options.outputDir = fullfile(cfg.paths.figures, 'diagnostics');
    end

    if options.makePlots && ~exist(options.outputDir, 'dir')
        mkdir(options.outputDir);
    end
end


function data = local_build_synthetic_data(dt_h, nDays)

    nT = round(24 / dt_h);
    time_h = (0:nT-1).' * dt_h;

    pvBase = max(0, sin(pi * (time_h - 6) / 12));
    pvBase = pvBase .^ 1.35;

    morningPeak = 80 * exp(-0.5 * ((time_h - 8) / 1.5).^2);
    eveningPeak = 140 * exp(-0.5 * ((time_h - 19) / 2.0).^2);
    baseLoad = 240 + 25 * sin(2 * pi * (time_h - 5) / 24);
    loadShape = max(80, baseLoad + morningPeak + eveningPeak);

    T_amb_C = 20 + 9 * max(0, sin(pi * (time_h - 7) / 12));

    days = repmat(struct(), nDays, 1);

    for d = 1:nDays
        loadScale = 1 + 0.03 * (d - 1);
        pvScale = 1 - 0.04 * (d - 1);

        days(d).date = datetime(2026, 6, d);
        days(d).P_load_kW = loadScale * loadShape;
        days(d).P_pv_base_kW = pvScale * pvBase;
        days(d).T_amb_C = T_amb_C + 0.5 * (d - 1);
        days(d).dt_h = dt_h;
    end

    data = struct();
    data.days = days;
    data.info = struct();
    data.info.source = "synthetic_diagnostic_profile";
    data.info.description = "Controlled PV/load profile with midday BESS charge and evening/night discharge";
    data.info.nDays = nDays;
    data.info.nT = nT;
    data.info.dt_h = dt_h;
end


function cfg = local_apply_single_candidate(cfg, design)

    cfg.system.bessCoupling = "dc";
    cfg.grid.allowExport = false;

    cfg.candidates.P_inv_kW_vec = design.P_inv_kW;
    cfg.candidates.DCAC_ratio_vec = design.DCAC_ratio;
    cfg.candidates.BESS_PV_vec = design.BESS_PV_ratio;
    cfg.candidates.bessDuration_h = design.bessDuration_h;

    cfg.sim.saveAfterEachCandidate = false;
    cfg.sim.verbose = false;
    cfg.sim.strictMetricSources = true;
end


function caseResult = local_run_case(data, cfgBase, coupling, options)

    cfgCase = cfgBase;
    cfgCase.system.bessCoupling = coupling;

    DB = init_candidate_database_structures(data, cfgCase);
    DB = simulate_candidates_database(data, DB, cfgCase);

    design = local_table_row_to_design(DB.candidateTable(1, :));
    history = local_collect_detailed_history(data, cfgCase, design);

    checks = local_run_checks(DB, history, options);

    plotFiles = strings(0, 1);
    if options.makePlots
        plotFiles = local_plot_case(history, coupling, options);
    end

    caseResult = struct();
    caseResult.coupling = coupling;
    caseResult.DB = DB;
    caseResult.history = history;
    caseResult.checks = checks;
    caseResult.plotFiles = plotFiles;
    caseResult.passed = all(checks.passed);
end


function design = local_table_row_to_design(row)

    design = struct();
    names = row.Properties.VariableNames;

    for i = 1:numel(names)
        name = names{i};
        value = row.(name);

        if iscell(value)
            value = value{1};
        elseif isstring(value) || isnumeric(value) || islogical(value)
            value = value(1);
        end

        design.(name) = value;
    end
end


function history = local_collect_detailed_history(data, cfg, design)

    nDays = numel(data.days);
    nT = numel(data.days(1).P_load_kW);

    state = init_bess_state_for_candidate(design, cfg, data.days(1).dt_h);
    running = init_metrics(nT, cfg);

    dayResultCells = cell(nDays, 1);
    stateEndCells = cell(nDays, 1);

    for d = 1:nDays
        dayInput = local_get_day_input(data, d);
        dayResultCells{d} = simulate_day_vectorized(dayInput, state, design, cfg);
        running = update_metrics(running, dayResultCells{d}.dayVectors, dayInput.dt_h, cfg);
        state = dayResultCells{d}.stateEnd;
        stateEndCells{d} = state;
    end

    history = struct();
    history.design = design;
    history.running = running;
    history.dayResults = [dayResultCells{:}];
    history.stateEnd = [stateEndCells{:}];
    history.finalState = state;
    history.firstDay = dayResultCells{1}.dayVectors;
    history.dt_h = data.days(1).dt_h;
    history.time_h = (0:nT-1).' * history.dt_h;
end


function dayInput = local_get_day_input(data, dayIdx)

    dd = data.days(dayIdx);

    dayInput = struct();
    dayInput.date = dd.date;
    dayInput.dayIndex = dayIdx;
    dayInput.P_load_kW = dd.P_load_kW(:);
    dayInput.P_pv_base_kW = dd.P_pv_base_kW(:);
    dayInput.dt_h = dd.dt_h;

    if isfield(dd, 'T_amb_C')
        dayInput.T_amb_C = dd.T_amb_C(:);
    end
end


function checks = local_run_checks(DB, history, options)

    names = strings(0, 1);
    passed = false(0, 1);
    values = zeros(0, 1);
    tolerances = zeros(0, 1);
    details = strings(0, 1);

    v = history.firstDay;
    tol = options.tolerance_kW;

    loadBalanceError = max(abs(v.P_load_kW(:) - ...
        v.P_pv_to_load_kW(:) - v.P_bess_to_load_kW(:) - v.P_grid_import_kW(:)));
    [names, passed, values, tolerances, details] = local_add_check( ...
        names, passed, values, tolerances, details, ...
        "load_power_balance", loadBalanceError <= tol, loadBalanceError, tol, ...
        "P_load = P_pv_to_load + P_bess_to_load + P_grid_import");

    noExportError = max(abs(v.P_grid_export_kW(:)));
    [names, passed, values, tolerances, details] = local_add_check( ...
        names, passed, values, tolerances, details, ...
        "no_grid_export_when_disabled", noExportError <= tol, noExportError, tol, ...
        "cfg.grid.allowExport=false eseten P_grid_export_kW nulla");

    simultaneousBessPower = max(min(v.P_pv_to_bess_kW(:), v.P_bess_to_load_kW(:)));
    [names, passed, values, tolerances, details] = local_add_check( ...
        names, passed, values, tolerances, details, ...
        "no_simultaneous_bess_charge_discharge", simultaneousBessPower <= tol, ...
        simultaneousBessPower, tol, "BESS ne toltsen es sussön ki ugyanabban a mintaban");

    socMin = min(v.SoC(:));
    socMax = max(v.SoC(:));
    socBoundsError = max([0; -socMin; socMax - 1]);
    [names, passed, values, tolerances, details] = local_add_check( ...
        names, passed, values, tolerances, details, ...
        "soc_within_unit_interval", socBoundsError <= tol, socBoundsError, tol, ...
        "SoC tartomany: [0, 1]");

    if isfield(v, 'SOH')
        sohMin = min(v.SOH(:));
        sohMax = max(v.SOH(:));
        sohBoundsError = max([0; -sohMin; sohMax - 1]);
    else
        sohBoundsError = inf;
    end
    [names, passed, values, tolerances, details] = local_add_check( ...
        names, passed, values, tolerances, details, ...
        "soh_within_unit_interval", sohBoundsError <= tol, sohBoundsError, tol, ...
        "SOH tartomany: [0, 1]");

    chargeEnergy_kWh = sum(v.P_pv_to_bess_kW(:)) * history.dt_h;
    dischargeEnergy_kWh = sum(v.P_bess_to_load_kW(:)) * history.dt_h;
    bessActive = chargeEnergy_kWh > tol && dischargeEnergy_kWh > tol;
    [names, passed, values, tolerances, details] = local_add_check( ...
        names, passed, values, tolerances, details, ...
        "bess_charge_and_discharge_observed", bessActive, ...
        min(chargeEnergy_kWh, dischargeEnergy_kWh), tol, ...
        "A diagnosztikai profilban legyen BESS toltes es kisutes is");

    T = DB.candidateTable;
    tableSoHOk = ismember('finalSoH', T.Properties.VariableNames) && ...
        isfinite(T.finalSoH(1)) && T.finalSoH(1) > 0 && T.finalSoH(1) <= 1;
    tableSoHValue = NaN;
    if ismember('finalSoH', T.Properties.VariableNames)
        tableSoHValue = T.finalSoH(1);
    end
    [names, passed, values, tolerances, details] = local_add_check( ...
        names, passed, values, tolerances, details, ...
        "candidate_table_final_soh_written", tableSoHOk, tableSoHValue, 1, ...
        "simulate_candidates_database irja a candidateTable.finalSoH erteket");

    tableSoCOk = ismember('finalSoC', T.Properties.VariableNames) && ...
        isfinite(T.finalSoC(1)) && T.finalSoC(1) >= 0 && T.finalSoC(1) <= 1;
    tableSoCValue = NaN;
    if ismember('finalSoC', T.Properties.VariableNames)
        tableSoCValue = T.finalSoC(1);
    end
    [names, passed, values, tolerances, details] = local_add_check( ...
        names, passed, values, tolerances, details, ...
        "candidate_table_final_soc_written", tableSoCOk, tableSoCValue, 1, ...
        "simulate_candidates_database irja a candidateTable.finalSoC erteket");

    metricsOk = T.wasSimulated(1) && ~T.hasError(1) && ...
        T.loadEnergy_kWh(1) > 0 && T.pvToBess_kWh(1) > 0 && T.bessToLoad_kWh(1) > 0;
    [names, passed, values, tolerances, details] = local_add_check( ...
        names, passed, values, tolerances, details, ...
        "candidate_metrics_updated", metricsOk, double(metricsOk), 1, ...
        "finalize_candidate_result/update_metrics frissitette a candidate-szintu metrikakat");

    checks = table(names, passed, values, tolerances, details, ...
        'VariableNames', {'checkName', 'passed', 'value', 'tolerance', 'details'});
end


function [names, passed, values, tolerances, details] = local_add_check( ...
    names, passed, values, tolerances, details, checkName, isPassed, value, tolerance, detail)

    names(end+1, 1) = string(checkName);
    passed(end+1, 1) = logical(isPassed);
    values(end+1, 1) = double(value);
    tolerances(end+1, 1) = double(tolerance);
    details(end+1, 1) = string(detail);
end


function plotFiles = local_plot_case(history, coupling, options)

    plotFiles = strings(2, 1);
    v = history.firstDay;
    time_h = history.time_h;

    couplingChar = char(coupling);
    couplingUpper = upper(couplingChar);

    fig = figure('Visible', char(options.figureVisible), ...
        'Name', sprintf('PV+BESS %s energy flows diagnostic', couplingUpper));
    tiledlayout(fig, 2, 1);

    nexttile;
    plot(time_h, v.P_load_kW, 'k-', 'LineWidth', 1.3); hold on;
    plot(time_h, v.P_pv_available_kW, 'Color', [0.95 0.55 0.10], 'LineWidth', 1.1);
    plot(time_h, v.P_pv_to_load_kW, 'g-', 'LineWidth', 1.0);
    plot(time_h, v.P_grid_import_kW, 'b-', 'LineWidth', 1.0);
    grid on;
    xlabel('Ido [h]');
    ylabel('Teljesitmeny [kW]');
    title(sprintf('%s-csatolt: fogyasztas, PV es grid import', couplingUpper));
    legend({'Load', 'PV available', 'PV to load', 'Grid import'}, 'Location', 'best');

    nexttile;
    plot(time_h, v.P_pv_to_bess_kW, 'Color', [0.10 0.55 0.95], 'LineWidth', 1.1); hold on;
    plot(time_h, v.P_bess_to_load_kW, 'Color', [0.80 0.10 0.10], 'LineWidth', 1.1);
    plot(time_h, v.P_curtailment_kW, 'Color', [0.45 0.45 0.45], 'LineWidth', 1.0);
    grid on;
    xlabel('Ido [h]');
    ylabel('Teljesitmeny [kW]');
    title('BESS aramlasok es curtailment');
    legend({'PV to BESS', 'BESS to load', 'Curtailment'}, 'Location', 'best');

    plotFiles(1) = fullfile(options.outputDir, sprintf('diagnostic_%s_energy_flows.png', couplingChar));
    saveas(fig, char(plotFiles(1)));
    close(fig);

    fig = figure('Visible', char(options.figureVisible), ...
        'Name', sprintf('PV+BESS %s battery diagnostic', couplingUpper));
    tiledlayout(fig, 2, 1);

    nexttile;
    plot(time_h, v.SoC * 100, 'b-', 'LineWidth', 1.2); hold on;
    if isfield(v, 'SOH')
        plot(time_h, v.SOH * 100, 'r-', 'LineWidth', 1.0);
        legend({'SoC', 'SoH'}, 'Location', 'best');
    else
        legend({'SoC'}, 'Location', 'best');
    end
    grid on;
    xlabel('Ido [h]');
    ylabel('Allapot [%]');
    title(sprintf('%s-csatolt: BESS SoC/SoH', couplingUpper));

    nexttile;
    if isfield(v, 'P_pack_req_kW')
        plot(time_h, v.P_pack_req_kW, 'Color', [0.3 0.3 0.3], 'LineWidth', 1.0); hold on;
    end
    if isfield(v, 'P_pack_actual_kW')
        plot(time_h, v.P_pack_actual_kW, 'm-', 'LineWidth', 1.0);
    end
    grid on;
    xlabel('Ido [h]');
    ylabel('Pack teljesitmeny [kW]');
    title('Pack request/actual (+ kisutes, - toltes)');
    legend({'P pack requested', 'P pack actual'}, 'Location', 'best');

    plotFiles(2) = fullfile(options.outputDir, sprintf('diagnostic_%s_battery_state.png', couplingChar));
    saveas(fig, char(plotFiles(2)));
    close(fig);
end


function summaryTable = local_build_summary_table(cases)

    caseName = strings(0, 1);
    checkName = strings(0, 1);
    passed = false(0, 1);
    value = zeros(0, 1);
    tolerance = zeros(0, 1);
    details = strings(0, 1);

    for i = 1:numel(cases)
        C = cases(i).checks;
        n = height(C);
        idx = numel(caseName) + (1:n);

        caseName(idx, 1) = cases(i).coupling;
        checkName(idx, 1) = C.checkName;
        passed(idx, 1) = C.passed;
        value(idx, 1) = C.value;
        tolerance(idx, 1) = C.tolerance;
        details(idx, 1) = C.details;
    end

    summaryTable = table(caseName, checkName, passed, value, tolerance, details);
end