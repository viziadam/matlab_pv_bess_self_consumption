function acdcResult = evaluation_acdc_summary(cfg, options)
% EVALUATION_ACDC_SUMMARY
%
% AC/DC osszesito kiertekeles a grid-connected PV+BESS self-consumption
% esettanulmanyhoz.
%
% A fuggveny a ket mar lefutott eredmenyfajlt hasonlitja ossze:
%   results/results_dccoupled.mat
%   results/results_accoupled.mat
%
% A regi single-topology evaluation abrakat alapertelmezetten nem generalja,
% mert az AC/DC riportban csak az 5 kivalasztott jelolt szerepeljen:
%   1) legjobb csak PV
%   2) legjobb DC LCSE szerint
%   3) legjobb DC NPV szerint
%   4) legjobb AC LCSE szerint
%   5) legjobb AC NPV szerint

    if nargin < 2 || isempty(options)
        options = struct();
    end

    options = local_default_options(cfg, options);

    if ~exist(options.outputFolder, 'dir')
        mkdir(options.outputFolder);
    end

    tableFolder = fullfile(options.outputFolder, 'tables');
    figureFolder = fullfile(options.outputFolder, 'figures');

    if ~exist(tableFolder, 'dir')
        mkdir(tableFolder);
    end

    if ~exist(figureFolder, 'dir')
        mkdir(figureFolder);
    end

    fprintf('\n============================================================\n');
    fprintf('AC/DC combined evaluation started.\n');
    fprintf('Output folder: %s\n', options.outputFolder);
    fprintf('============================================================\n\n');

    [dcEval, dcTable] = local_run_single_coupling_evaluation(cfg, "dc", options);
    [acEval, acTable] = local_run_single_coupling_evaluation(cfg, "ac", options);

    dcTable = local_add_report_columns(dcTable, dcEval.evalCfg, cfg);
    acTable = local_add_report_columns(acTable, acEval.evalCfg, cfg);

    combinedTable = [dcTable; acTable];

    selected = local_select_report_candidates(combinedTable);
    selectedTable = selected.table;
    selectedLabels = selected.labels;
    selectedShortLabels = selected.shortLabels;

    selectedSummaryTable = local_build_selected_summary_table(selectedTable, selectedLabels);
    bessOnlyTable = local_build_bess_only_table(selectedTable, selectedLabels);

    % ---------------------------------------------------------------------
    % 3D LCSE / NPV abrak kulon DC es AC esetre
    % ---------------------------------------------------------------------
    local_plot_3d_metric(dcTable, 'LCSE_HUF_per_kWh_saved', ...
        'LCSE - megtakaritott energia fajlagos koltsege', 'Ft/kWh', 'min', figureFolder, 'dc');

    local_plot_3d_metric(dcTable, 'NPV_millionHUF', ...
        'Netto jelenertek', 'millio Ft', 'max', figureFolder, 'dc');

    local_plot_3d_metric(acTable, 'LCSE_HUF_per_kWh_saved', ...
        'LCSE - megtakaritott energia fajlagos koltsege', 'Ft/kWh', 'min', figureFolder, 'ac');

    local_plot_3d_metric(acTable, 'NPV_millionHUF', ...
        'Netto jelenertek', 'millio Ft', 'max', figureFolder, 'ac');

    % ---------------------------------------------------------------------
    % 5 jelolt osszesito abrak
    % ---------------------------------------------------------------------
    local_plot_value_cost_payback_summary(selectedTable, selectedShortLabels, figureFolder);
    local_plot_self_consumption_summary(selectedTable, selectedShortLabels, figureFolder);
    local_plot_useful_energy_and_losses(selectedTable, selectedShortLabels, figureFolder);

    % ---------------------------------------------------------------------
    % Mentesek
    % ---------------------------------------------------------------------
    writetable(combinedTable, fullfile(tableFolder, 'acdc_combined_candidate_table.csv'));
    writetable(selectedSummaryTable, fullfile(tableFolder, 'acdc_selected_candidates_summary.csv'));
    writetable(bessOnlyTable, fullfile(tableFolder, 'acdc_selected_bess_only_period_value_table.csv'));

    acdcResult = struct();
    acdcResult.createdAt = datetime('now');
    acdcResult.options = options;
    acdcResult.dcEvaluation = dcEval;
    acdcResult.acEvaluation = acEval;
    acdcResult.combinedTable = combinedTable;
    acdcResult.selectedTable = selectedTable;
    acdcResult.selectedSummaryTable = selectedSummaryTable;
    acdcResult.selectedBessOnlyValueTable = bessOnlyTable;
    acdcResult.outputFolder = options.outputFolder;

    save(fullfile(options.outputFolder, 'evaluation_acdc_summary_result.mat'), ...
        'acdcResult', '-v7.3');

    fprintf('\nAC/DC combined evaluation finished.\n');
    fprintf('Selected candidate summary saved: %s\n', ...
        fullfile(tableFolder, 'acdc_selected_candidates_summary.csv'));
