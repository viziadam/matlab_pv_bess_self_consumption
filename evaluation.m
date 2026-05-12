function evaluationResult = evaluation(cfg, evalCfg)
% EVALUATION
%
% Grid-connected PV+BESS onfogyasztás-növelési eredmények kiértékelése.
%
% Bemenet:
%   cfg     : fő szimulációs konfiguráció
%   evalCfg : külön kiértékelési konfiguráció
%
% Kötelező evalCfg mezők:
%
%   evalCfg.input.resultFilePath
%   evalCfg.output.baseFolder
%   evalCfg.output.saveEvaluationMat
%   evalCfg.output.saveEvaluationCsv
%   evalCfg.output.saveReportTables
%
%   evalCfg.plots.makePlots
%   evalCfg.plots.make3DScatter
%   evalCfg.plots.showAllMetrics
%
%   evalCfg.selection.mode
%   evalCfg.selection.minGridImportReduction_pct
%   evalCfg.selection.requirePositiveNPV
%   evalCfg.selection.requireBESS
%
%   evalCfg.report.smallBessMaxRatio
%   evalCfg.report.largeBessMinRatio
%
%   evalCfg.economics.simYears
%   evalCfg.economics.projectLifetime_years
%   evalCfg.economics.pvLifetime_years
%   evalCfg.economics.inverterLifetime_years
%   evalCfg.economics.discountRate
%   evalCfg.economics.pv_opex_frac_per_year
%   evalCfg.economics.bess_opex_frac_per_year
%   evalCfg.economics.inverter_opex_frac_per_year
%
%   evalCfg.metrics(:).field
%   evalCfg.metrics(:).label
%   evalCfg.metrics(:).unit
%   evalCfg.metrics(:).direction
%   evalCfg.metrics(:).plotWhenCompact
%
% Kötelező cfg mezők:
%
%   cfg.cost.pv_huf_per_kWp
%   cfg.cost.bess_huf_per_kWh
%   cfg.cost.bess_power_huf_per_kW
%   cfg.cost.inverter_huf_per_kW
%   cfg.cost.grid_import_huf_per_kWh
%   cfg.grid.allowExport
%
% Ha cfg.grid.allowExport == true:
%   cfg.cost.grid_export_huf_per_kWh
%
% Fő kimenetek:
%   evaluationResult.resultTable
%   evaluationResult.reportTables.optimalSystemTable
%   evaluationResult.reportTables.lcseMatrixTable
%   evaluationResult.reportTables.npvMatrixTable
%   evaluationResult.best
%
% Ábrák:
%   - LCSE színezett táblázat
%   - NPV színezett táblázat
%   - opcionális 3D scatter ábrák evalCfg.metrics alapján
%
% Színezés:
%   - zöld: legjobb érték
%   - sárga: köztes érték
%   - piros: legrosszabb érték
%
% A direction dönti el az irányt:
%   "max" -> nagyobb érték jobb
%   "min" -> kisebb érték jobb

    % ---------------------------------------------------------------------
    % 0) Validálás
    % ---------------------------------------------------------------------
    if nargin < 2
        error(['Az evaluation(cfg, evalCfg) forma kötelező. ', ...
               'Hozd létre az evalCfg struktúrát külön create_evaluation_config(cfg) függvénnyel.']);
    end

    local_validate_cfg(cfg);
    local_validate_eval_cfg(evalCfg);

    resultFilePath = char(evalCfg.input.resultFilePath);
    savePath = char(evalCfg.output.baseFolder);

    if ~isfile(resultFilePath)
        error('Nem található az evaluation input fájl: %s', resultFilePath);
    end

    if ~isfolder(savePath)
        mkdir(savePath);
    end

    fprintf('Kiértékelés input fájl: %s\n', resultFilePath);
    fprintf('Kiértékelés mentési mappa: %s\n\n', savePath);

    % ---------------------------------------------------------------------
    % 1) DB betöltése
    % ---------------------------------------------------------------------
    S = load(resultFilePath);
    DB = local_find_db_struct(S);

    if ~isfield(DB, 'candidateTable')
        error('A betöltött DB nem tartalmaz candidateTable mezőt.');
    end

    T = DB.candidateTable;

    if height(T) == 0
        error('A candidateTable üres.');
    end

    % ---------------------------------------------------------------------
    % 2) Teljes kiértékelési eredménytábla
    % ---------------------------------------------------------------------
    resultTable = local_build_result_table(T, cfg, evalCfg);

    % ---------------------------------------------------------------------
    % 3) Legjobb jelöltek kiválasztása
    % ---------------------------------------------------------------------
    best = struct();

    best.overallIndex = local_select_best_candidate(resultTable, evalCfg, true(height(resultTable), 1));

    pvOnlyMask = resultTable.E_BESS_kWh <= 1e-9;

    smallBessMask = ...
        resultTable.E_BESS_kWh > 1e-9 & ...
        resultTable.BESS_PV_ratio <= evalCfg.report.smallBessMaxRatio;

    largeBessMask = ...
        resultTable.E_BESS_kWh > 1e-9 & ...
        resultTable.BESS_PV_ratio >= evalCfg.report.largeBessMinRatio;

    best.pvOnlyIndex = local_select_best_candidate(resultTable, evalCfg, pvOnlyMask);
    best.smallBessIndex = local_select_best_candidate(resultTable, evalCfg, smallBessMask);
    best.largeBessIndex = local_select_best_candidate(resultTable, evalCfg, largeBessMask);

    best.indices = [ ...
        best.pvOnlyIndex, ...
        best.smallBessIndex, ...
        best.largeBessIndex];

    best.names = [ ...
        "Csak napelem", ...
        "Napelem + akkumulátor (1)", ...
        "Napelem + akkumulátor (2)"];

    fprintf('Kiválasztási mód: %s\n', string(evalCfg.selection.mode));
    fprintf('Összesített legjobb candidate index: %d\n\n', best.overallIndex);

    fprintf('Riportba kerülő jelöltek:\n');
    for k = 1:numel(best.indices)
        idx = best.indices(k);
        fprintf('  %s: candidateIndex = %d, P_inv = %.1f kW, P_PV = %.1f kWp, E_BESS = %.1f kWh\n', ...
            best.names(k), ...
            resultTable.candidateIndex(idx), ...
            resultTable.P_inv_kW(idx), ...
            resultTable.P_PV_kW(idx), ...
            resultTable.E_BESS_kWh(idx));
    end
    fprintf('\n');

    % ---------------------------------------------------------------------
    % 4) Riporttáblázatok
    % ---------------------------------------------------------------------
    reportTables = struct();

    reportTables.optimalSystemTable = local_create_optimal_system_table( ...
        resultTable, best.indices, best.names);

    [reportTables.lcseMatrixTable, lcseMatrixData] = local_create_metric_matrix_table( ...
        resultTable, ...
        "LCSE_HUF_per_kWh_saved", ...
        "min");

    [reportTables.npvMatrixTable, npvMatrixData] = local_create_metric_matrix_table( ...
        resultTable, ...
        "NPV_millionHUF", ...
        "max");

    % ---------------------------------------------------------------------
    % 5) Ábrák
    % ---------------------------------------------------------------------
    if evalCfg.plots.makePlots

        % Kötelező színezett táblázatos ábrák: LCSE és NPV
        local_plot_colored_matrix_table( ...
            lcseMatrixData, ...
            'LCSE - megtakarított energia fajlagos költsége', ...
            'Ft/kWh', ...
            'min', ...
            savePath, ...
            'colored_table_lcse');

        local_plot_colored_matrix_table( ...
            npvMatrixData, ...
            'Nettó jelenérték', ...
            'millió Ft', ...
            'max', ...
            savePath, ...
            'colored_table_npv');

        % Opcionális 3D scatter ábrák
        if evalCfg.plots.make3DScatter
            local_plot_selected_3d_scatters(resultTable, evalCfg, best.overallIndex, savePath);
        end
    end

    % ---------------------------------------------------------------------
    % 6) Mentés
    % ---------------------------------------------------------------------
    evaluationResult = struct();

    evaluationResult.config = cfg;
    evaluationResult.evalCfg = evalCfg;
    evaluationResult.sourceFile = resultFilePath;
    evaluationResult.resultTable = resultTable;
    evaluationResult.best = best;
    evaluationResult.bestCandidate = resultTable(best.overallIndex, :);
    evaluationResult.reportTables = reportTables;

    if evalCfg.output.saveEvaluationMat
        save(fullfile(savePath, 'evaluation_result.mat'), 'evaluationResult');
    end

    if evalCfg.output.saveEvaluationCsv
        local_safe_writetable(resultTable, fullfile(savePath, 'evaluation_result_table.csv'));
    end

    if evalCfg.output.saveReportTables
        local_safe_writetable(reportTables.optimalSystemTable, ...
            fullfile(savePath, 'optimalis_rendszermeretek_tablazat.csv'));

        local_safe_writetable(reportTables.lcseMatrixTable, ...
            fullfile(savePath, 'lcse_szinezett_matrix_tablazat.csv'));

        local_safe_writetable(reportTables.npvMatrixTable, ...
            fullfile(savePath, 'npv_szinezett_matrix_tablazat.csv'));

        save(fullfile(savePath, 'report_tables.mat'), 'reportTables');
    end

    fprintf('Kiértékelés kész.\n');
    fprintf('Mentési mappa: %s\n', savePath);
