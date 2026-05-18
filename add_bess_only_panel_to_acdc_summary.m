function acdcResult = add_bess_only_panel_to_acdc_summary(acdcResult)
% ADD_BESS_ONLY_PANEL_TO_ACDC_SUMMARY
%
% Ujrageneralja az AC/DC osszesito penzugyi abrat 4 panellel.
%
% A 4. panel BESS-only szemleletu:
%   + BESS -> load hasznos AC energia penzbeli erteke
%   - BESS degradacios CAPEX a szimulalt idoszakra
%   - BESS OPEX a szimulalt idoszakra
%   = BESS-only netto ertek
%
% A fuggveny ugyanarra a fajlnevve ment, mint az eredeti 3 paneles abra:
%   acdc_selected_value_cost_payback_summary.png/.fig
% Igy a vegso riportban mar a bovített figure szerepel.

    if nargin < 1 || isempty(acdcResult)
        error('acdcResult input is required.');
    end

    if ~isfield(acdcResult, 'selectedTable')
        error('acdcResult.selectedTable is missing.');
    end

    if ~isfield(acdcResult, 'outputFolder')
        error('acdcResult.outputFolder is missing.');
    end

    T = acdcResult.selectedTable;

    if height(T) == 0
        error('acdcResult.selectedTable is empty.');
    end

    figureFolder = fullfile(acdcResult.outputFolder, 'figures');
    tableFolder = fullfile(acdcResult.outputFolder, 'tables');

    if ~exist(figureFolder, 'dir')
        mkdir(figureFolder);
    end

    if ~exist(tableFolder, 'dir')
        mkdir(tableFolder);
    end

    xLabels = local_selected_labels(T);
    simYears = local_get_sim_years(acdcResult);

    bessOnlyTable = local_build_bess_only_table(T, xLabels, simYears);

    local_plot_extended_value_cost_summary(T, xLabels, bessOnlyTable, figureFolder);

    writetable(bessOnlyTable, fullfile(tableFolder, 'acdc_selected_bess_only_period_value_table.csv'));

    acdcResult.selectedBessOnlyValueTable = bessOnlyTable;

    save(fullfile(acdcResult.outputFolder, 'evaluation_acdc_summary_result.mat'), ...
        'acdcResult', '-v7.3');
end


% =========================================================================
% TABLE BUILDING
% =========================================================================
function bessOnlyTable = local_build_bess_only_table(T, xLabels, simYears)

    n = height(T);

    bessAcSaving_HUF = local_bess_ac_energy_value(T);
    bessDegradation_HUF = local_bess_degradation_cost_for_period(T, simYears);
    bessOpex_HUF = local_bess_opex_for_period(T, simYears);

    noBessMask = T.E_BESS_kWh <= 1e-9;
    bessAcSaving_HUF(noBessMask) = 0;
    bessDegradation_HUF(noBessMask) = 0;
    bessOpex_HUF(noBessMask) = 0;

    bessNet_HUF = bessAcSaving_HUF - bessDegradation_HUF - bessOpex_HUF;

    bessOnlyTable = table();
    bessOnlyTable.Selection = xLabels(:);

    if ismember('Coupling', T.Properties.VariableNames)
        bessOnlyTable.Coupling = T.Coupling;
    end

    bessOnlyTable.candidateIndex = T.candidateIndex;
    bessOnlyTable.E_BESS_kWh = T.E_BESS_kWh;
    bessOnlyTable.P_BESS_kW = T.P_BESS_kW;
    bessOnlyTable.BESS_to_load_MWh_total = T.bessToLoad_kWh ./ 1000;
    bessOnlyTable.BESS_AC_energy_saving_millionHUF = bessAcSaving_HUF ./ 1e6;
    bessOnlyTable.BESS_degradation_CAPEX_millionHUF = bessDegradation_HUF ./ 1e6;
    bessOnlyTable.BESS_OPEX_millionHUF = bessOpex_HUF ./ 1e6;
    bessOnlyTable.BESS_only_net_value_millionHUF = bessNet_HUF ./ 1e6;

    if height(bessOnlyTable) ~= n
        error('Internal BESS-only table construction error.');
    end
end