end


% =========================================================================
% DEFAULTS
% =========================================================================
function options = local_default_options(cfg, options)

    if ~isfield(cfg, 'paths') || ~isfield(cfg.paths, 'figures')
        error('cfg.paths.figures is required.');
    end

    if ~isfield(cfg.paths, 'results')
        error('cfg.paths.results is required.');
    end

    if ~isfield(options, 'outputFolder')
        options.outputFolder = fullfile(cfg.paths.figures, 'evaluation_acdc');
    end

    if ~isfield(options, 'singleEvaluationFolderName')
        options.singleEvaluationFolderName = 'single_topology_evaluation';
    end

    if ~isfield(options, 'saveSingleTopologyEvaluationCsv')
        options.saveSingleTopologyEvaluationCsv = false;
    end

    % Fontos: AC/DC osszesiteskor a regi 3 jeloltes single-topology abrakat
    % nem kerjuk, mert zavaro x tengelyt es mas logikat adnak.
    if ~isfield(options, 'makeSingleTopologyPlots')
        options.makeSingleTopologyPlots = false;
    end
end


% =========================================================================
% SINGLE TOPOLOGY EVALUATION
% =========================================================================
function [evaluationResult, T] = local_run_single_coupling_evaluation(cfg, coupling, options)

    cfgEval = cfg;
    cfgEval.system.bessCoupling = coupling;

    evalCfg = create_evaluation_config(cfgEval);

    switch string(coupling)
        case "dc"
            evalCfg.input.resultFilePath = fullfile(cfg.paths.results, 'results_dccoupled.mat');
        case "ac"
            evalCfg.input.resultFilePath = fullfile(cfg.paths.results, 'results_accoupled.mat');
        otherwise
            error('Unknown coupling: %s', string(coupling));
    end

    evalCfg.output.baseFolder = fullfile( ...
        options.outputFolder, ...
        options.singleEvaluationFolderName, ...
        char(coupling));

    evalCfg.output.saveEvaluationCsv = options.saveSingleTopologyEvaluationCsv;
    evalCfg.plots.makePlots = options.makeSingleTopologyPlots;
    evalCfg.plots.make3DScatter = false;

    if ~isfile(evalCfg.input.resultFilePath)
        error(['Missing %s result file: %s\n', ...
               'Run the %s-coupled simulation before AC/DC summary evaluation.'], ...
               upper(char(coupling)), evalCfg.input.resultFilePath, upper(char(coupling)));
    end

    evaluationResult = evaluation(cfgEval, evalCfg);
    T = evaluationResult.resultTable;

    T.Coupling = repmat(string(coupling), height(T), 1);
    T = movevars(T, 'Coupling', 'Before', 1);
end


