function acdcResult = finalize_acdc_summary_outputs(acdcResult, cfg)
% FINALIZE_ACDC_SUMMARY_OUTPUTS
%
% Vegso AC/DC riportgenerator.
%
% Cel:
%   - bezarja a korabbi, mar nem vegleges AC/DC figure ablakokat,
%   - ujrageneralja a vegleges osszesito abrakat egyertelmu x tengely feliratokkal,
%   - minden jeloltnel kiirja a PV es BESS meretet,
%   - a heatmapeket kozos DC/AC tengely- es szintartomannyal kesziti,
%   - plusz heatmapeket keszit onfogyasztasra, onellatasra es hasznos AC energiara.

    if nargin < 1 || isempty(acdcResult)
        error('acdcResult input is required.');
    end

    if nargin < 2
        cfg = struct();
    end

    if ~isfield(acdcResult, 'combinedTable')
        error('acdcResult.combinedTable is missing.');
    end

    if ~isfield(acdcResult, 'outputFolder')
        error('acdcResult.outputFolder is missing.');
    end

    % A regi, kozben megnyitott figure-ok ne maradjanak nyitva.
    close all force;

    outputFolder = acdcResult.outputFolder;
    figureFolder = fullfile(outputFolder, 'figures');
    tableFolder = fullfile(outputFolder, 'tables');

    if ~exist(figureFolder, 'dir')
        mkdir(figureFolder);
    end

    if ~exist(tableFolder, 'dir')
        mkdir(tableFolder);
    end

    econ = local_get_economics(acdcResult);

    T = acdcResult.combinedTable;
    T = local_recalculate_period_metrics(T, cfg, econ);

    selected = local_select_report_candidates(T);
    selectedTable = selected.table;
    selectedLabels = selected.labels;
    selectedAxisLabels = local_candidate_axis_labels(selectedTable);

    selectedSummaryTable = local_build_selected_summary_table(selectedTable, selectedLabels, selectedAxisLabels);
    bessOnlyTable = local_build_bess_only_table(selectedTable, selectedLabels, selectedAxisLabels);

    % Vegleges 5-jeloltes abrak.
    local_plot_value_cost_payback_summary(selectedTable, selectedAxisLabels, figureFolder);
    local_plot_self_consumption_summary(selectedTable, selectedAxisLabels, figureFolder);
    local_plot_useful_energy_and_losses(selectedTable, selectedAxisLabels, figureFolder);

    % Vegleges 3D scatterek. Az NPV itt mar a szimulalt idoszakra vonatkozik.
    local_plot_3d_metric(T(T.Coupling == "dc", :), 'LCSE_HUF_per_kWh_saved', ...
        'LCSE - megtakaritott energia fajlagos koltsege', 'Ft/kWh', 'min', figureFolder, 'dc');

    local_plot_3d_metric(T(T.Coupling == "ac", :), 'LCSE_HUF_per_kWh_saved', ...
        'LCSE - megtakaritott energia fajlagos koltsege', 'Ft/kWh', 'min', figureFolder, 'ac');

    local_plot_3d_metric(T(T.Coupling == "dc", :), 'NPV_millionHUF', ...
        'NPV a szimulalt idoszakra', 'millio Ft', 'max', figureFolder, 'dc');

    local_plot_3d_metric(T(T.Coupling == "ac", :), 'NPV_millionHUF', ...
        'NPV a szimulalt idoszakra', 'millio Ft', 'max', figureFolder, 'ac');

    % Heatmapek a legkisebb invertermeret mellett. Egy figure-on belul a DC es AC
    % subplot azonos tengely- es szintartomanyt hasznal.
    local_plot_min_inverter_heatmap_pair(T, 'NPV_millionHUF', ...
        'NPV a szimulalt idoszakra', 'millio Ft', 'max', figureFolder, 'heatmap_min_inverter_npv');

    lcoeField = local_find_first_existing_field(T, { ...
        'LCOE_usefulPV_HUF_per_kWh', ...
        'LCOE_HUF_per_kWh'});

    if strlength(lcoeField) > 0
        local_plot_min_inverter_heatmap_pair(T, char(lcoeField), ...
            'LCOE', 'Ft/kWh', 'min', figureFolder, 'heatmap_min_inverter_lcoe');
    else
        warning('finalize_acdc_summary_outputs:missingLCOE', ...
            'Nem talaltam LCOE mezot, ezert LCOE heatmap nem keszult.');
    end

    local_plot_min_inverter_heatmap_pair(T, 'NPV_BESSOnly_millionHUF', ...
        'BESS-only NPV a szimulalt idoszakra', 'millio Ft', 'max', figureFolder, 'heatmap_min_inverter_bess_only_npv');

    local_plot_min_inverter_heatmap_pair(T, 'selfConsumption_pct', ...
        'Onfogyasztasi arany', '%', 'max', figureFolder, 'heatmap_min_inverter_self_consumption');

    local_plot_min_inverter_heatmap_pair(T, 'selfSufficiency_pct', ...
        'Onellatasi arany', '%', 'max', figureFolder, 'heatmap_min_inverter_self_sufficiency');

    local_plot_min_inverter_heatmap_pair(T, 'reportUsefulACEnergy_MWh', ...
        'Hasznos AC energia', 'MWh', 'max', figureFolder, 'heatmap_min_inverter_useful_ac_energy');

    % Tablazatok frissitese.
    writetable(T, fullfile(tableFolder, 'acdc_combined_candidate_table.csv'));
    writetable(selectedSummaryTable, fullfile(tableFolder, 'acdc_selected_candidates_summary.csv'));
    writetable(bessOnlyTable, fullfile(tableFolder, 'acdc_selected_bess_only_period_value_table.csv'));

    acdcResult.combinedTable = T;
    acdcResult.selectedTable = selectedTable;
    acdcResult.selectedSummaryTable = selectedSummaryTable;
    acdcResult.selectedBessOnlyValueTable = bessOnlyTable;
    acdcResult.selectedAxisLabels = selectedAxisLabels;
    acdcResult.periodNpvDefinition = "energyCostSavings_HUF - period allocated PV/inverter/BESS CAPEX and OPEX";

    save(fullfile(outputFolder, 'evaluation_acdc_summary_result.mat'), ...
        'acdcResult', '-v7.3');

    fprintf('\nFinal AC/DC summary figures regenerated.\n');