end


% =========================================================================
% VALIDÁLÁS
% =========================================================================
function local_validate_cfg(cfg)

    local_require_fields(cfg, {'cost', 'grid'}, 'cfg');

    requiredCostFields = { ...
        'pv_huf_per_kWp', ...
        'bess_huf_per_kWh', ...
        'bess_power_huf_per_kW', ...
        'inverter_huf_per_kW', ...
        'grid_import_huf_per_kWh'};

    local_require_fields(cfg.cost, requiredCostFields, 'cfg.cost');

    local_require_fields(cfg.grid, {'allowExport'}, 'cfg.grid');

    if logical(cfg.grid.allowExport)
        local_require_fields(cfg.cost, {'grid_export_huf_per_kWh'}, 'cfg.cost');
    end
end


function local_validate_eval_cfg(evalCfg)

    local_require_fields(evalCfg, ...
        {'input', 'output', 'plots', 'selection', 'report', 'economics', 'metrics'}, ...
        'evalCfg');

    local_require_fields(evalCfg.input, ...
        {'resultFilePath'}, ...
        'evalCfg.input');

    local_require_fields(evalCfg.output, ...
        {'baseFolder', 'saveEvaluationMat', 'saveEvaluationCsv', 'saveReportTables'}, ...
        'evalCfg.output');

    local_require_fields(evalCfg.plots, ...
        {'makePlots', 'make3DScatter', 'showAllMetrics'}, ...
        'evalCfg.plots');

    local_require_fields(evalCfg.selection, ...
        {'mode', 'minGridImportReduction_pct', 'requirePositiveNPV', 'requireBESS'}, ...
        'evalCfg.selection');

    local_require_fields(evalCfg.report, ...
        {'smallBessMaxRatio', 'largeBessMinRatio'}, ...
        'evalCfg.report');

    local_require_fields(evalCfg.economics, ...
        {'simYears', ...
         'projectLifetime_years', ...
         'pvLifetime_years', ...
         'inverterLifetime_years', ...
         'discountRate', ...
         'pv_opex_frac_per_year', ...
         'bess_opex_frac_per_year', ...
         'inverter_opex_frac_per_year'}, ...
        'evalCfg.economics');

    if isempty(evalCfg.metrics)
        error('evalCfg.metrics üres.');
    end

    local_require_fields(evalCfg.metrics, ...
        {'field', 'label', 'unit', 'direction', 'plotWhenCompact'}, ...
        'evalCfg.metrics');

    for i = 1:numel(evalCfg.metrics)
        direction = string(evalCfg.metrics(i).direction);

        if ~(direction == "min" || direction == "max")
            error('Hibás evalCfg.metrics(%d).direction: %s. Használható: "min" vagy "max".', ...
                i, direction);
        end
    end
end


function local_require_fields(S, requiredFields, structName)

    for i = 1:numel(requiredFields)
        f = requiredFields{i};

        if ~isfield(S, f)
            error('Hiányzó kötelező mező: %s.%s', structName, f);
        end
    end
end


% =========================================================================
% DB BETÖLTÉS
% =========================================================================
function DB = local_find_db_struct(S)

    if isfield(S, 'DB')
        DB = S.DB;
        return;
    end

    names = fieldnames(S);

    for i = 1:numel(names)
        candidate = S.(names{i});

        if isstruct(candidate) && isfield(candidate, 'candidateTable')
            DB = candidate;
            return;
        end
    end

    error('Nem találtam DB struktúrát a MAT fájlban.');
end