function value_HUF = local_bess_ac_energy_value(T)

    if ismember('bessUsefulEnergyValue_HUF', T.Properties.VariableNames)
        value_HUF = T.bessUsefulEnergyValue_HUF;
        value_HUF(~isfinite(value_HUF)) = 0;
        return;
    end

    if ismember('gridOnlyEnergyCost_HUF', T.Properties.VariableNames) && ...
       ismember('loadEnergy_kWh', T.Properties.VariableNames)
        importPrice_HUF_per_kWh = T.gridOnlyEnergyCost_HUF ./ max(T.loadEnergy_kWh, eps);
    else
        error(['Cannot calculate BESS AC energy value. ', ...
               'Missing bessUsefulEnergyValue_HUF or gridOnlyEnergyCost_HUF/loadEnergy_kWh.']);
    end

    value_HUF = T.bessToLoad_kWh .* importPrice_HUF_per_kWh;
    value_HUF(~isfinite(value_HUF)) = 0;
end


function cost_HUF = local_bess_degradation_cost_for_period(T, simYears)

    if ismember('reportAnnualBessDegradation_HUF', T.Properties.VariableNames)
        cost_HUF = T.reportAnnualBessDegradation_HUF .* simYears;
        cost_HUF(~isfinite(cost_HUF)) = 0;
        return;
    end

    if ismember('allocatedBESSDegradationCapex_HUF', T.Properties.VariableNames)
        cost_HUF = T.allocatedBESSDegradationCapex_HUF;
        cost_HUF(~isfinite(cost_HUF)) = 0;
        return;
    end

    if ismember('capexBESS_HUF', T.Properties.VariableNames) && ismember('finalSoH', T.Properties.VariableNames)
        deltaSoH = max(0, 1 - T.finalSoH);
        cost_HUF = (deltaSoH ./ 0.2) .* T.capexBESS_HUF;
        cost_HUF(~isfinite(cost_HUF)) = 0;
        return;
    end

    error('Cannot calculate BESS degradation CAPEX for period.');
end


function cost_HUF = local_bess_opex_for_period(T, simYears)

    if ismember('reportAnnualBessOpex_HUF', T.Properties.VariableNames)
        cost_HUF = T.reportAnnualBessOpex_HUF .* simYears;
        cost_HUF(~isfinite(cost_HUF)) = 0;
        return;
    end

    if ismember('capexBESS_HUF', T.Properties.VariableNames)
        % Fallback csak akkor hasznalhato, ha az evaluation nem adott kulon
        % annual BESS OPEX mezot. A jelenlegi create_evaluation_config szerint
        % az arany 2 %/ev.
        cost_HUF = T.capexBESS_HUF .* 0.020 .* simYears;
        cost_HUF(~isfinite(cost_HUF)) = 0;
        return;
    end

    error('Cannot calculate BESS OPEX for period.');
end


function simYears = local_get_sim_years(acdcResult)

    if isfield(acdcResult, 'dcEvaluation') && ...
       isfield(acdcResult.dcEvaluation, 'evalCfg') && ...
       isfield(acdcResult.dcEvaluation.evalCfg, 'economics') && ...
       isfield(acdcResult.dcEvaluation.evalCfg.economics, 'simYears')
        simYears = acdcResult.dcEvaluation.evalCfg.economics.simYears;
        return;
    end

    if isfield(acdcResult, 'acEvaluation') && ...
       isfield(acdcResult.acEvaluation, 'evalCfg') && ...
       isfield(acdcResult.acEvaluation.evalCfg, 'economics') && ...
       isfield(acdcResult.acEvaluation.evalCfg.economics, 'simYears')
        simYears = acdcResult.acEvaluation.evalCfg.economics.simYears;
        return;
    end

    error('Cannot determine simulation length from acdcResult.');
end