end


% =========================================================================
% PERIOD METRICS
% =========================================================================
function econ = local_get_economics(acdcResult)

    if isfield(acdcResult, 'dcEvaluation') && ...
       isfield(acdcResult.dcEvaluation, 'evalCfg') && ...
       isfield(acdcResult.dcEvaluation.evalCfg, 'economics')
        econ = acdcResult.dcEvaluation.evalCfg.economics;
        return;
    end

    if isfield(acdcResult, 'acEvaluation') && ...
       isfield(acdcResult.acEvaluation, 'evalCfg') && ...
       isfield(acdcResult.acEvaluation.evalCfg, 'economics')
        econ = acdcResult.acEvaluation.evalCfg.economics;
        return;
    end

    error('Cannot determine economics settings from acdcResult.');
end


function T = local_recalculate_period_metrics(T, cfg, econ)

    simYears = econ.simYears;
    pvLifetime = econ.pvLifetime_years;
    inverterLifetime = econ.inverterLifetime_years;

    if simYears <= 0
        error('econ.simYears must be positive.');
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

    T.reportSimYears = repmat(simYears, n, 1);
    T.reportDeltaSoH = deltaSoH;

    T.reportPeriodPVCapex_HUF = capexPV ./ pvLifetime .* simYears;
    T.reportPeriodPVOpex_HUF = capexPV .* econ.pv_opex_frac_per_year .* simYears;

    T.reportPeriodInverterCapex_HUF = capexInv ./ inverterLifetime .* simYears;
    T.reportPeriodInverterOpex_HUF = capexInv .* econ.inverter_opex_frac_per_year .* simYears;

    T.reportPeriodBessDegradation_HUF = (deltaSoH ./ 0.2) .* capexBess;
    T.reportPeriodBessOpex_HUF = capexBess .* econ.bess_opex_frac_per_year .* simYears;

    T.reportPeriodInvestmentCost_HUF = ...
        T.reportPeriodPVCapex_HUF + ...
        T.reportPeriodPVOpex_HUF + ...
        T.reportPeriodInverterCapex_HUF + ...
        T.reportPeriodInverterOpex_HUF + ...
        T.reportPeriodBessDegradation_HUF + ...
        T.reportPeriodBessOpex_HUF;

    T.reportPeriodCostSaving_HUF = local_col(T, 'energyCostSavings_HUF', zeros(n, 1));
    T.reportPeriodNetValue_HUF = T.reportPeriodCostSaving_HUF - T.reportPeriodInvestmentCost_HUF;

    importPrice_HUF_per_kWh = local_get_import_price(T, cfg);

    T.reportPeriodBessAcSaving_HUF = local_col(T, 'bessToLoad_kWh', zeros(n, 1)) .* importPrice_HUF_per_kWh;
    T.reportPeriodBessAcSaving_HUF(~hasBess) = 0;

    T.reportPeriodBessOnlyCost_HUF = T.reportPeriodBessDegradation_HUF + T.reportPeriodBessOpex_HUF;
    T.reportPeriodBessOnlyNetValue_HUF = T.reportPeriodBessAcSaving_HUF - T.reportPeriodBessOnlyCost_HUF;

    if ismember('NPV_millionHUF', T.Properties.VariableNames) && ...
       ~ismember('NPV_projectLifetime_original_millionHUF', T.Properties.VariableNames)
        T.NPV_projectLifetime_original_millionHUF = T.NPV_millionHUF;
    end

    if ismember('NPV_BESSOnly_millionHUF', T.Properties.VariableNames) && ...
       ~ismember('NPV_BESSOnly_projectLifetime_original_millionHUF', T.Properties.VariableNames)
        T.NPV_BESSOnly_projectLifetime_original_millionHUF = T.NPV_BESSOnly_millionHUF;
    end

    T.NPV_millionHUF = T.reportPeriodNetValue_HUF ./ 1e6;
    T.NPV_BESSOnly_millionHUF = T.reportPeriodBessOnlyNetValue_HUF ./ 1e6;

    T.reportUsefulACEnergy_MWh = ...
        (local_col(T, 'pvToLoad_kWh', zeros(n, 1)) + ...
         local_col(T, 'bessToLoad_kWh', zeros(n, 1))) ./ 1000;

    invLoss = local_col(T, 'inverterConversionLoss_kWh', zeros(n, 1));

    if all(abs(invLoss) < 1e-12)
        invLoss = local_col(T, 'inverterLoss_kWh', zeros(n, 1));
    end

    T.reportInverterLoss_MWh = invLoss ./ 1000;
    T.reportDcdcLoss_MWh = local_col(T, 'dcdcConversionLoss_kWh', zeros(n, 1)) ./ 1000;
    T.reportBessInternalLoss_MWh = local_col(T, 'bessCellLoss_kWh', zeros(n, 1)) ./ 1000;
    T.reportCurtailment_MWh = local_col(T, 'curtailment_kWh', zeros(n, 1)) ./ 1000;

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
% CANDIDATE SELECTION AND LABELS
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
        "Legjobb DC - periodus NPV"; ...
        "Legjobb AC - LCSE"; ...
        "Legjobb AC - periodus NPV"];

    selectedTable.SelectionLabel = labels;
    selectedTable = movevars(selectedTable, 'SelectionLabel', 'Before', 1);

    selected = struct();
    selected.table = selectedTable;
    selected.labels = labels;