% =========================================================================
% RESULT TABLE ÉPÍTÉS
% =========================================================================
function resultTable = local_build_result_table(T, cfg, evalCfg)

    n = height(T);

    % ---------------------------------------------------------------------
    % Candidate méretek
    % ---------------------------------------------------------------------
    candidateIndex = local_get_required_column(T, {'candidateIndex'});
    P_inv_kW = local_get_required_column(T, {'P_inv_kW'});
    P_PV_kW = local_get_required_column(T, {'P_PV_kW', 'PV_kW'});
    E_BESS_kWh = local_get_required_column(T, {'E_BESS_kWh'});
    P_BESS_kW = local_get_required_column(T, {'P_BESS_kW'});

    DCAC_ratio = local_get_required_column(T, {'DCAC_ratio'});
    BESS_PV_ratio = local_get_required_column(T, {'BESS_PV_ratio'});

    % ---------------------------------------------------------------------
    % Energiaáramok
    % ---------------------------------------------------------------------
    loadEnergy_kWh = local_get_required_column(T, {'loadEnergy_kWh'});

    pvEnergyAvailable_kWh = local_get_required_column(T, { ...
        'pvEnergyAvailable_kWh', ...
        'pvEnergy_kWh'});

    pvToLoad_kWh = local_get_required_column(T, {'pvToLoad_kWh'});
    pvToBess_kWh = local_get_required_column(T, {'pvToBess_kWh'});
    bessToLoad_kWh = local_get_required_column(T, {'bessToLoad_kWh'});

    gridImport_kWh = local_get_required_column(T, {'gridImport_kWh'});
    gridExport_kWh = local_get_required_column(T, {'gridExport_kWh'});
    curtailment_kWh = local_get_required_column(T, {'curtailment_kWh'});

    inverterLoss_kWh = local_get_required_column(T, {'inverterLoss_kWh'});
    internalNetworkLoss_kWh = local_get_required_column(T, {'internalNetworkLoss_kWh'});

    % ---------------------------------------------------------------------
    % Veszteségmezők, ha a cfg.output alapján már kimentésre kerültek
    % ---------------------------------------------------------------------
    bessCellLoss_kWh = local_get_required_column(T, {'bessCellLoss_kWh'});
    bessTotalInternalLoss_kWh = local_get_required_column(T, {'bessTotalInternalLoss_kWh'});
    dcdcConversionLoss_kWh = local_get_required_column(T, {'dcdcConversionLoss_kWh'});
    inverterConversionLoss_kWh = local_get_required_column(T, {'inverterConversionLoss_kWh'});
    inverterPowerClipped_kWh = local_get_required_column(T, {'inverterPowerClipped_kWh'});
    inverterPvClipped_kWh = local_get_required_column(T, {'inverterPvClipped_kWh'});
    inverterBessClipped_kWh = local_get_required_column(T, {'inverterBessClipped_kWh'});

    % ---------------------------------------------------------------------
    % Final SoH
    % ---------------------------------------------------------------------
    finalSoH = local_get_required_final_soh(T, E_BESS_kWh);

    % ---------------------------------------------------------------------
    % Származtatott műszaki mutatók
    % ---------------------------------------------------------------------
    gridImportReduction_kWh = loadEnergy_kWh - gridImport_kWh;
    gridImportReduction_kWh(gridImportReduction_kWh < 0) = 0;

    gridImportReduction_pct = ...
        100 * local_divide_required(gridImportReduction_kWh, loadEnergy_kWh, ...
        'gridImportReduction_pct');

    pvSelfConsumedGross_kWh = pvToLoad_kWh + pvToBess_kWh;
    pvSelfConsumedUseful_kWh = pvToLoad_kWh + bessToLoad_kWh;

    directSelfConsumption_pct = ...
        100 * local_divide_required(pvToLoad_kWh, pvEnergyAvailable_kWh, ...
        'directSelfConsumption_pct');

    selfConsumptionGross_pct = ...
        100 * local_divide_required(pvSelfConsumedGross_kWh, pvEnergyAvailable_kWh, ...
        'selfConsumptionGross_pct');

    selfConsumption_pct = ...
        100 * local_divide_required(pvSelfConsumedUseful_kWh, pvEnergyAvailable_kWh, ...
        'selfConsumption_pct');

    selfSufficiency_pct = ...
        100 * local_divide_required(pvSelfConsumedUseful_kWh, loadEnergy_kWh, ...
        'selfSufficiency_pct');

    curtailment_pct = ...
        100 * local_divide_required(curtailment_kWh, pvEnergyAvailable_kWh, ...
        'curtailment_pct');

    gridExport_pct = ...
        100 * local_divide_required(gridExport_kWh, pvEnergyAvailable_kWh, ...
        'gridExport_pct');

    unusedPV_kWh = curtailment_kWh + gridExport_kWh;

    unusedPV_pct = ...
        100 * local_divide_required(unusedPV_kWh, pvEnergyAvailable_kWh, ...
        'unusedPV_pct');

    bessEquivalentCycles = ...
        local_divide_required(pvToBess_kWh + bessToLoad_kWh, 2 * E_BESS_kWh, ...
        'bessEquivalentCycles');

    noBessMask = E_BESS_kWh <= 1e-9;
    bessEquivalentCycles(noBessMask) = 0;

    % ---------------------------------------------------------------------
    % Gazdasági paraméterek
    % ---------------------------------------------------------------------
    simYears = evalCfg.economics.simYears;
    projectLifetime_years = evalCfg.economics.projectLifetime_years;
    pvLifetime_years = evalCfg.economics.pvLifetime_years;
    inverterLifetime_years = evalCfg.economics.inverterLifetime_years;
    discountRate = evalCfg.economics.discountRate;

    pv_opex_frac_per_year = evalCfg.economics.pv_opex_frac_per_year;
    bess_opex_frac_per_year = evalCfg.economics.bess_opex_frac_per_year;
    inverter_opex_frac_per_year = evalCfg.economics.inverter_opex_frac_per_year;

    pv_huf_per_kWp = cfg.cost.pv_huf_per_kWp;
    bess_huf_per_kWh = cfg.cost.bess_huf_per_kWh;
    bess_power_huf_per_kW = cfg.cost.bess_power_huf_per_kW;
    inverter_huf_per_kW = cfg.cost.inverter_huf_per_kW;
    grid_import_huf_per_kWh = cfg.cost.grid_import_huf_per_kWh;

    if logical(cfg.grid.allowExport)
        grid_export_huf_per_kWh = cfg.cost.grid_export_huf_per_kWh;
    else
        grid_export_huf_per_kWh = 0;
    end

    % ---------------------------------------------------------------------
    % CAPEX
    % ---------------------------------------------------------------------
    capexPV_HUF = P_PV_kW .* pv_huf_per_kWp;

    capexBESS_energy_HUF = E_BESS_kWh .* bess_huf_per_kWh;
    capexBESS_power_HUF = P_BESS_kW .* bess_power_huf_per_kW;
    capexBESS_HUF = capexBESS_energy_HUF + capexBESS_power_HUF;

    capexInverter_HUF = P_inv_kW .* inverter_huf_per_kW;

    initialCapex_HUF = ...
        capexPV_HUF + ...
        capexBESS_HUF + ...
        capexInverter_HUF;

    % ---------------------------------------------------------------------
    % Szimulált időszakra allokált költségek
    % ---------------------------------------------------------------------
    allocatedPVCapex_HUF = ...
        min(simYears / pvLifetime_years, 1) .* capexPV_HUF;

    allocatedBESSDegradationCapex_HUF = ...
        max(0, 1 - finalSoH) .* capexBESS_HUF;

    allocatedInverterCapex_HUF = ...
        min(simYears / inverterLifetime_years, 1) .* capexInverter_HUF;

    opexPV_HUF = capexPV_HUF .* pv_opex_frac_per_year .* simYears;
    opexBESS_HUF = capexBESS_HUF .* bess_opex_frac_per_year .* simYears;
    opexInverter_HUF = capexInverter_HUF .* inverter_opex_frac_per_year .* simYears;

    totalOpex_HUF = ...
        opexPV_HUF + ...
        opexBESS_HUF + ...
        opexInverter_HUF;

    allocatedTotalCost_HUF = ...
        allocatedPVCapex_HUF + ...
        allocatedBESSDegradationCapex_HUF + ...
        allocatedInverterCapex_HUF + ...
        totalOpex_HUF;

    % ---------------------------------------------------------------------
    % Energia-költségek
    % ---------------------------------------------------------------------
    gridOnlyEnergyCost_HUF = ...
        loadEnergy_kWh .* grid_import_huf_per_kWh;

    gridImportCost_HUF = ...
        gridImport_kWh .* grid_import_huf_per_kWh;

    gridExportRevenue_HUF = ...
        gridExport_kWh .* grid_export_huf_per_kWh;

    systemGridEnergyCost_HUF = ...
        gridImportCost_HUF - gridExportRevenue_HUF;

    energyCostSavings_HUF = ...
        gridOnlyEnergyCost_HUF - systemGridEnergyCost_HUF;

    periodNetValue_HUF = ...
        energyCostSavings_HUF - allocatedTotalCost_HUF;

    annualEnergySavings_HUF = energyCostSavings_HUF ./ simYears;
    annualOpex_HUF = totalOpex_HUF ./ simYears;

    annualBessDegradationCost_HUF = ...
        allocatedBESSDegradationCapex_HUF ./ simYears;

    annualNetCashflow_HUF = ...
        annualEnergySavings_HUF - ...
        annualOpex_HUF - ...
        annualBessDegradationCost_HUF;

    % ---------------------------------------------------------------------
    % Fajlagos költségmutatók
    % ---------------------------------------------------------------------
    LCSE_HUF_per_kWh_saved = ...
        local_divide_required(allocatedTotalCost_HUF, gridImportReduction_kWh, ...
        'LCSE_HUF_per_kWh_saved');

    LCOE_usefulPV_HUF_per_kWh = ...
        local_divide_required(allocatedTotalCost_HUF, pvSelfConsumedUseful_kWh, ...
        'LCOE_usefulPV_HUF_per_kWh');

    % ---------------------------------------------------------------------
    % Cashflow mutatók
    % ---------------------------------------------------------------------
    NPV_HUF = NaN(n, 1);
    discountedPayback_year = NaN(n, 1);
    simplePayback_year = NaN(n, 1);

    for i = 1:n
        NPV_HUF(i) = local_npv_constant_cashflow( ...
            initialCapex_HUF(i), ...
            annualNetCashflow_HUF(i), ...
            discountRate, ...
            projectLifetime_years);

        discountedPayback_year(i) = local_discounted_payback( ...
            initialCapex_HUF(i), ...
            annualNetCashflow_HUF(i), ...
            discountRate, ...
            projectLifetime_years);

        if annualNetCashflow_HUF(i) > 0
            simplePayback_year(i) = initialCapex_HUF(i) / annualNetCashflow_HUF(i);
        else
            simplePayback_year(i) = inf;
        end
    end

    % ---------------------------------------------------------------------
    % Évesített mennyiségek
    % ---------------------------------------------------------------------
    annualPVEnergy_MWh = pvEnergyAvailable_kWh ./ simYears ./ 1000;
    annualPvToLoad_MWh = pvToLoad_kWh ./ simYears ./ 1000;
    annualPvToBess_MWh = pvToBess_kWh ./ simYears ./ 1000;
    annualBessToLoad_MWh = bessToLoad_kWh ./ simYears ./ 1000;
    annualCurtailment_MWh = curtailment_kWh ./ simYears ./ 1000;
    annualUnusedPV_MWh = unusedPV_kWh ./ simYears ./ 1000;
    annualGridImportReduction_MWh = gridImportReduction_kWh ./ simYears ./ 1000;
    annualBessEquivalentCycles = bessEquivalentCycles ./ simYears;

    % ---------------------------------------------------------------------
    % Result table
    % ---------------------------------------------------------------------
    resultTable = table();

    resultTable.candidateIndex = candidateIndex;

    resultTable.P_inv_kW = P_inv_kW;
    resultTable.P_PV_kW = P_PV_kW;
    resultTable.E_BESS_kWh = E_BESS_kWh;
    resultTable.P_BESS_kW = P_BESS_kW;
    resultTable.DCAC_ratio = DCAC_ratio;
    resultTable.BESS_PV_ratio = BESS_PV_ratio;

    resultTable.loadEnergy_kWh = loadEnergy_kWh;
    resultTable.pvEnergyAvailable_kWh = pvEnergyAvailable_kWh;
    resultTable.pvToLoad_kWh = pvToLoad_kWh;
    resultTable.pvToBess_kWh = pvToBess_kWh;
    resultTable.bessToLoad_kWh = bessToLoad_kWh;
    resultTable.gridImport_kWh = gridImport_kWh;
    resultTable.gridExport_kWh = gridExport_kWh;
    resultTable.curtailment_kWh = curtailment_kWh;
    resultTable.unusedPV_kWh = unusedPV_kWh;

    resultTable.inverterLoss_kWh = inverterLoss_kWh;
    resultTable.internalNetworkLoss_kWh = internalNetworkLoss_kWh;

    resultTable.bessCellLoss_kWh = bessCellLoss_kWh;
    resultTable.bessTotalInternalLoss_kWh = bessTotalInternalLoss_kWh;
    resultTable.dcdcConversionLoss_kWh = dcdcConversionLoss_kWh;
    resultTable.inverterConversionLoss_kWh = inverterConversionLoss_kWh;
    resultTable.inverterPowerClipped_kWh = inverterPowerClipped_kWh;
    resultTable.inverterPvClipped_kWh = inverterPvClipped_kWh;
    resultTable.inverterBessClipped_kWh = inverterBessClipped_kWh;

    resultTable.gridImportReduction_kWh = gridImportReduction_kWh;
    resultTable.gridImportReduction_pct = gridImportReduction_pct;

    resultTable.directSelfConsumption_pct = directSelfConsumption_pct;
    resultTable.selfConsumptionGross_pct = selfConsumptionGross_pct;
    resultTable.selfConsumption_pct = selfConsumption_pct;
    resultTable.selfSufficiency_pct = selfSufficiency_pct;
    resultTable.curtailment_pct = curtailment_pct;
    resultTable.gridExport_pct = gridExport_pct;
    resultTable.unusedPV_pct = unusedPV_pct;
    resultTable.bessEquivalentCycles = bessEquivalentCycles;
    resultTable.finalSoH = finalSoH;

    resultTable.capexPV_HUF = capexPV_HUF;
    resultTable.capexBESS_energy_HUF = capexBESS_energy_HUF;
    resultTable.capexBESS_power_HUF = capexBESS_power_HUF;
    resultTable.capexBESS_HUF = capexBESS_HUF;
    resultTable.capexInverter_HUF = capexInverter_HUF;
    resultTable.initialCapex_HUF = initialCapex_HUF;

    resultTable.allocatedPVCapex_HUF = allocatedPVCapex_HUF;
    resultTable.allocatedBESSDegradationCapex_HUF = allocatedBESSDegradationCapex_HUF;
    resultTable.allocatedInverterCapex_HUF = allocatedInverterCapex_HUF;
    resultTable.totalOpex_HUF = totalOpex_HUF;
    resultTable.allocatedTotalCost_HUF = allocatedTotalCost_HUF;

    resultTable.gridOnlyEnergyCost_HUF = gridOnlyEnergyCost_HUF;
    resultTable.systemGridEnergyCost_HUF = systemGridEnergyCost_HUF;
    resultTable.gridExportRevenue_HUF = gridExportRevenue_HUF;
    resultTable.energyCostSavings_HUF = energyCostSavings_HUF;
    resultTable.periodNetValue_HUF = periodNetValue_HUF;

    resultTable.annualEnergySavings_HUF = annualEnergySavings_HUF;
    resultTable.annualNetCashflow_HUF = annualNetCashflow_HUF;

    resultTable.LCSE_HUF_per_kWh_saved = LCSE_HUF_per_kWh_saved;
    resultTable.LCOE_usefulPV_HUF_per_kWh = LCOE_usefulPV_HUF_per_kWh;

    resultTable.NPV_HUF = NPV_HUF;
    resultTable.NPV_millionHUF = NPV_HUF ./ 1e6;
    resultTable.periodNetValue_millionHUF = periodNetValue_HUF ./ 1e6;

    resultTable.discountedPayback_year = discountedPayback_year;
    resultTable.simplePayback_year = simplePayback_year;

    resultTable.annualPVEnergy_MWh = annualPVEnergy_MWh;
    resultTable.annualPvToLoad_MWh = annualPvToLoad_MWh;
    resultTable.annualPvToBess_MWh = annualPvToBess_MWh;
    resultTable.annualBessToLoad_MWh = annualBessToLoad_MWh;
    resultTable.annualCurtailment_MWh = annualCurtailment_MWh;
    resultTable.annualUnusedPV_MWh = annualUnusedPV_MWh;
    resultTable.annualGridImportReduction_MWh = annualGridImportReduction_MWh;
    resultTable.annualBessEquivalentCycles = annualBessEquivalentCycles;

    if ismember('wasSimulated', T.Properties.VariableNames)
        resultTable.wasSimulated = T.wasSimulated;
    else
        error('A candidateTable nem tartalmaz wasSimulated mezőt.');
    end

    if ismember('hasError', T.Properties.VariableNames)
        resultTable.hasError = T.hasError;
    else
        error('A candidateTable nem tartalmaz hasError mezőt.');
    end