function xLabels = local_selected_labels(T)

    if ismember('SelectionLabel', T.Properties.VariableNames)
        xLabels = string(T.SelectionLabel);
        xLabels = replace(xLabels, "Best only PV", "PV only");
        xLabels = replace(xLabels, "Best DC by LCSE", "DC LCSE");
        xLabels = replace(xLabels, "Best DC by NPV", "DC NPV");
        xLabels = replace(xLabels, "Best AC by LCSE", "AC LCSE");
        xLabels = replace(xLabels, "Best AC by NPV", "AC NPV");
    else
        xLabels = "Candidate " + string((1:height(T)).');
    end
end


% =========================================================================
% PLOT
% =========================================================================
function local_plot_extended_value_cost_summary(T, xLabels, bessOnlyTable, figureFolder)

    fig = figure('Name', 'AC/DC selected value cost payback summary', ...
        'Position', [50, 40, 1550, 1250]);

    tiledlayout(fig, 4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');

    x = 1:height(T);

    % ---------------------------------------------------------------------
    % 1) Annual system added value as energy cost saving
    % ---------------------------------------------------------------------
    ax1 = nexttile;
    hold(ax1, 'on');
    grid(ax1, 'on');
    box(ax1, 'on');

    annualSaving_mHUF = T.reportAnnualCostSaving_HUF ./ 1e6;
    bar(ax1, x, annualSaving_mHUF, 'BarWidth', 0.65);
    yline(ax1, 0, 'k-', 'LineWidth', 1.0);

    ylabel(ax1, 'million HUF/year');
    title(ax1, 'System added value as annual electricity cost saving');
    xticks(ax1, x);
    xticklabels(ax1, cellstr(xLabels));

    local_add_bar_value_labels(ax1, x, annualSaving_mHUF);

    % ---------------------------------------------------------------------
    % 2) Annual cost components
    % ---------------------------------------------------------------------
    ax2 = nexttile;
    hold(ax2, 'on');
    grid(ax2, 'on');
    box(ax2, 'on');

    costData_mHUF = [ ...
        T.reportAnnualPVCapex_HUF, ...
        T.reportAnnualPVOpex_HUF, ...
        T.reportAnnualInverterCapex_HUF, ...
        T.reportAnnualInverterOpex_HUF, ...
        T.reportAnnualBessDegradation_HUF, ...
        T.reportAnnualBessOpex_HUF] ./ 1e6;

    bar(ax2, x, costData_mHUF, 'stacked', 'BarWidth', 0.65);

    ylabel(ax2, 'million HUF/year');
    title(ax2, 'Annual investment and OPEX components');
    xticks(ax2, x);
    xticklabels(ax2, cellstr(xLabels));

    legend(ax2, { ...
        'PV CAPEX / lifetime', ...
        'PV OPEX', ...
        'Inverter CAPEX / lifetime', ...
        'Inverter OPEX', ...
        'BESS degradation: deltaSoH / 0.2 * CAPEX', ...
        'BESS OPEX'}, ...
        'Location', 'bestoutside');

    % ---------------------------------------------------------------------
    % 3) Net value over simulated period
    % ---------------------------------------------------------------------
    ax3 = nexttile;
    hold(ax3, 'on');
    grid(ax3, 'on');
    box(ax3, 'on');

    periodNet_mHUF = T.reportPeriodNetValue_HUF ./ 1e6;
    bar(ax3, x, periodNet_mHUF, 'BarWidth', 0.65);
    yline(ax3, 0, 'k-', 'LineWidth', 1.0);

    ylabel(ax3, 'million HUF');
    title(ax3, 'Net value over simulated period (positive means economically beneficial)');
    xticks(ax3, x);
    xticklabels(ax3, cellstr(xLabels));

    local_add_bar_value_labels(ax3, x, periodNet_mHUF);

    % ---------------------------------------------------------------------
    % 4) BESS-only value over simulated period
    % ---------------------------------------------------------------------
    ax4 = nexttile;
    hold(ax4, 'on');
    grid(ax4, 'on');
    box(ax4, 'on');

    bessValueStack_mHUF = [ ...
        bessOnlyTable.BESS_AC_energy_saving_millionHUF, ...
        -bessOnlyTable.BESS_degradation_CAPEX_millionHUF, ...
        -bessOnlyTable.BESS_OPEX_millionHUF];

    bar(ax4, x, bessValueStack_mHUF, 'stacked', 'BarWidth', 0.65);

    bessNet_mHUF = bessOnlyTable.BESS_only_net_value_millionHUF;
    plot(ax4, x, bessNet_mHUF, 'k-o', ...
        'LineWidth', 1.6, ...
        'MarkerSize', 5, ...
        'DisplayName', 'BESS-only net value');

    yline(ax4, 0, 'k-', 'LineWidth', 1.0);

    ylabel(ax4, 'million HUF / simulated period');
    title(ax4, 'BESS-only value: useful AC energy saving - BESS CAPEX/OPEX');
    xticks(ax4, x);
    xticklabels(ax4, cellstr(xLabels));

    legend(ax4, { ...
        'BESS -> load AC energy saving', ...
        'BESS degradation CAPEX', ...
        'BESS OPEX', ...
        'BESS-only net value'}, ...
        'Location', 'bestoutside');

    local_add_bar_value_labels(ax4, x, bessNet_mHUF);

    local_save_figure(fig, figureFolder, 'acdc_selected_value_cost_payback_summary');
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