end


function row = local_pick_best_row(T, mask, metricField, direction, excludedRow)

    if ~ismember(metricField, T.Properties.VariableNames)
        error('Missing metric field for candidate selection: %s', metricField);
    end

    valid = mask(:) & isfinite(T.(metricField));

    if ~isempty(excludedRow) && height(excludedRow) == 1
        sameRow = T.Coupling == excludedRow.Coupling & T.candidateIndex == excludedRow.candidateIndex;
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


function labels = local_candidate_axis_labels(T)

    labels = strings(height(T), 1);

    for i = 1:height(T)
        pvSize = T.P_PV_kW(i);
        bessSize = T.E_BESS_kWh(i);

        if bessSize <= 1e-9
            labels(i) = string(sprintf('Csak PV | PV: %.0f kWp | BESS: 0 kWh', pvSize));
        else
            labels(i) = string(sprintf('%s | PV: %.0f kWp | BESS: %.0f kWh', ...
                upper(char(T.Coupling(i))), pvSize, bessSize));
        end
    end
end


% =========================================================================
% TABLES
% =========================================================================
function S = local_build_selected_summary_table(T, labels, axisLabels)

    S = table();
    S.Selection = labels(:);
    S.AxisLabel = axisLabels(:);
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
    S.NPV_simulatedPeriod_millionHUF = T.NPV_millionHUF;
    S.NPV_BESSOnly_simulatedPeriod_millionHUF = T.NPV_BESSOnly_millionHUF;
    S.Simple_payback_year = T.simplePayback_year;
    S.Discounted_payback_year = T.discountedPayback_year;