end


% =========================================================================
% OSZLOP KIOLVASÁS
% =========================================================================
function values = local_get_required_column(T, possibleNames)

    if ischar(possibleNames) || isstring(possibleNames)
        possibleNames = cellstr(possibleNames);
    end

    for k = 1:numel(possibleNames)

        colName = possibleNames{k};

        if ismember(colName, T.Properties.VariableNames)

            raw = T.(colName);

            if iscell(raw)
                values = zeros(height(T), 1);
                for i = 1:height(T)
                    values(i) = double(raw{i});
                end
            elseif isstring(raw)
                values = str2double(raw(:));
            elseif islogical(raw)
                values = double(raw(:));
            else
                values = double(raw(:));
            end

            if numel(values) ~= height(T)
                error('A(z) %s oszlop mérete hibás.', colName);
            end

            return;
        end
    end

    namesText = strjoin(possibleNames, ', ');
    error('Hiányzó kötelező oszlop a candidateTable-ben. Elfogadott nevek: %s', namesText);
end


function finalSoH = local_get_required_final_soh(T, E_BESS_kWh)

    possibleNames = { ...
        'finalSoH', ...
        'finalSOH', ...
        'SOH_final', ...
        'bessFinalSoH', ...
        'BESS_finalSoH'};

    hasBessCandidate = any(E_BESS_kWh > 1e-9);

    for k = 1:numel(possibleNames)

        name = possibleNames{k};

        if ismember(name, T.Properties.VariableNames)

            finalSoH = double(T.(name)(:));

            invalidMask = ...
                ~isfinite(finalSoH) | ...
                finalSoH <= 0 | ...
                finalSoH > 1;

            noBessMask = E_BESS_kWh <= 1e-9;

            if any(invalidMask & ~noBessMask)
                error(['A finalSoH oszlop tartalmaz hibás értéket BESS-es candidate esetében. ', ...
                       'Ellenőrizd a simulate_candidates_database végén a finalSoH mentését.']);
            end

            finalSoH(noBessMask) = 1;

            return;
        end
    end

    if hasBessCandidate
        error(['Hiányzik a finalSoH a candidateTable-ből, miközben vannak BESS-es candidate-ek. ', ...
               'Futtasd újra a szimulációt olyan simulate_candidates_database verzióval, ', ...
               'amely elmenti a finalSoH mezőt.']);
    end

    finalSoH = ones(height(T), 1);
