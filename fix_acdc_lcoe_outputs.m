function acdcResult = fix_acdc_lcoe_outputs(acdcResult)
% FIX_ACDC_LCOE_OUTPUTS
%
% Vegso LCOE javitas az AC/DC osszesito riporthoz.
%
% Definicio:
%   LCOE = teljes, szimulalt idoszakra allokalt rendszerkoltseg
%          / hasznositott AC energia
%
% ahol:
%   teljes rendszerkoltseg =
%       PV CAPEX / lifetime * simYears
%     + PV OPEX
%     + inverter CAPEX / lifetime * simYears
%     + inverter OPEX
%     + BESS degradacios CAPEX: (1 - finalSoH) / 0.2 * BESS CAPEX
%     + BESS OPEX
%
%   hasznositott AC energia = PV -> load + BESS -> load
%
% A fuggveny felulirja az AC/DC riportban hasznalt LCOE mezoket, frissiti a
% tablazatokat es ujrageneralja a legkisebb invertermerethez tartozo LCOE
% heatmapet kozos DC/AC szintartomannyal.

    if nargin < 1 || isempty(acdcResult)
        error('acdcResult input is required.');
    end

    if ~isfield(acdcResult, 'combinedTable')
        error('acdcResult.combinedTable is missing.');
    end

    if ~isfield(acdcResult, 'outputFolder')
        error('acdcResult.outputFolder is missing.');
    end

    T = acdcResult.combinedTable;

    if ~ismember('reportPeriodInvestmentCost_HUF', T.Properties.VariableNames)
        error('Missing reportPeriodInvestmentCost_HUF. Run finalize_acdc_summary_outputs first.');
    end

    if ~ismember('reportUsefulACEnergy_MWh', T.Properties.VariableNames)
        if all(ismember({'pvToLoad_kWh', 'bessToLoad_kWh'}, T.Properties.VariableNames))
            T.reportUsefulACEnergy_MWh = (T.pvToLoad_kWh + T.bessToLoad_kWh) ./ 1000;
        else
            error('Missing reportUsefulACEnergy_MWh and cannot reconstruct it.');
        end
    end

    usefulACEnergy_kWh = T.reportUsefulACEnergy_MWh .* 1000;

    T.LCOE_system_HUF_per_kWh = local_safe_divide( ...
        T.reportPeriodInvestmentCost_HUF, ...
        usefulACEnergy_kWh);

    % A korabbi LCOE mezoket is felulirjuk, hogy a heatmapek es tablazatok
    % ne a regi definiciot hasznaljak.
    T.LCOE_usefulPV_HUF_per_kWh = T.LCOE_system_HUF_per_kWh;
    T.LCOE_HUF_per_kWh = T.LCOE_system_HUF_per_kWh;

    acdcResult.combinedTable = T;

    if isfield(acdcResult, 'selectedTable') && height(acdcResult.selectedTable) > 0
        acdcResult.selectedTable = local_refresh_selected_table(acdcResult.selectedTable, T);
    end

    if isfield(acdcResult, 'selectedSummaryTable') && height(acdcResult.selectedSummaryTable) > 0
        acdcResult.selectedSummaryTable = local_update_selected_summary_lcoe( ...
            acdcResult.selectedSummaryTable, acdcResult.selectedTable);
    end

    outputFolder = acdcResult.outputFolder;
    tableFolder = fullfile(outputFolder, 'tables');
    figureFolder = fullfile(outputFolder, 'figures');

    if ~exist(tableFolder, 'dir')
        mkdir(tableFolder);
    end

    if ~exist(figureFolder, 'dir')
        mkdir(figureFolder);
    end

    writetable(T, fullfile(tableFolder, 'acdc_combined_candidate_table.csv'));

    if isfield(acdcResult, 'selectedSummaryTable') && height(acdcResult.selectedSummaryTable) > 0
        writetable(acdcResult.selectedSummaryTable, ...
            fullfile(tableFolder, 'acdc_selected_candidates_summary.csv'));
    end

    local_plot_min_inverter_lcoe_heatmap(T, figureFolder);

    acdcResult.lcoeDefinition = ...
        "LCOE_system_HUF_per_kWh = reportPeriodInvestmentCost_HUF / ((pvToLoad_kWh + bessToLoad_kWh))";

    save(fullfile(outputFolder, 'evaluation_acdc_summary_result.mat'), ...
        'acdcResult', '-v7.3');

    fprintf('\nAC/DC LCOE recalculated from period costs and useful AC energy.\n');