% =========================================================================
% REPORT COLUMNS
% =========================================================================
function T = local_add_report_columns(T, evalCfg, cfg)

    simYears = evalCfg.economics.simYears;
    pvLifetime = evalCfg.economics.pvLifetime_years;
    inverterLifetime = evalCfg.economics.inverterLifetime_years;

    if simYears <= 0
        error('evalCfg.economics.simYears must be positive.');
    end

    n = height(T);

    finalSoH = local_col(T, 'finalSoH', ones(n, 1));
    finalSoH(~isfinite(finalSoH)) = 1;

    capexPV = local_col(T, 'capexPV_HUF', zeros(n, 1));
    capexInv = local_col(T, 'capexInverter_HUF', zeros(n, 1));
    capexBess = local_col(T, 'capexBESS_HUF', zeros(n, 1));

    hasBess = local_col(T, 'E_BESS_kWh', zeros(n, 1)) > 1e-9;

    deltaSoH = max(0, 1 - finalSoH);
    deltaSoH(~hasBess) = 0;

    % ---------------------------------------------------------------------
    % Periodusra vetitett rendszerkoltsegek
    % ---------------------------------------------------------------------
    T.reportSimYears = repmat(simYears, n, 1);
    T.reportDeltaSoH = deltaSoH;

    T.reportPeriodPVCapex_HUF = capexPV ./ pvLifetime .* simYears;
    T.reportPeriodPVOpex_HUF = capexPV .* evalCfg.economics.pv_opex_frac_per_year .* simYears;

    T.reportPeriodInverterCapex_HUF = capexInv ./ inverterLifetime .* simYears;
    T.reportPeriodInverterOpex_HUF = capexInv .* evalCfg.economics.inverter_opex_frac_per_year .* simYears;

    T.reportPeriodBessDegradation_HUF = (deltaSoH ./ 0.2) .* capexBess;
    T.reportPeriodBessOpex_HUF = capexBess .* evalCfg.economics.bess_opex_frac_per_year .* simYears;

    T.reportPeriodInvestmentCost_HUF = ...
        T.reportPeriodPVCapex_HUF + ...
        T.reportPeriodPVOpex_HUF + ...
        T.reportPeriodInverterCapex_HUF + ...
        T.reportPeriodInverterOpex_HUF + ...
        T.reportPeriodBessDegradation_HUF + ...
        T.reportPeriodBessOpex_HUF;

    % A teljes szimulalt idoszak energiakoltseg-megtakaritasa.
    T.reportPeriodCostSaving_HUF = local_col(T, 'energyCostSavings_HUF', zeros(n, 1));

    % Saját, egyszeru riportmutato: megtakaritas - periodusra allokalt koltsegek.
    T.reportPeriodNetValue_HUF = ...
        T.reportPeriodCostSaving_HUF - T.reportPeriodInvestmentCost_HUF;

    % ---------------------------------------------------------------------
    % BESS-only periodusmutatok
    % ---------------------------------------------------------------------
    importPrice_HUF_per_kWh = local_get_import_price(T, cfg);

    T.reportPeriodBessAcSaving_HUF = ...
        local_col(T, 'bessToLoad_kWh', zeros(n, 1)) .* importPrice_HUF_per_kWh;

    T.reportPeriodBessAcSaving_HUF(~hasBess) = 0;

    T.reportPeriodBessOnlyCost_HUF = ...
        T.reportPeriodBessDegradation_HUF + T.reportPeriodBessOpex_HUF;

    T.reportPeriodBessOnlyNetValue_HUF = ...
        T.reportPeriodBessAcSaving_HUF - T.reportPeriodBessOnlyCost_HUF;

    % ---------------------------------------------------------------------
    % Energia es veszteseg bontas a teljes szimulalt idoszakra
    % ---------------------------------------------------------------------
    T.reportUsefulACEnergy_MWh = ...
        (local_col(T, 'pvToLoad_kWh', zeros(n, 1)) + ...
         local_col(T, 'bessToLoad_kWh', zeros(n, 1))) ./ 1000;

    invLoss = local_col(T, 'inverterConversionLoss_kWh', zeros(n, 1));

    if all(abs(invLoss) < 1e-12)
        invLoss = local_col(T, 'inverterLoss_kWh', zeros(n, 1));
    end

    T.reportInverterLoss_MWh = invLoss ./ 1000;

    T.reportDcdcLoss_MWh = ...
        local_col(T, 'dcdcConversionLoss_kWh', zeros(n, 1)) ./ 1000;

    % Itt szandekosan nem a bessTotalInternalLoss_kWh mezot hasznaljuk,
    % mert az SoC limit / ures-tele miatti nem hasznosult request veszteseggel
    % nagyon nagyra tud noni. A fizikai belso akkuveszteseghez a cell loss a
    % megfelelobb riportmező.
    T.reportBessInternalLoss_MWh = ...
        local_col(T, 'bessCellLoss_kWh', zeros(n, 1)) ./ 1000;

    T.reportCurtailment_MWh = ...
        local_col(T, 'curtailment_kWh', zeros(n, 1)) ./ 1000;

    % ---------------------------------------------------------------------
    % Technikai mutatok fallback mezokkel
    % ---------------------------------------------------------------------
    if ~ismember('selfConsumption_pct', T.Properties.VariableNames)
        T.selfConsumption_pct = 100 * local_col(T, 'selfConsumptionRatio', zeros(n, 1));
    end

    if ~ismember('selfSufficiency_pct', T.Properties.VariableNames)
        T.selfSufficiency_pct = 100 * local_col(T, 'selfSufficiencyRatio', zeros(n, 1));
    end

    if ~ismember('annualBessEquivalentCycles', T.Properties.VariableNames)
        T.annualBessEquivalentCycles = local_col(T, 'bessEquivalentCycles', zeros(n, 1)) ./ simYears;
    end