end


% =========================================================================
% BIZTONSÁGOS OSZTÁS
% =========================================================================
function y = local_divide_required(a, b, metricName)

    a = double(a(:));
    b = double(b(:));

    if numel(a) ~= numel(b)
        error('Méreteltérés az osztásnál: %s', metricName);
    end

    y = NaN(size(a));

    valid = isfinite(a) & isfinite(b) & abs(b) > 1e-12;

    if any(~valid)
        % BESS ciklusszámnál a no-BESS eseteket később külön kezeljük.
        if ~strcmp(metricName, 'bessEquivalentCycles')
            error('Érvénytelen osztás a(z) %s számításánál. Nulla vagy NaN nevező található.', metricName);
        end
    end

    y(valid) = a(valid) ./ b(valid);
end


% =========================================================================
% LEGJOBB CANDIDATE KIVÁLASZTÁSA
% =========================================================================
function bestIdx = local_select_best_candidate(resultTable, evalCfg, extraMask)

    if nargin < 3
        error('local_select_best_candidate: extraMask kötelező.');
    end

    mode = lower(string(evalCfg.selection.mode));

    feasibleMask = extraMask(:);

    if numel(feasibleMask) ~= height(resultTable)
        error('A feasibleMask mérete nem egyezik a resultTable magasságával.');
    end

    feasibleMask = feasibleMask & ...
        resultTable.gridImportReduction_pct >= evalCfg.selection.minGridImportReduction_pct;

    if evalCfg.selection.requirePositiveNPV
        feasibleMask = feasibleMask & resultTable.NPV_HUF > 0;
    end

    if evalCfg.selection.requireBESS
        feasibleMask = feasibleMask & resultTable.E_BESS_kWh > 1e-9;
    end

    feasibleMask = feasibleMask & resultTable.wasSimulated & ~resultTable.hasError;

    switch mode

        case {"minlcse", "lcse"}
            values = resultTable.LCSE_HUF_per_kWh_saved;
            bestIdx = local_pick_best_index(values, feasibleMask, "min");

        case {"maxnpv", "npv"}
            values = resultTable.NPV_HUF;
            bestIdx = local_pick_best_index(values, feasibleMask, "max");

        case {"mindiscountedpayback", "discountedpayback", "payback"}
            values = resultTable.discountedPayback_year;
            bestIdx = local_pick_best_index(values, feasibleMask, "min");

        case {"maxperiodnetvalue", "periodnetvalue"}
            values = resultTable.periodNetValue_HUF;
            bestIdx = local_pick_best_index(values, feasibleMask, "max");

        otherwise
            error('Ismeretlen evalCfg.selection.mode: %s', mode);
    end