end


function y = local_safe_divide(num, den)

    y = NaN(size(num));
    mask = isfinite(num) & isfinite(den) & abs(den) > 1e-12;
    y(mask) = num(mask) ./ den(mask);
end


function selectedTable = local_refresh_selected_table(selectedTable, combinedTable)

    for i = 1:height(selectedTable)
        mask = combinedTable.Coupling == selectedTable.Coupling(i) & ...
            combinedTable.candidateIndex == selectedTable.candidateIndex(i);

        idx = find(mask, 1);

        if isempty(idx)
            continue;
        end

        if ismember('LCOE_system_HUF_per_kWh', selectedTable.Properties.VariableNames)
            selectedTable.LCOE_system_HUF_per_kWh(i) = combinedTable.LCOE_system_HUF_per_kWh(idx);
        else
            selectedTable.LCOE_system_HUF_per_kWh = NaN(height(selectedTable), 1);
            selectedTable.LCOE_system_HUF_per_kWh(i) = combinedTable.LCOE_system_HUF_per_kWh(idx);
        end

        selectedTable.LCOE_usefulPV_HUF_per_kWh(i) = combinedTable.LCOE_system_HUF_per_kWh(idx);
        selectedTable.LCOE_HUF_per_kWh(i) = combinedTable.LCOE_system_HUF_per_kWh(idx);
    end
end


function S = local_update_selected_summary_lcoe(S, selectedTable)

    lcoeValues = selectedTable.LCOE_system_HUF_per_kWh;

    if ismember('LCOE_system_HUF_per_kWh', S.Properties.VariableNames)
        S.LCOE_system_HUF_per_kWh = lcoeValues;
    else
        S.LCOE_system_HUF_per_kWh = lcoeValues;
    end

    if ismember('LCOE_usefulPV_HUF_per_kWh', S.Properties.VariableNames)
        S.LCOE_usefulPV_HUF_per_kWh = lcoeValues;
    end
end


function local_plot_min_inverter_lcoe_heatmap(T, figureFolder)

    metricField = 'LCOE_system_HUF_per_kWh';
    metricLabel = 'LCOE - periodus koltseg / hasznositott AC energia';
    metricUnit = 'Ft/kWh';
    direction = 'min';

    valid = logical(T.wasSimulated) & ~logical(T.hasError) & ...
        isfinite(T.P_inv_kW) & isfinite(T.DCAC_ratio) & ...
        isfinite(T.BESS_PV_ratio) & isfinite(T.(metricField));

    if ~any(valid)
        warning('fix_acdc_lcoe_outputs:noValidData', ...
            'No valid data for corrected LCOE heatmap.');
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
        warning('fix_acdc_lcoe_outputs:noHeatmapData', ...
            'No common min-inverter data for corrected LCOE heatmap.');
        return;
    end

    cMin = min(metricValues);
    cMax = max(metricValues);

    if abs(cMax - cMin) < 1e-12
        delta = max(1, abs(cMin) * 0.05);
        cMin = cMin - delta;
        cMax = cMax + delta;
    end

    fig = figure('Name', 'Heatmap min inverter - corrected LCOE', ...
        'Position', [80, 80, 1450, 650]);

    tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

    couplings = ["dc", "ac"];

    for i = 1:numel(couplings)
        ax = nexttile;
        local_plot_single_lcoe_heatmap(ax, T, couplings(i), minInv, invTol, ...
            xVals, yVals, [cMin, cMax], metricField, metricLabel, metricUnit, direction);
    end

    sgtitle(fig, sprintf('%s - legkisebb invertermeret: %.0f kW', metricLabel, minInv), ...
        'Interpreter', 'none');

    local_save_figure(fig, figureFolder, 'heatmap_min_inverter_lcoe');
end


function local_plot_single_lcoe_heatmap(ax, T, coupling, minInv, invTol, xVals, yVals, colorLimits, metricField, metricLabel, metricUnit, direction)

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
    hold(ax, 'on');
    grid(ax, 'on');
    box(ax, 'on');

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

    local_mark_best_heatmap_point(ax, T(mask, :), metricField, direction);
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