end


function importPrice = local_get_import_price(T, cfg)

    n = height(T);

    if isfield(cfg, 'cost') && isfield(cfg.cost, 'grid_import_huf_per_kWh')
        importPrice = repmat(cfg.cost.grid_import_huf_per_kWh, n, 1);
        return;
    end

    if ismember('gridOnlyEnergyCost_HUF', T.Properties.VariableNames) && ...
       ismember('loadEnergy_kWh', T.Properties.VariableNames)
        importPrice = T.gridOnlyEnergyCost_HUF ./ max(T.loadEnergy_kWh, eps);
        importPrice(~isfinite(importPrice)) = 0;
        return;
    end

    error('Cannot determine grid import price for BESS-only value calculation.');
end


function x = local_col(T, name, defaultValue)

    if ismember(name, T.Properties.VariableNames)
        x = T.(name);
    else
        x = defaultValue;
    end

    x = double(x);
end


% =========================================================================
% CANDIDATE SELECTION
% =========================================================================
function selected = local_select_report_candidates(T)

    validBase = logical(T.wasSimulated) & ~logical(T.hasError);

    pvOnlyMask = validBase & T.E_BESS_kWh <= 1e-9;

    onlyPv = local_pick_best_row(T, pvOnlyMask, 'LCSE_HUF_per_kWh_saved', 'min', []);

    dcBessMask = validBase & T.Coupling == "dc" & T.E_BESS_kWh > 1e-9;
    acBessMask = validBase & T.Coupling == "ac" & T.E_BESS_kWh > 1e-9;

    dcBestLcse = local_pick_best_row(T, dcBessMask, 'LCSE_HUF_per_kWh_saved', 'min', []);
    dcBestNpv = local_pick_best_row(T, dcBessMask, 'NPV_millionHUF', 'max', dcBestLcse);

    acBestLcse = local_pick_best_row(T, acBessMask, 'LCSE_HUF_per_kWh_saved', 'min', []);
    acBestNpv = local_pick_best_row(T, acBessMask, 'NPV_millionHUF', 'max', acBestLcse);

    selectedTable = [onlyPv; dcBestLcse; dcBestNpv; acBestLcse; acBestNpv];

    labels = [ ...
        "Legjobb csak PV"; ...
        "Legjobb DC - LCSE"; ...
        "Legjobb DC - NPV"; ...
        "Legjobb AC - LCSE"; ...
        "Legjobb AC - NPV"];

    shortLabels = [ ...
        "Csak PV"; ...
        "DC LCSE"; ...
        "DC NPV"; ...
        "AC LCSE"; ...
        "AC NPV"];

    selectedTable.SelectionLabel = labels;
    selectedTable = movevars(selectedTable, 'SelectionLabel', 'Before', 1);

    selected = struct();
    selected.table = selectedTable;
    selected.labels = labels;
    selected.shortLabels = shortLabels;
end


function row = local_pick_best_row(T, mask, metricField, direction, excludedRow)

    if ~ismember(metricField, T.Properties.VariableNames)
        error('Missing metric field for candidate selection: %s', metricField);
    end

    valid = mask(:) & isfinite(T.(metricField));

    if ~isempty(excludedRow) && height(excludedRow) == 1
        sameRow = T.Coupling == excludedRow.Coupling & ...
            T.candidateIndex == excludedRow.candidateIndex;

        validWithExclusion = valid & ~sameRow;

        if any(validWithExclusion)
            valid = validWithExclusion;
        end
    end

    if ~any(valid)
        error('No valid candidate found for metric %s.', metricField);
    end

    values = T.(metricField);

    switch string(direction)
        case "min"
            values(~valid) = inf;
            [~, idx] = min(values);
        case "max"
            values(~valid) = -inf;
            [~, idx] = max(values);
        otherwise
            error('Unknown direction: %s', string(direction));
    end

    row = T(idx, :);