end


function bestIdx = local_pick_best_index(values, feasibleMask, direction)

    values = double(values(:));
    feasibleMask = logical(feasibleMask(:));

    valid = feasibleMask & isfinite(values);

    if ~any(valid)
        error('Nincs értékelhető candidate a megadott szűrőfeltételekkel.');
    end

    switch string(direction)

        case "min"
            tmp = values;
            tmp(~valid) = inf;
            [~, bestIdx] = min(tmp);

        case "max"
            tmp = values;
            tmp(~valid) = -inf;
            [~, bestIdx] = max(tmp);

        otherwise
            error('Ismeretlen direction: %s', string(direction));
    end
end


% =========================================================================
% RIPORTTÁBLÁZAT: 3 LEGJOBB JELÖLT
% =========================================================================
function optimalSystemTable = local_create_optimal_system_table(resultTable, indices, names)

    if numel(indices) ~= 3
        error('Az optimalSystemTable pontosan 3 jelöltet vár.');
    end

    labels = { ...
        'Napelemes rendszer teljesítménye'; ...
        'Inverter névleges teljesítménye'; ...
        'Akkumulátor kapacitása'; ...
        'Akkumulátor névleges teljesítménye'; ...
        'Hálózati import csökkenése'; ...
        'Éves villamosenergia-megtakarítás'; ...
        'Éves töltési/kisütési ciklusszám'; ...
        'Megtermelt PV energia'; ...
        'PV által közvetlenül fedezett energia'; ...
        'PV által akkumulátorba töltött energia'; ...
        'Akkumulátor által szolgáltatott energia'; ...
        'Nem hasznosított PV energia'; ...
        'PV visszwattos/levágási veszteség'; ...
        'Veszteségek összesen'; ...
        'Nettó jelenérték'; ...
        'Teljes beruházási költség'; ...
        'Statikus megtérülési idő'; ...
        'Diszkontált megtérülési idő'; ...
        'LCSE - megtakarított energia fajlagos költsége'; ...
        'LCOE - hasznosított PV energia fajlagos költsége'; ...
        'candidateIndex'};

    units = { ...
        'kWp'; ...
        'kW'; ...
        'kWh'; ...
        'kW'; ...
        '%'; ...
        'millió Ft/év'; ...
        'db/év'; ...
        'MWh/év'; ...
        'MWh/év'; ...
        'MWh/év'; ...
        'MWh/év'; ...
        'MWh/év'; ...
        'MWh/év'; ...
        'MWh/év'; ...
        'millió Ft'; ...
        'millió Ft'; ...
        'év'; ...
        'év'; ...
        'Ft/kWh'; ...
        'Ft/kWh'; ...
        '-'};

    values = strings(numel(labels), 3);

    for c = 1:3

        idx = indices(c);

        totalLoss_MWh_per_year = ...
            (resultTable.inverterLoss_kWh(idx) + ...
             resultTable.internalNetworkLoss_kWh(idx) + ...
             resultTable.bessTotalInternalLoss_kWh(idx) + ...
             resultTable.dcdcConversionLoss_kWh(idx)) / ...
             local_get_sim_years_from_annual_values(resultTable, idx);

        rowValues = { ...
            resultTable.P_PV_kW(idx); ...
            resultTable.P_inv_kW(idx); ...
            resultTable.E_BESS_kWh(idx); ...
            resultTable.P_BESS_kW(idx); ...
            resultTable.gridImportReduction_pct(idx); ...
            resultTable.annualEnergySavings_HUF(idx) / 1e6; ...
            resultTable.annualBessEquivalentCycles(idx); ...
            resultTable.annualPVEnergy_MWh(idx); ...
            resultTable.annualPvToLoad_MWh(idx); ...
            resultTable.annualPvToBess_MWh(idx); ...
            resultTable.annualBessToLoad_MWh(idx); ...
            resultTable.annualUnusedPV_MWh(idx); ...
            resultTable.annualCurtailment_MWh(idx); ...
            totalLoss_MWh_per_year; ...
            resultTable.NPV_millionHUF(idx); ...
            resultTable.initialCapex_HUF(idx) / 1e6; ...
            resultTable.simplePayback_year(idx); ...
            resultTable.discountedPayback_year(idx); ...
            resultTable.LCSE_HUF_per_kWh_saved(idx); ...
            resultTable.LCOE_usefulPV_HUF_per_kWh(idx); ...
            resultTable.candidateIndex(idx)};

        for r = 1:numel(rowValues)

            value = rowValues{r};

            if r == 3 || r == 4 || r == 7 || r == 10 || r == 11
                if abs(value) < 1e-9
                    values(r, c) = "-";
                else
                    values(r, c) = local_format_number(value);
                end
            else
                values(r, c) = local_format_number(value);
            end
        end
    end

    optimalSystemTable = table();

    optimalSystemTable.Mennyiseg = string(labels);
    optimalSystemTable.(matlab.lang.makeValidName(names(1))) = values(:, 1);
    optimalSystemTable.(matlab.lang.makeValidName(names(2))) = values(:, 2);
    optimalSystemTable.(matlab.lang.makeValidName(names(3))) = values(:, 3);
    optimalSystemTable.Mertekegyseg = string(units);
