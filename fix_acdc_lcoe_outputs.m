function acdcResult = fix_acdc_lcoe_outputs(acdcResult)
% FIX_ACDC_LCOE_OUTPUTS
%
% Vegso fajlagos hasznos AC energia mutato javitas az AC/DC osszesito
% riporthoz.
%
% A feladat szerinti definicio:
%   mutato = rendszer altal szolgaltatott AC energia / (sumCAPEX + sumOPEX)
%
% ahol a szimulalt idoszakra vett koltseg:
%   sumCAPEX + sumOPEX =
%       PV CAPEX / PV lifetime * simYears
%     + PV OPEX
%     + inverter CAPEX / inverter lifetime * simYears
%     + inverter OPEX
%     + BESS degradacios CAPEX
%     + BESS OPEX
%
% BESS degradacios CAPEX:
%   (1 - finalSoH) / 0.2 * CapexBESS
%
% Szolgaltatott AC energia:
%   PV -> load + BESS -> load
%
% A mutato mertekegysege a riportban:
%   MWh / millio Ft
%
% Minel nagyobb ez az ertek, annal jobb. Ezert a heatmap a maximumot jeloli.

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

    T = local_ensure_required_period_fields(T);

    periodCost_millionHUF = T.reportPeriodInvestmentCost_HUF ./ 1e6;
    usefulACEnergy_MWh = T.reportUsefulACEnergy_MWh;

    % Ez az altalad kert irany: energia / koltseg.
    T.ACEnergyPerCost_MWh_per_millionHUF = local_safe_divide( ...
        usefulACEnergy_MWh, ...
        periodCost_millionHUF);

    % A regi LCOE mezoket szandekosan felulirjuk, hogy a heatmapek es a
    % tablazatok ne a korabbi koltseg/energia definiciot hasznaljak.
    % Itt a nev kompatibilitasi okbol marad LCOE, de a tartalom:
    % hasznositott AC energia / periodus koltseg.
    T.LCOE_system_HUF_per_kWh = T.ACEnergyPerCost_MWh_per_millionHUF;
    T.LCOE_usefulPV_HUF_per_kWh = T.ACEnergyPerCost_MWh_per_millionHUF;
    T.LCOE_HUF_per_kWh = T.ACEnergyPerCost_MWh_per_millionHUF;

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
        "ACEnergyPerCost_MWh_per_millionHUF = (pvToLoad_kWh + bessToLoad_kWh)/1000 / (sumCAPEX_plus_sumOPEX_HUF/1e6), where BESS CAPEX = (1-finalSoH)/0.2*CapexBESS";

    save(fullfile(outputFolder, 'evaluation_acdc_summary_result.mat'), ...
        'acdcResult', '-v7.3');

    fprintf('\nAC/DC useful AC energy per period cost recalculated.\n');
end


function T = local_ensure_required_period_fields(T)

    n = height(T);

    if ~ismember('reportUsefulACEnergy_MWh', T.Properties.VariableNames)
        if all(ismember({'pvToLoad_kWh', 'bessToLoad_kWh'}, T.Properties.VariableNames))
            T.reportUsefulACEnergy_MWh = (T.pvToLoad_kWh + T.bessToLoad_kWh) ./ 1000;
        else
            error('Missing reportUsefulACEnergy_MWh and cannot reconstruct it.');
        end
    end

    % A BESS degradacios CAPEX-et itt explicit ujraszamoljuk, hogy biztosan
    % az altalad kert kepletet hasznalja.
    if ~all(ismember({'capexBESS_HUF', 'finalSoH'}, T.Properties.VariableNames))
        error('Missing capexBESS_HUF or finalSoH for BESS degradation CAPEX calculation.');
    end

    if ismember('E_BESS_kWh', T.Properties.VariableNames)
        hasBess = T.E_BESS_kWh > 1e-9;
    else
        hasBess = true(n, 1);
    end

    deltaSoH = max(0, 1 - T.finalSoH);
    deltaSoH(~hasBess) = 0;

    T.reportDeltaSoH = deltaSoH;
    T.reportPeriodBessDegradation_HUF = (deltaSoH ./ 0.2) .* T.capexBESS_HUF;

    requiredCostFields = { ...
        'reportPeriodPVCapex_HUF', ...
        'reportPeriodPVOpex_HUF', ...
        'reportPeriodInverterCapex_HUF', ...
        'reportPeriodInverterOpex_HUF', ...
        'reportPeriodBessOpex_HUF'};

    for k = 1:numel(requiredCostFields)
        if ~ismember(requiredCostFields{k}, T.Properties.VariableNames)
            error('Missing required cost field: %s. Run finalize_acdc_summary_outputs first.', requiredCostFields{k});
        end
    end

    T.reportPeriodInvestmentCost_HUF = ...
        T.reportPeriodPVCapex_HUF + ...
        T.reportPeriodPVOpex_HUF + ...
        T.reportPeriodInverterCapex_HUF + ...
        T.reportPeriodInverterOpex_HUF + ...
        T.reportPeriodBessDegradation_HUF + ...
        T.reportPeriodBessOpex_HUF;