end


% =========================================================================
% TABLES
% =========================================================================
function S = local_build_selected_summary_table(T, labels)

    S = table();
    S.Selection = labels(:);
    S.Coupling = T.Coupling;
    S.candidateIndex = T.candidateIndex;

    S.P_inv_kW = T.P_inv_kW;
    S.DCAC_ratio = T.DCAC_ratio;
    S.BESS_PV_ratio_kWh_per_kWp = T.BESS_PV_ratio;
    S.P_PV_kWp = T.P_PV_kW;
    S.E_BESS_kWh = T.E_BESS_kWh;
    S.P_BESS_kW = T.P_BESS_kW;

    S.Load_MWh_total = T.loadEnergy_kWh ./ 1000;
    S.PV_available_MWh_total = T.pvEnergyAvailable_kWh ./ 1000;
    S.PV_to_load_MWh_total = T.pvToLoad_kWh ./ 1000;
    S.PV_to_BESS_MWh_total = T.pvToBess_kWh ./ 1000;
    S.BESS_to_load_MWh_total = T.bessToLoad_kWh ./ 1000;
    S.Grid_import_MWh_total = T.gridImport_kWh ./ 1000;
    S.Curtailment_MWh_total = T.curtailment_kWh ./ 1000;

    S.Grid_import_reduction_pct = T.gridImportReduction_pct;
    S.Self_consumption_pct = T.selfConsumption_pct;
    S.Self_sufficiency_pct = T.selfSufficiency_pct;
    S.Curtailment_pct = T.curtailment_pct;
    S.Equivalent_cycles_per_year = T.annualBessEquivalentCycles;
    S.Final_SoH = T.finalSoH;

    S.Initial_CAPEX_millionHUF = T.initialCapex_HUF ./ 1e6;
    S.PV_CAPEX_millionHUF = T.capexPV_HUF ./ 1e6;
    S.Inverter_CAPEX_millionHUF = T.capexInverter_HUF ./ 1e6;
    S.BESS_CAPEX_millionHUF = T.capexBESS_HUF ./ 1e6;

    S.Period_energy_cost_saving_millionHUF = T.reportPeriodCostSaving_HUF ./ 1e6;
    S.Period_PV_CAPEX_millionHUF = T.reportPeriodPVCapex_HUF ./ 1e6;
    S.Period_PV_OPEX_millionHUF = T.reportPeriodPVOpex_HUF ./ 1e6;
    S.Period_inverter_CAPEX_millionHUF = T.reportPeriodInverterCapex_HUF ./ 1e6;
    S.Period_inverter_OPEX_millionHUF = T.reportPeriodInverterOpex_HUF ./ 1e6;
    S.Period_BESS_degradation_CAPEX_millionHUF = T.reportPeriodBessDegradation_HUF ./ 1e6;
    S.Period_BESS_OPEX_millionHUF = T.reportPeriodBessOpex_HUF ./ 1e6;
    S.Period_net_value_millionHUF = T.reportPeriodNetValue_HUF ./ 1e6;

    S.BESS_AC_energy_saving_millionHUF = T.reportPeriodBessAcSaving_HUF ./ 1e6;
    S.BESS_only_cost_millionHUF = T.reportPeriodBessOnlyCost_HUF ./ 1e6;
    S.BESS_only_net_value_millionHUF = T.reportPeriodBessOnlyNetValue_HUF ./ 1e6;

    S.LCSE_HUF_per_kWh_saved = T.LCSE_HUF_per_kWh_saved;
    S.NPV_millionHUF = T.NPV_millionHUF;
    S.NPV_BESSOnly_millionHUF = T.NPV_BESSOnly_millionHUF;
    S.Simple_payback_year = T.simplePayback_year;
    S.Discounted_payback_year = T.discountedPayback_year;
end