end


function simYearsApprox = local_get_sim_years_from_annual_values(resultTable, idx)

    if resultTable.annualPVEnergy_MWh(idx) > 0
        simYearsApprox = resultTable.pvEnergyAvailable_kWh(idx) / ...
            (resultTable.annualPVEnergy_MWh(idx) * 1000);
    else
        simYearsApprox = 1;
    end
end


% =========================================================================
% SZÍNEZETT MÁTRIX TÁBLÁZATOK
% =========================================================================
function [matrixTable, matrixData] = local_create_metric_matrix_table(resultTable, metricField, direction)

    if ~ismember(metricField, resultTable.Properties.VariableNames)
        error('A resultTable nem tartalmazza ezt a metrikát: %s', metricField);
    end

    xVals = unique(resultTable.P_PV_kW(isfinite(resultTable.P_PV_kW)));
    yVals = unique(resultTable.BESS_PV_ratio(isfinite(resultTable.BESS_PV_ratio)));

    xVals = sort(xVals(:).');
    yVals = sort(yVals(:));

    Z = NaN(numel(yVals), numel(xVals));
    candidateIdxMatrix = NaN(numel(yVals), numel(xVals));

    metricValues = resultTable.(metricField);

    for iy = 1:numel(yVals)
        for ix = 1:numel(xVals)

            mask = ...
                abs(resultTable.P_PV_kW - xVals(ix)) < 1e-9 & ...
                abs(resultTable.BESS_PV_ratio - yVals(iy)) < 1e-9 & ...
                resultTable.wasSimulated & ...
                ~resultTable.hasError & ...
                isfinite(metricValues);

            if any(mask)

                candidateRows = find(mask);
                candidateMetricValues = metricValues(candidateRows);

                switch string(direction)
                    case "min"
                        [bestValue, localIdx] = min(candidateMetricValues);

                    case "max"
                        [bestValue, localIdx] = max(candidateMetricValues);

                    otherwise
                        error('Ismeretlen direction: %s', string(direction));
                end

                Z(iy, ix) = bestValue;
                candidateIdxMatrix(iy, ix) = candidateRows(localIdx);
            end
        end
    end

    rowLabels = strings(numel(yVals), 1);

    for iy = 1:numel(yVals)
        if abs(yVals(iy)) < 1e-12
            rowLabels(iy) = "Akkumulátor nélkül";
        else
            rowLabels(iy) = sprintf('BESS/PV = %.2f kWh/kWp', yVals(iy));
        end
    end

    colLabels = strings(1, numel(xVals));

    for ix = 1:numel(xVals)
        colLabels(ix) = sprintf('%.0f kWp', xVals(ix));
    end

    matrixTable = table();
    matrixTable.BESS_PV_arany = rowLabels;

    for ix = 1:numel(xVals)
        colName = matlab.lang.makeValidName(sprintf('PV_%.0f_kWp', xVals(ix)));
        matrixTable.(colName) = Z(:, ix);
    end

    matrixData = struct();
    matrixData.xVals = xVals;
    matrixData.yVals = yVals;
    matrixData.rowLabels = rowLabels;
    matrixData.colLabels = colLabels;
    matrixData.Z = Z;
    matrixData.candidateIdxMatrix = candidateIdxMatrix;
    matrixData.metricField = metricField;
    matrixData.direction = direction;
end


function local_plot_colored_matrix_table(matrixData, metricLabel, metricUnit, direction, savePath, fileTag)

    Z = matrixData.Z;
    rowLabels = matrixData.rowLabels;
    colLabels = matrixData.colLabels;

    nRows = size(Z, 1);
    nCols = size(Z, 2);

    finiteVals = Z(isfinite(Z));

    if isempty(finiteVals)
        error('Nincs véges érték a színezett táblázathoz: %s', metricLabel);
    end

    vMin = min(finiteVals);
    vMax = max(finiteVals);

    figW = max(1000, 120 + 90 * nCols);
    figH = max(550, 120 + 36 * nRows);

    fig = figure('Name', metricLabel, ...
        'Position', [100, 100, figW, figH]);

    ax = axes(fig);
    hold(ax, 'on');
    axis(ax, 'equal');
    axis(ax, 'off');

    cellW = 1.0;
    cellH = 0.45;
    rowLabelW = 3.0;

    totalW = rowLabelW + nCols * cellW;
    totalH = (nRows + 1) * cellH;

    xlim(ax, [0, totalW]);
    ylim(ax, [0, totalH]);

    % ---------------------------------------------------------------------
    % Fejléc
    % ---------------------------------------------------------------------
    rectangle(ax, ...
        'Position', [0, totalH - cellH, rowLabelW, cellH], ...
        'FaceColor', [0.92, 0.92, 0.92], ...
        'EdgeColor', 'k');

    text(ax, rowLabelW / 2, totalH - cellH / 2, ...
        'BESS/PV arány', ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'middle', ...
        'FontWeight', 'bold', ...
        'Interpreter', 'none');

    for ix = 1:nCols
        x0 = rowLabelW + (ix - 1) * cellW;

        rectangle(ax, ...
            'Position', [x0, totalH - cellH, cellW, cellH], ...
            'FaceColor', [0.92, 0.92, 0.92], ...
            'EdgeColor', 'k');

        text(ax, x0 + cellW / 2, totalH - cellH / 2, ...
            char(colLabels(ix)), ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'middle', ...
            'FontWeight', 'bold', ...
            'FontSize', 8, ...
            'Interpreter', 'none');
    end

    % ---------------------------------------------------------------------
    % Cellák
    % ---------------------------------------------------------------------
    for iy = 1:nRows

        y0 = totalH - (iy + 1) * cellH;

        rectangle(ax, ...
            'Position', [0, y0, rowLabelW, cellH], ...
            'FaceColor', [0.96, 0.96, 0.96], ...
            'EdgeColor', 'k');

        text(ax, 0.05, y0 + cellH / 2, ...
            char(rowLabels(iy)), ...
            'HorizontalAlignment', 'left', ...
            'VerticalAlignment', 'middle', ...
            'FontSize', 8, ...
            'Interpreter', 'none');

        for ix = 1:nCols

            x0 = rowLabelW + (ix - 1) * cellW;
            value = Z(iy, ix);

            if isfinite(value)
                color = local_value_to_green_yellow_red(value, vMin, vMax, direction);
                textValue = local_format_number(value);
            else
                color = [1, 1, 1];
                textValue = "-";
            end

            rectangle(ax, ...
                'Position', [x0, y0, cellW, cellH], ...
                'FaceColor', color, ...
                'EdgeColor', 'k');

            text(ax, x0 + cellW / 2, y0 + cellH / 2, ...
                textValue, ...
                'HorizontalAlignment', 'center', ...
                'VerticalAlignment', 'middle', ...
                'FontSize', 8, ...
                'Interpreter', 'none');
        end
    end

    title(ax, sprintf('%s [%s]', metricLabel, metricUnit), ...
        'Interpreter', 'none', ...
        'FontWeight', 'bold');

    saveas(fig, fullfile(savePath, [fileTag, '.png']));
    savefig(fig, fullfile(savePath, [fileTag, '.fig']));
end


function color = local_value_to_green_yellow_red(value, vMin, vMax, direction)

    if abs(vMax - vMin) < 1e-12
        score = 0.5;
    else
        rawScore = (value - vMin) / (vMax - vMin);

        switch string(direction)
            case "max"
                score = rawScore;
            case "min"
                score = 1 - rawScore;
            otherwise
                error('Ismeretlen direction: %s', string(direction));
        end
    end

    score = max(0, min(1, score));

    red = [0.85, 0.15, 0.15];
    yellow = [1.00, 0.90, 0.15];
    green = [0.15, 0.70, 0.25];

    if score <= 0.5
        t = score / 0.5;
        color = (1 - t) * red + t * yellow;
    else
        t = (score - 0.5) / 0.5;
        color = (1 - t) * yellow + t * green;
    end
end


% =========================================================================
% OPCIONÁLIS 3D SCATTER ÁBRÁK
% =========================================================================
function local_plot_selected_3d_scatters(resultTable, evalCfg, bestIdx, savePath)

    for m = 1:numel(evalCfg.metrics)

        metricField = char(evalCfg.metrics(m).field);
        metricLabel = char(evalCfg.metrics(m).label);
        metricUnit = char(evalCfg.metrics(m).unit);
        direction = string(evalCfg.metrics(m).direction);

        if ~evalCfg.plots.showAllMetrics && ~evalCfg.metrics(m).plotWhenCompact
            continue;
        end

        if ~ismember(metricField, resultTable.Properties.VariableNames)
            error('A resultTable nem tartalmazza a 3D scatterhez kért metrikát: %s', metricField);
        end

        metricValues = resultTable.(metricField);

        local_plot_3d_scatter( ...
            resultTable.P_inv_kW, ...
            resultTable.P_PV_kW, ...
            resultTable.E_BESS_kWh, ...
            metricValues, ...
            metricLabel, ...
            metricUnit, ...
            direction, ...
            bestIdx, ...
            savePath, ...
            metricField);
    end
end


function local_plot_3d_scatter(P_inv_kW, P_PV_kW, E_BESS_kWh, metricValues, ...
    metricLabel, metricUnit, direction, bestIdx, savePath, fileTag)

    fig = figure('Name', ['3D scatter - ', metricLabel], ...
        'Position', [100, 100, 1100, 800]);

    hold on;
    grid on;
    box on;

    finiteMask = ...
        isfinite(P_inv_kW) & ...
        isfinite(P_PV_kW) & ...
        isfinite(E_BESS_kWh) & ...
        isfinite(metricValues);

    scatter3( ...
        P_inv_kW(finiteMask), ...
        P_PV_kW(finiteMask), ...
        E_BESS_kWh(finiteMask), ...
        45, ...
        metricValues(finiteMask), ...
        'filled');

    plot3( ...
        P_inv_kW(bestIdx), ...
        P_PV_kW(bestIdx), ...
        E_BESS_kWh(bestIdx), ...
        'kp', ...
        'MarkerSize', 16, ...
        'MarkerFaceColor', 'w', ...
        'LineWidth', 1.8);

    xlabel('Inverter névleges teljesítménye [kW]');
    ylabel('Napelemes rendszer teljesítménye [kWp]');
    zlabel('Akkumulátor kapacitása [kWh]');

    title(sprintf('%s a candidate térben', metricLabel), ...
        'Interpreter', 'none');

    cb = colorbar;
    cb.Label.String = sprintf('%s [%s]', metricLabel, metricUnit);

    colormap(gca, local_green_yellow_red_colormap(direction, 256));

    view(45, 25);

    saveas(fig, fullfile(savePath, ['scatter3_', char(fileTag), '.png']));
    savefig(fig, fullfile(savePath, ['scatter3_', char(fileTag), '.fig']));
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
            error('Ismeretlen direction: %s', string(direction));
    end

    cmap = [c1; c2];
end


function C = local_interp_color(cStart, cEnd, n)

    t = linspace(0, 1, n).';
    C = (1 - t) .* cStart + t .* cEnd;
end


% =========================================================================
% CASHFLOW
% =========================================================================
function npv = local_npv_constant_cashflow(initialCapex, annualNetCashflow, discountRate, lifetimeYears)

    if ~isfinite(initialCapex) || ~isfinite(annualNetCashflow)
        npv = NaN;
        return;
    end

    npv = -initialCapex;

    for y = 1:lifetimeYears
        npv = npv + annualNetCashflow / ((1 + discountRate) ^ y);
    end
end


function paybackYear = local_discounted_payback(initialCapex, annualNetCashflow, discountRate, lifetimeYears)

    if ~isfinite(initialCapex) || ~isfinite(annualNetCashflow) || annualNetCashflow <= 0
        paybackYear = inf;
        return;
    end

    cumulative = -initialCapex;

    for y = 1:lifetimeYears

        previousCumulative = cumulative;

        cumulative = cumulative + ...
            annualNetCashflow / ((1 + discountRate) ^ y);

        if cumulative >= 0

            yearlyDiscountedCashflow = cumulative - previousCumulative;

            if yearlyDiscountedCashflow <= 0
                paybackYear = y;
            else
                fraction = abs(previousCumulative) / yearlyDiscountedCashflow;
                paybackYear = (y - 1) + fraction;
            end

            return;
        end
    end

    paybackYear = inf;
end


% =========================================================================
% FORMÁZÁS ÉS MENTÉS
% =========================================================================
function s = local_format_number(x)

    if ~isfinite(x)
        if isinf(x)
            s = "NaN";
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


function local_safe_writetable(T, filePath)

    if exist(filePath, 'file')
        try
            delete(filePath);
        catch
            error(['Nem tudom felülírni a fájlt, mert valószínűleg meg van nyitva ', ...
                   'Excelben vagy más programban:\n%s\n\nZárd be a fájlt, majd futtasd újra.'], ...
                   filePath);
        end
    end

    try
        writetable(T, filePath);
    catch ME
        error('Nem sikerült kiírni a táblázatot:\n%s\n\nEredeti hiba:\n%s', ...
            filePath, ME.message);
    end
end