end


function y = local_safe_divide(num, den)

    y = NaN(size(num));
    mask = isfinite(num) & isfinite(den) & abs(den) > 1e-12;
    y(mask) = num(mask) ./ den(mask);
end


function selectedTable = local_refresh_selected_table(selectedTable, combinedTable)

    if ~ismember('ACEnergyPerCost_MWh_per_millionHUF', selectedTable.Properties.VariableNames)
        selectedTable.ACEnergyPerCost_MWh_per_millionHUF = NaN(height(selectedTable), 1);
    end

    if ~ismember('LCOE_system_HUF_per_kWh', selectedTable.Properties.VariableNames)
        selectedTable.LCOE_system_HUF_per_kWh = NaN(height(selectedTable), 1);
    end

    if ~ismember('LCOE_HUF_per_kWh', selectedTable.Properties.VariableNames)
        selectedTable.LCOE_HUF_per_kWh = NaN(height(selectedTable), 1);
    end

    for i = 1:height(selectedTable)
        mask = combinedTable.Coupling == selectedTable.Coupling(i) & ...
            combinedTable.candidateIndex == selectedTable.candidateIndex(i);

        idx = find(mask, 1);

        if isempty(idx)
            continue;
        end

        value = combinedTable.ACEnergyPerCost_MWh_per_millionHUF(idx);

        selectedTable.ACEnergyPerCost_MWh_per_millionHUF(i) = value;
        selectedTable.LCOE_system_HUF_per_kWh(i) = value;

        if ismember('LCOE_usefulPV_HUF_per_kWh', selectedTable.Properties.VariableNames)
            selectedTable.LCOE_usefulPV_HUF_per_kWh(i) = value;
        end

        selectedTable.LCOE_HUF_per_kWh(i) = value;
    end
end


function S = local_update_selected_summary_lcoe(S, selectedTable)

    values = selectedTable.ACEnergyPerCost_MWh_per_millionHUF;

    S.ACEnergyPerCost_MWh_per_millionHUF = values;
    S.LCOE_system_HUF_per_kWh = values;

    if ismember('LCOE_usefulPV_HUF_per_kWh', S.Properties.VariableNames)
        S.LCOE_usefulPV_HUF_per_kWh = values;
    end
end


function local_plot_min_inverter_lcoe_heatmap(T, figureFolder)

    metricField = 'ACEnergyPerCost_MWh_per_millionHUF';
    metricLabel = 'Hasznos AC energia / periodus koltseg';
    metricUnit = 'MWh/millio Ft';
    direction = 'max';

    valid = logical(T.wasSimulated) & ~logical(T.hasError) & ...
        isfinite(T.P_inv_kW) & isfinite(T.DCAC_ratio) & ...
        isfinite(T.BESS_PV_ratio) & isfinite(T.(metricField));

    if ~any(valid)
        warning('fix_acdc_lcoe_outputs:noValidData', ...
            'No valid data for corrected AC energy per cost heatmap.');
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
            'No common min-inverter data for corrected AC energy per cost heatmap.');
        return;
    end

    cMin = min(metricValues);
    cMax = max(metricValues);

    if abs(cMax - cMin) < 1e-12
        delta = max(1, abs(cMin) * 0.05);
        cMin = cMin - delta;
        cMax = cMax + delta;
    end

    fig = figure('Name', 'Heatmap min inverter - useful AC energy per cost', ...
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