function B = local_build_bess_only_table(T, labels)

    B = table();
    B.Selection = labels(:);
    B.Coupling = T.Coupling;
    B.candidateIndex = T.candidateIndex;
    B.E_BESS_kWh = T.E_BESS_kWh;
    B.P_BESS_kW = T.P_BESS_kW;
    B.BESS_to_load_MWh_total = T.bessToLoad_kWh ./ 1000;
    B.BESS_AC_energy_saving_millionHUF = T.reportPeriodBessAcSaving_HUF ./ 1e6;
    B.BESS_degradation_CAPEX_millionHUF = T.reportPeriodBessDegradation_HUF ./ 1e6;
    B.BESS_OPEX_millionHUF = T.reportPeriodBessOpex_HUF ./ 1e6;
    B.BESS_only_net_value_millionHUF = T.reportPeriodBessOnlyNetValue_HUF ./ 1e6;
end


% =========================================================================
% PLOTS - 3D METRIC MAPS
% =========================================================================
function local_plot_3d_metric(T, metricField, metricLabel, metricUnit, direction, figureFolder, coupling)

    if ~ismember(metricField, T.Properties.VariableNames)
        error('Missing metric field for 3D plot: %s', metricField);
    end

    valid = ...
        logical(T.wasSimulated) & ...
        ~logical(T.hasError) & ...
        isfinite(T.P_inv_kW) & ...
        isfinite(T.DCAC_ratio) & ...
        isfinite(T.BESS_PV_ratio) & ...
        isfinite(T.(metricField));

    if ~any(valid)
        error('No valid data for 3D plot: %s %s.', string(coupling), metricField);
    end

    bestRow = local_pick_best_row(T, valid, metricField, direction, []);

    fig = figure('Name', sprintf('%s %s 3D map', upper(char(coupling)), metricField), ...
        'Position', [80, 80, 1250, 850]);

    ax = axes(fig);
    hold(ax, 'on');
    grid(ax, 'on');
    box(ax, 'on');

    scatter3(ax, ...
        T.P_inv_kW(valid), ...
        T.DCAC_ratio(valid), ...
        T.BESS_PV_ratio(valid), ...
        55, ...
        T.(metricField)(valid), ...
        'filled');

    plot3(ax, ...
        bestRow.P_inv_kW, ...
        bestRow.DCAC_ratio, ...
        bestRow.BESS_PV_ratio, ...
        'kp', ...
        'MarkerSize', 18, ...
        'MarkerFaceColor', 'w', ...
        'LineWidth', 2.0);

    text(ax, ...
        bestRow.P_inv_kW, ...
        bestRow.DCAC_ratio, ...
        bestRow.BESS_PV_ratio, ...
        sprintf('  legjobb: C%d', bestRow.candidateIndex), ...
        'FontWeight', 'bold', ...
        'Interpreter', 'none');

    xlabel(ax, 'Inverter nevleges teljesitmeny [kW]');
    ylabel(ax, 'DC/AC arany [-]');
    zlabel(ax, 'BESS/PV arany [kWh/kWp]');

    title(ax, sprintf('%s-csatolt: %s', upper(char(coupling)), metricLabel), ...
        'Interpreter', 'none');

    cb = colorbar(ax);
    cb.Label.String = sprintf('%s [%s]', metricLabel, metricUnit);

    colormap(ax, local_green_yellow_red_colormap(direction, 256));
    view(ax, 45, 25);

    local_save_figure(fig, figureFolder, sprintf('scatter3_%s_%s', char(coupling), metricField));
end