end


function B = local_build_bess_only_table(T, labels, axisLabels)

    B = table();
    B.Selection = labels(:);
    B.AxisLabel = axisLabels(:);
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
% SELECTED CANDIDATE PLOTS
% =========================================================================
function local_plot_value_cost_payback_summary(T, xLabels, figureFolder)

    fig = figure('Name', 'AC/DC selected value cost payback summary', ...
        'Position', [50, 40, 1650, 1250]);

    tiledlayout(fig, 4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    x = 1:height(T);

    ax1 = nexttile;
    hold(ax1, 'on'); grid(ax1, 'on'); box(ax1, 'on');
    saving_mHUF = T.reportPeriodCostSaving_HUF ./ 1e6;
    bar(ax1, x, saving_mHUF, 'BarWidth', 0.65);
    yline(ax1, 0, 'k-', 'LineWidth', 1.0);
    ylabel(ax1, 'millio Ft');
    title(ax1, 'Rendszer hozzaadott erteke - energiakoltseg-megtakaritas a szimulalt idoszakra');
    local_apply_xlabels(ax1, x, xLabels);
    local_add_bar_value_labels(ax1, x, saving_mHUF);

    ax2 = nexttile;
    hold(ax2, 'on'); grid(ax2, 'on'); box(ax2, 'on');
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
    local_apply_xlabels(ax2, x, xLabels);
    legend(ax2, {'PV CAPEX / lifetime', 'PV OPEX', 'Inverter CAPEX / lifetime', ...
        'Inverter OPEX', 'BESS degradacios CAPEX', 'BESS OPEX'}, ...
        'Location', 'bestoutside');

    ax3 = nexttile;
    hold(ax3, 'on'); grid(ax3, 'on'); box(ax3, 'on');
    periodNet_mHUF = T.reportPeriodNetValue_HUF ./ 1e6;
    bar(ax3, x, periodNet_mHUF, 'BarWidth', 0.65);
    yline(ax3, 0, 'k-', 'LineWidth', 1.0);
    ylabel(ax3, 'millio Ft');
    title(ax3, 'Megterulesi ertek a szimulalt idoszakra - pozitiv ertek eseten gazdasagilag kedvezo');
    local_apply_xlabels(ax3, x, xLabels);
    local_add_bar_value_labels(ax3, x, periodNet_mHUF);

    ax4 = nexttile;
    hold(ax4, 'on'); grid(ax4, 'on'); box(ax4, 'on');
    bessValueStack_mHUF = [ ...
        T.reportPeriodBessAcSaving_HUF, ...
        -T.reportPeriodBessDegradation_HUF, ...
        -T.reportPeriodBessOpex_HUF] ./ 1e6;
    bar(ax4, x, bessValueStack_mHUF, 'stacked', 'BarWidth', 0.65);
    bessNet_mHUF = T.reportPeriodBessOnlyNetValue_HUF ./ 1e6;
    plot(ax4, x, bessNet_mHUF, 'k-o', 'LineWidth', 1.6, 'MarkerSize', 5);
    yline(ax4, 0, 'k-', 'LineWidth', 1.0);
    ylabel(ax4, 'millio Ft');
    title(ax4, 'BESS-only vizsgalat: BESS AC energiaertek - BESS degradacios CAPEX - BESS OPEX');
    local_apply_xlabels(ax4, x, xLabels);
    legend(ax4, {'BESS -> fogyaszto AC energia megtakaritasa', ...
        'BESS degradacios CAPEX', 'BESS OPEX', 'BESS-only netto ertek'}, ...
        'Location', 'bestoutside');
    local_add_bar_value_labels(ax4, x, bessNet_mHUF);

    local_save_figure(fig, figureFolder, 'acdc_selected_value_cost_payback_summary');
end


function local_plot_self_consumption_summary(T, xLabels, figureFolder)

    fig = figure('Name', 'AC/DC selected technical summary', ...
        'Position', [80, 80, 1550, 900]);

    tiledlayout(fig, 3, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    x = 1:height(T);

    metrics = { ...
        'selfConsumption_pct', 'Onfogyasztasi arany', '%'; ...
        'selfSufficiency_pct', 'Onellatasi arany', '%'; ...
        'annualBessEquivalentCycles', 'Eves ekvivalens BESS ciklusszam', 'ciklus/ev'};

    for k = 1:size(metrics, 1)
        ax = nexttile;
        hold(ax, 'on'); grid(ax, 'on'); box(ax, 'on');
        fieldName = metrics{k, 1};
        values = T.(fieldName);
        bar(ax, x, values, 'BarWidth', 0.65);
        ylabel(ax, metrics{k, 3});
        title(ax, metrics{k, 2});
        local_apply_xlabels(ax, x, xLabels);
        local_add_bar_value_labels(ax, x, values);
    end

    local_save_figure(fig, figureFolder, 'acdc_selected_self_consumption_summary');
end


function local_plot_useful_energy_and_losses(T, xLabels, figureFolder)

    fig = figure('Name', 'AC/DC selected useful AC energy and losses', ...
        'Position', [100, 90, 1550, 800]);

    ax = axes(fig);
    hold(ax, 'on'); grid(ax, 'on'); box(ax, 'on');

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
    local_apply_xlabels(ax, x, xLabels);

    legend(ax, {'Hasznos AC energia a fogyaszton', 'Inverter veszteseg', ...
        'DC/DC veszteseg', 'BESS cella/belso veszteseg', 'Curtailment'}, ...
        'Location', 'bestoutside');

    local_save_figure(fig, figureFolder, 'acdc_selected_useful_energy_and_losses');
end


function local_apply_xlabels(ax, x, xLabels)

    xticks(ax, x);
    xticklabels(ax, cellstr(xLabels));
    xtickangle(ax, 18);
    ax.TickLabelInterpreter = 'none';
end


% =========================================================================
% HEATMAPS AND 3D PLOTS
% =========================================================================
function local_plot_min_inverter_heatmap_pair(T, metricField, metricLabel, metricUnit, direction, figureFolder, fileName)

    if ~ismember(metricField, T.Properties.VariableNames)
        warning('Missing metric field for heatmap: %s', metricField);
        return;
    end

    valid = logical(T.wasSimulated) & ~logical(T.hasError) & ...
        isfinite(T.P_inv_kW) & isfinite(T.DCAC_ratio) & ...
        isfinite(T.BESS_PV_ratio) & isfinite(T.(metricField));

    if ~any(valid)
        warning('No valid data for heatmap: %s.', metricField);
        return;
    end

    minInv = min(T.P_inv_kW(valid));
    invTol = max(1e-9, 1e-6 * max(1, abs(minInv)));

    commonMask = valid & abs(T.P_inv_kW - minInv) <= invTol & ...
        (T.Coupling == "dc" | T.Coupling == "ac");

    xVals = unique(T.DCAC_ratio(commonMask));
    yVals = unique(T.BESS_PV_ratio(commonMask));
    metricValues = T.(metricField)(commonMask);
    metricValues = metricValues(isfinite(metricValues));

    if isempty(xVals) || isempty(yVals) || isempty(metricValues)
        warning('No common min-inverter data for heatmap: %s.', metricField);
        return;
    end

    cMin = min(metricValues);
    cMax = max(metricValues);

    if abs(cMax - cMin) < 1e-12
        delta = max(1, abs(cMin) * 0.05);
        cMin = cMin - delta;
        cMax = cMax + delta;
    end

    fig = figure('Name', ['Heatmap min inverter - ', metricField], ...
        'Position', [80, 80, 1450, 650]);

    tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

    couplings = ["dc", "ac"];

    for i = 1:numel(couplings)
        ax = nexttile;
        local_plot_single_heatmap(ax, T, couplings(i), minInv, invTol, ...
            xVals, yVals, [cMin, cMax], metricField, metricLabel, metricUnit, direction);
    end

    sgtitle(fig, sprintf('%s - legkisebb invertermeret: %.0f kW', metricLabel, minInv), ...
        'Interpreter', 'none');

    local_save_figure(fig, figureFolder, fileName);
end


function local_plot_single_heatmap(ax, T, coupling, minInv, invTol, xVals, yVals, colorLimits, metricField, metricLabel, metricUnit, direction)

    mask = T.Coupling == coupling & abs(T.P_inv_kW - minInv) <= invTol & ...
        logical(T.wasSimulated) & ~logical(T.hasError) & isfinite(T.(metricField));

    Z = NaN(numel(yVals), numel(xVals));

    rowIdx = find(mask).';

    for r = rowIdx
        ix = find(abs(xVals - T.DCAC_ratio(r)) < 1e-9, 1);
        iy = find(abs(yVals - T.BESS_PV_ratio(r)) < 1e-9, 1);

        if ~isempty(ix) && ~isempty(iy)
            Z(iy, ix) = T.(metricField)(r);
        end
    end

    imagesc(ax, xVals, yVals, Z);
    set(ax, 'YDir', 'normal');
    hold(ax, 'on'); grid(ax, 'on'); box(ax, 'on');

    if numel(xVals) > 1
        xlim(ax, [min(xVals), max(xVals)]);
    end

    if numel(yVals) > 1
        ylim(ax, [min(yVals), max(yVals)]);
    end

    try
        clim(ax, colorLimits);
    catch
        caxis(ax, colorLimits);
    end

    colormap(ax, local_green_yellow_red_colormap(direction, 256));
    cb = colorbar(ax);
    cb.Label.String = sprintf('%s [%s]', metricLabel, metricUnit);

    xlabel(ax, 'DC/AC arany [-]');
    ylabel(ax, 'BESS/PV arany [kWh/kWp]');
    title(ax, sprintf('%s-csatolt', upper(char(coupling))), 'Interpreter', 'none');

    if numel(Z) <= 120
        for iy = 1:numel(yVals)
            for ix = 1:numel(xVals)
                if isfinite(Z(iy, ix))
                    text(ax, xVals(ix), yVals(iy), char(local_format_number(Z(iy, ix))), ...
                        'HorizontalAlignment', 'center', ...
                        'VerticalAlignment', 'middle', ...
                        'FontSize', 8, ...
                        'Color', 'k');
                end
            end
        end
    end

    if any(isfinite(Z(:)))
        local_mark_best_heatmap_point(ax, T(mask, :), metricField, direction);
    end
end


function local_mark_best_heatmap_point(ax, Tsub, metricField, direction)

    if height(Tsub) == 0
        return;
    end

    values = Tsub.(metricField);

    switch string(direction)
        case "min"
            [~, idx] = min(values);
        case "max"
            [~, idx] = max(values);
        otherwise
            error('Unknown direction: %s', string(direction));
    end

    plot(ax, Tsub.DCAC_ratio(idx), Tsub.BESS_PV_ratio(idx), 'kp', ...
        'MarkerSize', 16, 'MarkerFaceColor', 'w', 'LineWidth', 1.8);
end


function local_plot_3d_metric(T, metricField, metricLabel, metricUnit, direction, figureFolder, coupling)

    if ~ismember(metricField, T.Properties.VariableNames)
        warning('Missing metric field for 3D plot: %s', metricField);
        return;
    end

    valid = logical(T.wasSimulated) & ~logical(T.hasError) & ...
        isfinite(T.P_inv_kW) & isfinite(T.DCAC_ratio) & ...
        isfinite(T.BESS_PV_ratio) & isfinite(T.(metricField));

    if ~any(valid)
        warning('No valid data for 3D plot: %s.', metricField);
        return;
    end

    Tvalid = T(valid, :);
    values = Tvalid.(metricField);

    switch string(direction)
        case "min"
            [~, bestIdx] = min(values);
        case "max"
            [~, bestIdx] = max(values);
        otherwise
            error('Unknown direction: %s', string(direction));
    end

    fig = figure('Name', sprintf('%s %s 3D map', upper(char(coupling)), metricField), ...
        'Position', [80, 80, 1250, 850]);

    ax = axes(fig);
    hold(ax, 'on'); grid(ax, 'on'); box(ax, 'on');

    scatter3(ax, Tvalid.P_inv_kW, Tvalid.DCAC_ratio, Tvalid.BESS_PV_ratio, 55, values, 'filled');

    plot3(ax, Tvalid.P_inv_kW(bestIdx), Tvalid.DCAC_ratio(bestIdx), ...
        Tvalid.BESS_PV_ratio(bestIdx), 'kp', ...
        'MarkerSize', 18, 'MarkerFaceColor', 'w', 'LineWidth', 2.0);

    text(ax, Tvalid.P_inv_kW(bestIdx), Tvalid.DCAC_ratio(bestIdx), ...
        Tvalid.BESS_PV_ratio(bestIdx), sprintf('  legjobb: C%d', Tvalid.candidateIndex(bestIdx)), ...
        'FontWeight', 'bold', 'Interpreter', 'none');

    xlabel(ax, 'Inverter nevleges teljesitmeny [kW]');
    ylabel(ax, 'DC/AC arany [-]');
    zlabel(ax, 'BESS/PV arany [kWh/kWp]');
    title(ax, sprintf('%s-csatolt: %s', upper(char(coupling)), metricLabel), 'Interpreter', 'none');

    cb = colorbar(ax);
    cb.Label.String = sprintf('%s [%s]', metricLabel, metricUnit);
    colormap(ax, local_green_yellow_red_colormap(direction, 256));
    view(ax, 45, 25);

    local_save_figure(fig, figureFolder, sprintf('scatter3_%s_%s', char(coupling), metricField));
end


% =========================================================================
% GENERIC HELPERS
% =========================================================================
function fieldName = local_find_first_existing_field(T, fieldNames)

    fieldName = "";

    for i = 1:numel(fieldNames)
        if ismember(fieldNames{i}, T.Properties.VariableNames)
            fieldName = string(fieldNames{i});
            return;
        end
    end
end


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

        text(ax, x(i), values(i), ['  ', char(local_format_number(values(i)))], ...
            'HorizontalAlignment', 'center', 'VerticalAlignment', vAlign, 'FontSize', 8);
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