% =========================================================================
% PLOTS - SELECTED CANDIDATES
% =========================================================================
function local_plot_value_cost_payback_summary(T, xLabels, figureFolder)

    fig = figure('Name', 'AC/DC selected value cost payback summary', ...
        'Position', [50, 40, 1550, 1250]);

    tiledlayout(fig, 4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    x = 1:height(T);

    % ---------------------------------------------------------------------
    % 1) Rendszer hozzaadott erteke a teljes szimulalt idoszakra
    % ---------------------------------------------------------------------
    ax1 = nexttile;
    hold(ax1, 'on');
    grid(ax1, 'on');
    box(ax1, 'on');

    saving_mHUF = T.reportPeriodCostSaving_HUF ./ 1e6;
    bar(ax1, x, saving_mHUF, 'BarWidth', 0.65);
    yline(ax1, 0, 'k-', 'LineWidth', 1.0);

    ylabel(ax1, 'millio Ft');
    title(ax1, 'Rendszer hozzaadott erteke - energiakoltseg-megtakaritas a szimulalt idoszakra');
    xticks(ax1, x);
    xticklabels(ax1, cellstr(xLabels));

    local_add_bar_value_labels(ax1, x, saving_mHUF);

    % ---------------------------------------------------------------------
    % 2) Periodusra allokalt beruhazasi es OPEX komponensek
    % ---------------------------------------------------------------------
    ax2 = nexttile;
    hold(ax2, 'on');
    grid(ax2, 'on');
    box(ax2, 'on');

    costData_mHUF = [ ...
        T.reportPeriodPVCapex_HUF, ...
        T.reportPeriodPVOpex_HUF, ...
        T.reportPeriodInverterCapex_HUF, ...
        T.reportPeriodInverterOpex_HUF, ...
        T.reportPeriodBessDegradation_HUF, ...
        T.reportPeriodBessOpex_HUF] ./ 1e6;

    bar(ax2, x, costData_mHUF, 'stacked', 'BarWidth', 0.65);

    ylabel(ax2, 'millio Ft');
    title(ax2, 'Szimulalt idoszakra allokalt beruhazasi es uzemeltetesi koltsegek');
    xticks(ax2, x);
    xticklabels(ax2, cellstr(xLabels));

    legend(ax2, { ...
        'PV CAPEX / lifetime', ...
        'PV OPEX', ...
        'Inverter CAPEX / lifetime', ...
        'Inverter OPEX', ...
        'BESS degradacios CAPEX', ...
        'BESS OPEX'}, ...
        'Location', 'bestoutside');

    % ---------------------------------------------------------------------
    % 3) Netto periodusertek
    % ---------------------------------------------------------------------
    ax3 = nexttile;
    hold(ax3, 'on');
    grid(ax3, 'on');
    box(ax3, 'on');

    periodNet_mHUF = T.reportPeriodNetValue_HUF ./ 1e6;
    bar(ax3, x, periodNet_mHUF, 'BarWidth', 0.65);
    yline(ax3, 0, 'k-', 'LineWidth', 1.0);

    ylabel(ax3, 'millio Ft');
    title(ax3, 'Megterulesi ertek a szimulalt idoszakra - pozitiv ertek eseten gazdasagilag kedvezo');
    xticks(ax3, x);
    xticklabels(ax3, cellstr(xLabels));

    local_add_bar_value_labels(ax3, x, periodNet_mHUF);

    % ---------------------------------------------------------------------
    % 4) BESS-only periodusertek
    % ---------------------------------------------------------------------
    ax4 = nexttile;
    hold(ax4, 'on');
    grid(ax4, 'on');
    box(ax4, 'on');

    bessValueStack_mHUF = [ ...
        T.reportPeriodBessAcSaving_HUF, ...
        -T.reportPeriodBessDegradation_HUF, ...
        -T.reportPeriodBessOpex_HUF] ./ 1e6;

    bar(ax4, x, bessValueStack_mHUF, 'stacked', 'BarWidth', 0.65);

    bessNet_mHUF = T.reportPeriodBessOnlyNetValue_HUF ./ 1e6;

    plot(ax4, x, bessNet_mHUF, 'k-o', ...
        'LineWidth', 1.6, ...
        'MarkerSize', 5, ...
        'DisplayName', 'BESS-only netto ertek');

    yline(ax4, 0, 'k-', 'LineWidth', 1.0);

    ylabel(ax4, 'millio Ft');
    title(ax4, 'BESS-only vizsgalat: BESS AC energiaertek - BESS degradacios CAPEX - BESS OPEX');
    xticks(ax4, x);
    xticklabels(ax4, cellstr(xLabels));

    legend(ax4, { ...
        'BESS -> fogyaszto AC energia megtakaritasa', ...
        'BESS degradacios CAPEX', ...
        'BESS OPEX', ...
        'BESS-only netto ertek'}, ...
        'Location', 'bestoutside');

    local_add_bar_value_labels(ax4, x, bessNet_mHUF);

    local_save_figure(fig, figureFolder, 'acdc_selected_value_cost_payback_summary');
end


function local_plot_self_consumption_summary(T, xLabels, figureFolder)

    fig = figure('Name', 'AC/DC selected technical summary', ...
        'Position', [80, 80, 1400, 900]);

    tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    x = 1:height(T);

    metrics = { ...
        'selfConsumption_pct', 'Onfogyasztasi arany', '%'; ...
        'selfSufficiency_pct', 'Onellatasi arany', '%'; ...
        'annualBessEquivalentCycles', 'Eves ekvivalens BESS ciklusszam', 'ciklus/ev'};

    for k = 1:size(metrics, 1)
        ax = nexttile;
        hold(ax, 'on');
        grid(ax, 'on');
        box(ax, 'on');

        fieldName = metrics{k, 1};
        values = T.(fieldName);

        bar(ax, x, values, 'BarWidth', 0.65);
        ylabel(ax, metrics{k, 3});
        title(ax, metrics{k, 2});
        xticks(ax, x);
        xticklabels(ax, cellstr(xLabels));

        local_add_bar_value_labels(ax, x, values);
    end

    local_save_figure(fig, figureFolder, 'acdc_selected_self_consumption_summary');
end


function local_plot_useful_energy_and_losses(T, xLabels, figureFolder)

    fig = figure('Name', 'AC/DC selected useful AC energy and losses', ...
        'Position', [100, 90, 1500, 800]);

    ax = axes(fig);
    hold(ax, 'on');
    grid(ax, 'on');
    box(ax, 'on');

    x = 1:height(T);

    energyData_MWh = [ ...
        T.reportUsefulACEnergy_MWh, ...
        T.reportInverterLoss_MWh, ...
        T.reportDcdcLoss_MWh, ...
        T.reportBessInternalLoss_MWh, ...
        T.reportCurtailment_MWh];

    bar(ax, x, energyData_MWh, 'stacked', 'BarWidth', 0.65);

    ylabel(ax, 'MWh / szimulalt idoszak');
    title(ax, 'Hasznos AC energia es fo vesztesegkomponensek');
    xticks(ax, x);
    xticklabels(ax, cellstr(xLabels));

    legend(ax, { ...
        'Hasznos AC energia a fogyaszton', ...
        'Inverter veszteseg', ...
        'DC/DC veszteseg', ...
        'BESS cella/belso veszteseg', ...
        'Curtailment'}, ...
        'Location', 'bestoutside');

    local_save_figure(fig, figureFolder, 'acdc_selected_useful_energy_and_losses');
end


% =========================================================================
% PLOT HELPERS
% =========================================================================
function local_add_bar_value_labels(ax, x, values)

    for i = 1:numel(values)
        if ~isfinite(values(i))
            continue;
        end

        if values(i) >= 0
            vAlign = 'bottom';
        else
            vAlign = 'top';
        end

        text(ax, x(i), values(i), ...
            ['  ', char(local_format_number(values(i)))], ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment', vAlign, ...
            'FontSize', 8);
    end
end


function cmap = local_green_yellow_red_colormap(direction, n)

    if nargin < 2
        n = 256;
    end

    red = [0.85, 0.15, 0.15];
    yellow = [1.00, 0.90, 0.15];
    green = [0.15, 0.70, 0.25];

    n1 = floor(n / 2);
    n2 = n - n1;

    switch string(direction)
        case "max"
            c1 = local_interp_color(red, yellow, n1);
            c2 = local_interp_color(yellow, green, n2);
        case "min"
            c1 = local_interp_color(green, yellow, n1);
            c2 = local_interp_color(yellow, red, n2);
        otherwise
            error('Unknown direction: %s', string(direction));
    end

    cmap = [c1; c2];
end


function C = local_interp_color(cStart, cEnd, n)

    t = linspace(0, 1, n).';
    C = (1 - t) .* cStart + t .* cEnd;
end


function s = local_format_number(x)

    if ~isfinite(x)
        if isinf(x)
            s = "Inf";
        else
            s = "NaN";
        end
        return;
    end

    ax = abs(x);

    if ax >= 1000
        s = string(sprintf('%.0f', x));
    elseif ax >= 100
        s = string(sprintf('%.1f', x));
    elseif ax >= 10
        s = string(sprintf('%.1f', x));
    elseif ax >= 1
        s = string(sprintf('%.2f', x));
    else
        s = string(sprintf('%.3f', x));
    end
end


function local_save_figure(fig, figureFolder, fileName)

    if ~exist(figureFolder, 'dir')
        mkdir(figureFolder);
    end

    savefig(fig, fullfile(figureFolder, [fileName, '.fig']));

    try
        exportgraphics(fig, fullfile(figureFolder, [fileName, '.png']), 'Resolution', 150);
    catch
        saveas(fig, fullfile(figureFolder, [fileName, '.png']));
    end
end
