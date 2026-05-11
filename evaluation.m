function evaluationResult = evaluation(cfg)
% EVALUATION
%
% Grid-connected PV+BESS self-consumption szimulacios eredmenyek
% kiertekelese.
%
% A fuggveny alapertelmezetten ezt tolti be:
%
%   cfg.paths.results/results_dccoupled.mat
%
% A fajlban egy DB struktura kell legyen:
%
%   DB.candidateTable
%   DB.candidateProfiles
%   DB.nDays
%   DB.dt_h
%
% Kiertekelt mutatok:
%   - grid import reduction [%]
%   - self-consumption [%]
%   - self-sufficiency [%]
%   - curtailment [%]
%   - LCSE / LCOE_saved [HUF/kWh_saved]
%   - discounted payback [year]
%   - NPV [HUF]
%   - period net value [HUF]
%
% Abra:
%   - 3D scatter plot minden fontos mutatora:
%       x = P_inv_kW
%       y = P_PV_kW
%       z = E_BESS_kWh
%
%   - inverterenkenti heatmap:
%       x = DCAC_ratio
%       y = BESS_PV_ratio
%       color = adott mutato
%
% Fontos:
%   A heatmapek ugyanazon metrika eseten kozos color range-et hasznalnak,
%   hogy az invertermeretek osszehasonlithatok legyenek.
%
% Legjobb candidate kivalasztasa:
%   cfg.evaluation.selectionMode:
%       "minLCSE"    -> legalacsonyabb fajlagos megtakaritottenergia-koltseg
%       "maxNPV"     -> legnagyobb netto jelenertek
%       "minPayback" -> legrovidebb diszkontalt megterules
%
% A BESS degradacios koltseghez szukseges:
%   DB.candidateTable.finalSoH

    % ---------------------------------------------------------------------
    % 0) Alap ellenorzesek es utak
    % ---------------------------------------------------------------------
    if nargin < 1
        error('A cfg struktura kotelezo bemenet.');
    end

    if ~isfield(cfg, 'paths') || ~isfield(cfg.paths, 'results')
        error('cfg.paths.results hianyzik.');
    end

    if ~isfield(cfg.paths, 'figures')
        cfg.paths.figures = fullfile(cfg.paths.results, 'figures');
    end

    if ~isfolder(cfg.paths.results)
        error('Nem letezik a results mappa: %s', cfg.paths.results);
    end

    if ~isfolder(cfg.paths.figures)
        mkdir(cfg.paths.figures);
    end

    savePath = fullfile(cfg.paths.figures, 'evaluation');

    if ~isfolder(savePath)
        mkdir(savePath);
    end

    resultFileName = string(local_get_cfg_value( ...
        cfg, {'evaluation', 'resultFileName'}, "results_dccoupled.mat"));

    resultFilePath = fullfile(cfg.paths.results, char(resultFileName));

    if ~isfile(resultFilePath)
        error('Nem talalhato eredmenyfajl: %s', resultFilePath);
    end

    fprintf('Evaluation input file: %s\n', resultFilePath);
    fprintf('Figures/evaluation output path: %s\n\n', savePath);

    % ---------------------------------------------------------------------
    % 1) DB betoltese
    % ---------------------------------------------------------------------
    S = load(resultFilePath);
    DB = local_find_db_struct(S);

    if ~isfield(DB, 'candidateTable')
        error('A betoltott DB nem tartalmaz candidateTable mezot.');
    end

    T = DB.candidateTable;

    nCandidates = height(T);

    if nCandidates == 0
        error('A candidateTable ures.');
    end

    if isfield(DB, 'nDays')
        nDays = DB.nDays;
    else
        nDays = NaN;
    end

    if isfield(DB, 'dt_h')
        dt_h = DB.dt_h;
    else
        dt_h = NaN;
    end

    % ---------------------------------------------------------------------
    % 2) Candidate meretek es dimenziok kiolvasasa
    % ---------------------------------------------------------------------
    candidateIndex = local_get_numeric_column(T, {'candidateIndex'}, (1:nCandidates).');

    P_inv_kW = local_get_numeric_column(T, {'P_inv_kW'}, NaN(nCandidates, 1));
    P_PV_kW  = local_get_numeric_column(T, {'P_PV_kW', 'PV_kW'}, NaN(nCandidates, 1));
    E_BESS_kWh = local_get_numeric_column(T, {'E_BESS_kWh'}, NaN(nCandidates, 1));
    P_BESS_kW  = local_get_numeric_column(T, {'P_BESS_kW'}, NaN(nCandidates, 1));

    DCAC_ratio = local_get_numeric_column(T, {'DCAC_ratio'}, NaN(nCandidates, 1));
    BESS_PV_ratio = local_get_numeric_column(T, {'BESS_PV_ratio'}, NaN(nCandidates, 1));

    missingDCAC = isnan(DCAC_ratio) & P_inv_kW > 0;
    DCAC_ratio(missingDCAC) = P_PV_kW(missingDCAC) ./ P_inv_kW(missingDCAC);

    missingBessPv = isnan(BESS_PV_ratio) & P_PV_kW > 0;
    BESS_PV_ratio(missingBessPv) = E_BESS_kWh(missingBessPv) ./ P_PV_kW(missingBessPv);

    % ---------------------------------------------------------------------
    % 3) Alap energiaaramok kiolvasasa
    % ---------------------------------------------------------------------
    loadEnergy_kWh = local_get_numeric_column(T, ...
        {'loadEnergy_kWh'}, NaN(nCandidates, 1));

    pvEnergyAvailable_kWh = local_get_numeric_column(T, ...
        {'pvEnergyAvailable_kWh', 'pvEnergy_kWh'}, NaN(nCandidates, 1));

    pvToLoad_kWh = local_get_numeric_column(T, ...
        {'pvToLoad_kWh'}, zeros(nCandidates, 1));

    pvToBess_kWh = local_get_numeric_column(T, ...
        {'pvToBess_kWh'}, zeros(nCandidates, 1));

    bessToLoad_kWh = local_get_numeric_column(T, ...
        {'bessToLoad_kWh'}, zeros(nCandidates, 1));

    gridImport_kWh = local_get_numeric_column(T, ...
        {'gridImport_kWh'}, NaN(nCandidates, 1));

    gridExport_kWh = local_get_numeric_column(T, ...
        {'gridExport_kWh'}, zeros(nCandidates, 1));

    curtailment_kWh = local_get_numeric_column(T, ...
        {'curtailment_kWh'}, zeros(nCandidates, 1));

    inverterLoss_kWh = local_get_numeric_column(T, ...
        {'inverterLoss_kWh'}, zeros(nCandidates, 1));

    internalNetworkLoss_kWh = local_get_numeric_column(T, ...
        {'internalNetworkLoss_kWh'}, zeros(nCandidates, 1));

    % ---------------------------------------------------------------------
    % 4) Vegso SoH
    % ---------------------------------------------------------------------
    finalSoH = local_get_final_soh(T, DB, nCandidates);

    noBessMask = E_BESS_kWh <= 1e-9 | isnan(E_BESS_kWh);
    finalSoH(noBessMask) = 1;

    % ---------------------------------------------------------------------
    % 5) Muszaki szarmaztatott mutatok
    % ---------------------------------------------------------------------
    gridImportReduction_kWh = max(loadEnergy_kWh - gridImport_kWh, 0);

    gridImportReduction_pct = ...
        100 * local_safe_divide_vec(gridImportReduction_kWh, loadEnergy_kWh);

    pvSelfConsumedGross_kWh = pvToLoad_kWh + pvToBess_kWh;
    pvSelfConsumedUseful_kWh = pvToLoad_kWh + bessToLoad_kWh;

    directSelfConsumption_pct = ...
        100 * local_safe_divide_vec(pvToLoad_kWh, pvEnergyAvailable_kWh);

    selfConsumption_pct = ...
        100 * local_safe_divide_vec(pvSelfConsumedUseful_kWh, pvEnergyAvailable_kWh);

    selfConsumptionGross_pct = ...
        100 * local_safe_divide_vec(pvSelfConsumedGross_kWh, pvEnergyAvailable_kWh);

    selfSufficiency_pct = ...
        100 * local_safe_divide_vec(pvSelfConsumedUseful_kWh, loadEnergy_kWh);

    curtailment_pct = ...
        100 * local_safe_divide_vec(curtailment_kWh, pvEnergyAvailable_kWh);

    gridExport_pct = ...
        100 * local_safe_divide_vec(gridExport_kWh, pvEnergyAvailable_kWh);

    bessEquivalentCycles = ...
        local_safe_divide_vec(pvToBess_kWh + bessToLoad_kWh, 2 * E_BESS_kWh);

    bessEquivalentCycles(noBessMask) = 0;

    % ---------------------------------------------------------------------
    % 6) Gazdasagi beallitasok
    % ---------------------------------------------------------------------
    simYears = local_get_first_cfg_value(cfg, { ...
        {'evaluation', 'simYears'}, ...
        {'analysis', 'simYears'}, ...
        {'sim', 'simYears'}}, NaN);

    if isnan(simYears)
        if ~isnan(nDays)
            simYears = nDays / 365.25;
        else
            simYears = 1;
        end
    end

    projectLifetime_years = local_get_first_cfg_value(cfg, { ...
        {'cost', 'project_lifetime_years'}, ...
        {'economic', 'projectLifetime_years'}}, 20);

    pvLifetime_years = local_get_first_cfg_value(cfg, { ...
        {'cost', 'pv_lifetime_years'}, ...
        {'economic', 'pvLifetime_years'}}, 25);

    inverterLifetime_years = local_get_first_cfg_value(cfg, { ...
        {'cost', 'inverter_lifetime_years'}, ...
        {'economic', 'inverterLifetime_years'}}, 15);

    discountRate = local_get_first_cfg_value(cfg, { ...
        {'cost', 'discount_rate'}, ...
        {'economic', 'discountRate'}}, 0.08);

    pv_huf_per_kWp = local_get_cfg_value(cfg, ...
        {'cost', 'pv_huf_per_kWp'}, 0);

    bess_huf_per_kWh = local_get_cfg_value(cfg, ...
        {'cost', 'bess_huf_per_kWh'}, 0);

    bess_power_huf_per_kW = local_get_cfg_value(cfg, ...
        {'cost', 'bess_power_huf_per_kW'}, 0);

    inverter_huf_per_kW = local_get_cfg_value(cfg, ...
        {'cost', 'inverter_huf_per_kW'}, 0);

    grid_import_huf_per_kWh = local_get_cfg_value(cfg, ...
        {'cost', 'grid_import_huf_per_kWh'}, 0);

    grid_export_huf_per_kWh = local_get_cfg_value(cfg, ...
        {'cost', 'grid_export_huf_per_kWh'}, 0);

    pv_opex_frac_per_year = local_get_cfg_value(cfg, ...
        {'cost', 'pv_opex_frac_per_year'}, 0.015);

    bess_opex_frac_per_year = local_get_cfg_value(cfg, ...
        {'cost', 'bess_opex_frac_per_year'}, 0.020);

    inverter_opex_frac_per_year = local_get_cfg_value(cfg, ...
        {'cost', 'inverter_opex_frac_per_year'}, 0.010);

    % ---------------------------------------------------------------------
    % 7) CAPEX, OPEX, degradacios koltseg
    % ---------------------------------------------------------------------
    capexPV_HUF = P_PV_kW .* pv_huf_per_kWp;

    capexBESS_energy_HUF = E_BESS_kWh .* bess_huf_per_kWh;
    capexBESS_power_HUF  = P_BESS_kW .* bess_power_huf_per_kW;
    capexBESS_HUF = capexBESS_energy_HUF + capexBESS_power_HUF;

    capexInverter_HUF = P_inv_kW .* inverter_huf_per_kW;

    initialCapex_HUF = capexPV_HUF + capexBESS_HUF + capexInverter_HUF;

    % ---------------------------------------------------------------------
    % A szimulalt idoszakra allokalt CAPEX
    % ---------------------------------------------------------------------
    allocatedPVCapex_HUF = ...
        min(simYears / pvLifetime_years, 1) .* capexPV_HUF;

    allocatedBESSDegradationCapex_HUF = ...
        max(0, 1 - finalSoH) .* capexBESS_HUF;

    allocatedInverterCapex_HUF = ...
        min(simYears / inverterLifetime_years, 1) .* capexInverter_HUF;

    % ---------------------------------------------------------------------
    % OPEX a szimulalt idoszakra
    % ---------------------------------------------------------------------
    opexPV_HUF = capexPV_HUF .* pv_opex_frac_per_year .* simYears;
    opexBESS_HUF = capexBESS_HUF .* bess_opex_frac_per_year .* simYears;
    opexInverter_HUF = capexInverter_HUF .* inverter_opex_frac_per_year .* simYears;

    totalOpex_HUF = opexPV_HUF + opexBESS_HUF + opexInverter_HUF;

    allocatedTotalCost_HUF = ...
        allocatedPVCapex_HUF + ...
        allocatedBESSDegradationCapex_HUF + ...
        allocatedInverterCapex_HUF + ...
        totalOpex_HUF;

    % ---------------------------------------------------------------------
    % 8) Energia koltseg es megtakaritas
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

    % LCSE = Levelized Cost of Saved Energy
    LCOE_saved_HUF_per_kWh = ...
        local_safe_divide_vec(allocatedTotalCost_HUF, gridImportReduction_kWh);

    % ---------------------------------------------------------------------
    % 9) Discounted cashflow mutatok
    % ---------------------------------------------------------------------
    annualEnergySavings_HUF = energyCostSavings_HUF ./ max(simYears, eps);
    annualOpex_HUF = totalOpex_HUF ./ max(simYears, eps);

    % Itt a degradacios koltseget evesitve kezeljuk a cashflow-ban.
    annualBessDegradationCost_HUF = ...
        allocatedBESSDegradationCapex_HUF ./ max(simYears, eps);

    annualNetCashflow_HUF = ...
        annualEnergySavings_HUF - ...
        annualOpex_HUF - ...
        annualBessDegradationCost_HUF;

    NPV_HUF = NaN(nCandidates, 1);
    discountedPayback_year = NaN(nCandidates, 1);

    for i = 1:nCandidates
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
    end

    % ---------------------------------------------------------------------
    % 10) Result table
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

    resultTable.gridImportReduction_kWh = gridImportReduction_kWh;
    resultTable.gridImportReduction_pct = gridImportReduction_pct;
    resultTable.directSelfConsumption_pct = directSelfConsumption_pct;
    resultTable.selfConsumption_pct = selfConsumption_pct;
    resultTable.selfConsumptionGross_pct = selfConsumptionGross_pct;
    resultTable.selfSufficiency_pct = selfSufficiency_pct;
    resultTable.curtailment_pct = curtailment_pct;
    resultTable.gridExport_pct = gridExport_pct;
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

    resultTable.LCSE_HUF_per_kWh_saved = LCOE_saved_HUF_per_kWh;
    resultTable.LCOE_saved_HUF_per_kWh = LCOE_saved_HUF_per_kWh;
    resultTable.annualNetCashflow_HUF = annualNetCashflow_HUF;
    resultTable.NPV_HUF = NPV_HUF;
    resultTable.discountedPayback_year = discountedPayback_year;

    % ---------------------------------------------------------------------
    % 11) Legjobb candidate kivalasztasa
    % ---------------------------------------------------------------------
    selectionMode = lower(string(local_get_cfg_value( ...
        cfg, {'evaluation', 'selectionMode'}, "minLCSE")));

    minGridImportReduction_pct = local_get_cfg_value( ...
        cfg, {'evaluation', 'minGridImportReduction_pct'}, 0);

    requirePositiveNPV = logical(local_get_cfg_value( ...
        cfg, {'evaluation', 'requirePositiveNPV'}, false));

    requireBESS = logical(local_get_cfg_value( ...
        cfg, {'evaluation', 'requireBESS'}, false));

    feasibleMask = ...
        isfinite(NPV_HUF) & ...
        isfinite(LCOE_saved_HUF_per_kWh) & ...
        gridImportReduction_kWh > 0 & ...
        gridImportReduction_pct >= minGridImportReduction_pct;

    if ismember('hasError', T.Properties.VariableNames)
        feasibleMask = feasibleMask & ~T.hasError;
    end

    if ismember('wasSimulated', T.Properties.VariableNames)
        feasibleMask = feasibleMask & T.wasSimulated;
    end

    if requirePositiveNPV
        feasibleMask = feasibleMask & NPV_HUF > 0;
    end

    if requireBESS
        feasibleMask = feasibleMask & E_BESS_kWh > 1e-9;
    end

    bestByNPVIndex = local_pick_best_index(NPV_HUF, feasibleMask, "max");
    bestByLCSEIndex = local_pick_best_index(LCOE_saved_HUF_per_kWh, feasibleMask, "min");
    bestByPaybackIndex = local_pick_best_index(discountedPayback_year, feasibleMask, "min");

    switch selectionMode
        case {"maxnpv", "npv"}
            bestIdx = bestByNPVIndex;
            selectedCriterionText = "maximum NPV";

        case {"minlcse", "lcse", "minlcoe", "lcoe"}
            bestIdx = bestByLCSEIndex;
            selectedCriterionText = "minimum LCSE / LCOE_saved";

        case {"minpayback", "payback", "discountedpayback"}
            bestIdx = bestByPaybackIndex;
            selectedCriterionText = "minimum discounted payback";

        otherwise
            error('Ismeretlen cfg.evaluation.selectionMode: %s', selectionMode);
    end

    bestCandidate = resultTable(bestIdx, :);

    fprintf('\nLegjobb candidate gazdasagi szempontbol:\n');
    fprintf('  Selection mode: %s\n', selectedCriterionText);
    fprintf('  candidateIndex: %d\n', bestIdx);
    fprintf('  P_inv       = %.2f kW\n', P_inv_kW(bestIdx));
    fprintf('  P_PV        = %.2f kW\n', P_PV_kW(bestIdx));
    fprintf('  E_BESS      = %.2f kWh\n', E_BESS_kWh(bestIdx));
    fprintf('  P_BESS      = %.2f kW\n', P_BESS_kW(bestIdx));
    fprintf('  DCAC ratio  = %.3f\n', DCAC_ratio(bestIdx));
    fprintf('  BESS/PV     = %.3f kWh/kWp\n', BESS_PV_ratio(bestIdx));
    fprintf('  Final SoH   = %.2f %%\n', finalSoH(bestIdx) * 100);
    fprintf('  Grid import reduction = %.2f %%\n', gridImportReduction_pct(bestIdx));
    fprintf('  Self-consumption      = %.2f %%\n', selfConsumption_pct(bestIdx));
    fprintf('  Self-sufficiency      = %.2f %%\n', selfSufficiency_pct(bestIdx));
    fprintf('  LCSE / LCOE_saved     = %.2f HUF/kWh\n', LCOE_saved_HUF_per_kWh(bestIdx));
    fprintf('  Discounted payback    = %.2f year\n', discountedPayback_year(bestIdx));
    fprintf('  NPV                   = %.2f million HUF\n', NPV_HUF(bestIdx) / 1e6);
    fprintf('  Period net value      = %.2f million HUF\n\n', periodNetValue_HUF(bestIdx) / 1e6);

    fprintf('Osszehasonlito optimumok:\n');
    fprintf('  Best by NPV:     candidate %d, NPV = %.2f million HUF, LCSE = %.2f HUF/kWh\n', ...
        bestByNPVIndex, NPV_HUF(bestByNPVIndex) / 1e6, LCOE_saved_HUF_per_kWh(bestByNPVIndex));

    fprintf('  Best by LCSE:    candidate %d, NPV = %.2f million HUF, LCSE = %.2f HUF/kWh\n', ...
        bestByLCSEIndex, NPV_HUF(bestByLCSEIndex) / 1e6, LCOE_saved_HUF_per_kWh(bestByLCSEIndex));

    fprintf('  Best by payback: candidate %d, NPV = %.2f million HUF, payback = %.2f year\n\n', ...
        bestByPaybackIndex, NPV_HUF(bestByPaybackIndex) / 1e6, discountedPayback_year(bestByPaybackIndex));

    % ---------------------------------------------------------------------
    % 12) Abrak
    % ---------------------------------------------------------------------
    local_plot_metric_set( ...
        P_inv_kW, P_PV_kW, E_BESS_kWh, DCAC_ratio, BESS_PV_ratio, ...
        gridImportReduction_pct, ...
        'Grid import reduction', '%', bestIdx, savePath, 'grid_import_reduction');

    local_plot_metric_set( ...
        P_inv_kW, P_PV_kW, E_BESS_kWh, DCAC_ratio, BESS_PV_ratio, ...
        selfConsumption_pct, ...
        'Self-consumption', '%', bestIdx, savePath, 'self_consumption');

    local_plot_metric_set( ...
        P_inv_kW, P_PV_kW, E_BESS_kWh, DCAC_ratio, BESS_PV_ratio, ...
        selfSufficiency_pct, ...
        'Self-sufficiency', '%', bestIdx, savePath, 'self_sufficiency');

    local_plot_metric_set( ...
        P_inv_kW, P_PV_kW, E_BESS_kWh, DCAC_ratio, BESS_PV_ratio, ...
        LCOE_saved_HUF_per_kWh, ...
        'LCSE / LCOE saved', 'HUF/kWh', bestIdx, savePath, 'lcse');

    local_plot_metric_set( ...
        P_inv_kW, P_PV_kW, E_BESS_kWh, DCAC_ratio, BESS_PV_ratio, ...
        discountedPayback_year, ...
        'Discounted payback', 'year', bestIdx, savePath, 'discounted_payback');

    local_plot_metric_set( ...
        P_inv_kW, P_PV_kW, E_BESS_kWh, DCAC_ratio, BESS_PV_ratio, ...
        periodNetValue_HUF / 1e6, ...
        'Period net value', 'million HUF', bestIdx, savePath, 'period_net_value');

    local_plot_best_candidate_summary(resultTable, bestIdx, savePath);

    % ---------------------------------------------------------------------
    % 13) Mentes
    % ---------------------------------------------------------------------
    evaluationResult = struct();

    evaluationResult.config = cfg;
    evaluationResult.sourceFile = resultFilePath;
    evaluationResult.resultTable = resultTable;
    evaluationResult.bestIdx = bestIdx;
    evaluationResult.bestCandidate = bestCandidate;
    evaluationResult.bestByNPVIndex = bestByNPVIndex;
    evaluationResult.bestByLCSEIndex = bestByLCSEIndex;
    evaluationResult.bestByPaybackIndex = bestByPaybackIndex;

    evaluationResult.assumptions = struct();
    evaluationResult.assumptions.simYears = simYears;
    evaluationResult.assumptions.projectLifetime_years = projectLifetime_years;
    evaluationResult.assumptions.pvLifetime_years = pvLifetime_years;
    evaluationResult.assumptions.inverterLifetime_years = inverterLifetime_years;
    evaluationResult.assumptions.discountRate = discountRate;

    save(fullfile(savePath, 'evaluation_result.mat'), 'evaluationResult');
    writetable(resultTable, fullfile(savePath, 'evaluation_result_table.csv'));

    fprintf('Evaluation kesz.\n');
    fprintf('Mentett MAT: %s\n', fullfile(savePath, 'evaluation_result.mat'));
    fprintf('Mentett CSV: %s\n', fullfile(savePath, 'evaluation_result_table.csv'));
end


% =========================================================================
% DB BETOLTES
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

    error('Nem talaltam DB strukturalis valtozot a MAT fajlban.');
end


% =========================================================================
% OSZLOP KIOLVASAS
% =========================================================================
function values = local_get_numeric_column(T, possibleNames, defaultValue)

    if ischar(possibleNames) || isstring(possibleNames)
        possibleNames = cellstr(possibleNames);
    end

    n = height(T);

    for k = 1:numel(possibleNames)

        name = possibleNames{k};

        if ismember(name, T.Properties.VariableNames)

            raw = T.(name);

            if iscell(raw)
                raw = cellfun(@double, raw);
            end

            if isstring(raw)
                raw = str2double(raw);
            end

            values = double(raw(:));
            return;
        end
    end

    if isscalar(defaultValue)
        values = repmat(defaultValue, n, 1);
    else
        values = defaultValue(:);
    end
end


% =========================================================================
% FINAL SOH
% =========================================================================
function finalSoH = local_get_final_soh(T, DB, nCandidates)

    possibleTableNames = { ...
        'finalSoH', ...
        'SOH_final', ...
        'finalSOH', ...
        'bessFinalSoH', ...
        'BESS_finalSoH', ...
        'eval_finalSoH'};

    for k = 1:numel(possibleTableNames)

        name = possibleTableNames{k};

        if ismember(name, T.Properties.VariableNames)

            finalSoH = double(T.(name)(:));

            finalSoH(finalSoH <= 0 | finalSoH > 1 | ~isfinite(finalSoH)) = NaN;

            if ismember('E_BESS_kWh', T.Properties.VariableNames)
                noBessMask = T.E_BESS_kWh <= 1e-9;
                finalSoH(noBessMask) = 1;
            end

            missingMask = isnan(finalSoH);

            if any(missingMask)
                warning('%d candidate eseteben hianyzik a finalSoH. Ezeknel finalSoH = 1 lesz.', sum(missingMask));
                finalSoH(missingMask) = 1;
            end

            return;
        end
    end

    if isfield(DB, 'candidateProfiles')

        P = DB.candidateProfiles;

        possibleProfileNames = { ...
            'meanSoH', ...
            'minSoH', ...
            'finalSoH'};

        for k = 1:numel(possibleProfileNames)

            name = possibleProfileNames{k};

            if isfield(P, name)

                M = P.(name);

                if size(M, 1) == nCandidates
                    finalSoH = double(M(:, end));
                    finalSoH(finalSoH <= 0 | finalSoH > 1 | ~isfinite(finalSoH)) = 1;
                    return;
                end
            end
        end
    end

    warning(['Nem talaltam final SoH mezot a DB-ben. ', ...
             'A BESS degradacios CAPEX koltseg pontatlan lesz, mert finalSoH = 1 ertekkel szamolok.']);

    finalSoH = ones(nCandidates, 1);
end


% =========================================================================
% SAFE DIVIDE
% =========================================================================
function y = local_safe_divide_vec(a, b)

    y = NaN(size(a));

    mask = isfinite(a) & isfinite(b) & abs(b) > 1e-12;

    y(mask) = a(mask) ./ b(mask);
end


% =========================================================================
% CFG HELPERS
% =========================================================================
function value = local_get_cfg_value(cfg, pathCells, defaultValue)

    value = defaultValue;

    current = cfg;

    for k = 1:numel(pathCells)

        fieldName = pathCells{k};

        if ~isstruct(current) || ~isfield(current, fieldName)
            value = defaultValue;
            return;
        end

        current = current.(fieldName);
    end

    if isempty(current)
        value = defaultValue;
    else
        value = current;
    end
end


function value = local_get_first_cfg_value(cfg, pathList, defaultValue)

    value = defaultValue;

    for i = 1:numel(pathList)

        pathCells = pathList{i};
        tmp = local_get_cfg_value(cfg, pathCells, []);

        if ~isempty(tmp)
            value = tmp;
            return;
        end
    end
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

        prevCumulative = cumulative;
        cumulative = cumulative + annualNetCashflow / ((1 + discountRate) ^ y);

        if cumulative >= 0

            yearlyDiscountedCashflow = cumulative - prevCumulative;

            if yearlyDiscountedCashflow <= 0
                paybackYear = y;
            else
                fraction = abs(prevCumulative) / yearlyDiscountedCashflow;
                paybackYear = (y - 1) + fraction;
            end

            return;
        end
    end

    paybackYear = inf;
end


% =========================================================================
% BEST PICKER
% =========================================================================
function bestIdx = local_pick_best_index(metricValues, feasibleMask, direction)

    metricValues = metricValues(:);
    feasibleMask = feasibleMask(:);

    if ~any(feasibleMask)
        warning('Nincs feasible candidate a megadott szurokkel. A teljes halmazon valasztok.');
        feasibleMask = isfinite(metricValues);
    end

    if ~any(feasibleMask)
        error('Nincs egyetlen ertekelheto candidate sem.');
    end

    switch lower(string(direction))

        case "max"
            tmp = metricValues;
            tmp(~feasibleMask) = -inf;
            [~, bestIdx] = max(tmp);

        case "min"
            tmp = metricValues;
            tmp(~feasibleMask) = inf;
            [~, bestIdx] = min(tmp);

        otherwise
            error('Ismeretlen direction: %s', direction);
    end
end


% =========================================================================
% PLOT WRAPPER
% =========================================================================
function local_plot_metric_set(P_inv_kW, P_PV_kW, E_BESS_kWh, DCAC_ratio, BESS_PV_ratio, ...
    metricValues, metricName, metricUnit, bestIdx, savePath, fileTag)

    local_plot_3d_scatter( ...
        P_inv_kW, ...
        P_PV_kW, ...
        E_BESS_kWh, ...
        metricValues, ...
        metricName, ...
        metricUnit, ...
        bestIdx, ...
        savePath, ...
        fileTag);

    local_plot_inverter_heatmaps( ...
        P_inv_kW, ...
        DCAC_ratio, ...
        BESS_PV_ratio, ...
        metricValues, ...
        metricName, ...
        metricUnit, ...
        bestIdx, ...
        savePath, ...
        fileTag);
end


% =========================================================================
% 3D SCATTER
% =========================================================================
function local_plot_3d_scatter(P_inv_kW, P_PV_kW, E_BESS_kWh, metricValues, ...
    metricName, metricUnit, bestIdx, savePath, fileTag)

    fig = figure('Name', ['3D scatter - ', metricName], ...
        'Position', [100, 100, 1100, 800]);

    hold on;
    grid on;
    box on;

    finiteMask = isfinite(metricValues) & ...
                 isfinite(P_inv_kW) & ...
                 isfinite(P_PV_kW) & ...
                 isfinite(E_BESS_kWh);

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

    xlabel('P_{inv} [kW]');
    ylabel('P_{PV} [kW]');
    zlabel('E_{BESS} [kWh]');

    title(sprintf('%s in candidate space', metricName), ...
        'Interpreter', 'none');

    cb = colorbar;
    cb.Label.String = sprintf('%s [%s]', metricName, metricUnit);

    view(45, 25);

    saveas(fig, fullfile(savePath, ['scatter3_', fileTag, '.png']));
    savefig(fig, fullfile(savePath, ['scatter3_', fileTag, '.fig']));
end


% =========================================================================
% INVERTERENKENTI HEATMAP
% =========================================================================
function local_plot_inverter_heatmaps(P_inv_kW, DCAC_ratio, BESS_PV_ratio, metricValues, ...
    metricName, metricUnit, bestIdx, savePath, fileTag)
% LOCAL_PLOT_INVERTER_HEATMAPS
%
% Egy metrikahoz inverterenkenti heatmapeket rajzol.
% Az osszes subplot ugyanazt a color range-et hasznalja.

    uniqueInv = unique(P_inv_kW(isfinite(P_inv_kW)));
    uniqueInv = sort(uniqueInv(:));

    if isempty(uniqueInv)
        warning('Nincs ervenyes invertermeret a heatmaphez: %s', metricName);
        return;
    end

    if numel(uniqueInv) > 4
        uniqueInv = uniqueInv(1:4);
    end

    xVals = unique(DCAC_ratio(isfinite(DCAC_ratio)));
    yVals = unique(BESS_PV_ratio(isfinite(BESS_PV_ratio)));

    xVals = sort(xVals(:));
    yVals = sort(yVals(:));

    finiteVals = metricValues(isfinite(metricValues));

    if isempty(finiteVals)
        commonCLim = [0, 1];
    else
        vMin = min(finiteVals);
        vMax = max(finiteVals);

        if abs(vMax - vMin) < 1e-12
            pad = max(abs(vMin) * 0.01, 1e-6);
            commonCLim = [vMin - pad, vMax + pad];
        else
            commonCLim = [vMin, vMax];
        end
    end

    fig = figure('Name', ['Heatmaps by inverter - ', metricName], ...
        'Position', [120, 120, 1300, 850]);

    tiledlayout(2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

    for iInv = 1:4

        nexttile;
        hold on;
        grid on;

        if iInv > numel(uniqueInv)
            axis off;
            continue;
        end

        invValue = uniqueInv(iInv);

        Z = NaN(numel(yVals), numel(xVals));

        for ix = 1:numel(xVals)
            for iy = 1:numel(yVals)

                mask = abs(P_inv_kW - invValue) < 1e-9 & ...
                       abs(DCAC_ratio - xVals(ix)) < 1e-9 & ...
                       abs(BESS_PV_ratio - yVals(iy)) < 1e-9;

                if any(mask)
                    Z(iy, ix) = mean(metricValues(mask), 'omitnan');
                end
            end
        end

        imagesc(xVals, yVals, Z);
        set(gca, 'YDir', 'normal');

        caxis(commonCLim);

        xlabel('DC/AC ratio [-]');
        ylabel('BESS/PV ratio [kWh/kWp]');
        title(sprintf('P_{inv} = %.0f kW', invValue));

        cb = colorbar;
        cb.Label.String = sprintf('%s [%s]', metricName, metricUnit);

        if abs(P_inv_kW(bestIdx) - invValue) < 1e-9
            plot(DCAC_ratio(bestIdx), BESS_PV_ratio(bestIdx), ...
                'kp', ...
                'MarkerSize', 14, ...
                'MarkerFaceColor', 'w', ...
                'LineWidth', 1.5);
        end
    end

    sgtitle(sprintf('%s by inverter size, common color range', metricName), ...
        'Interpreter', 'none');

    saveas(fig, fullfile(savePath, ['heatmap_by_inverter_', fileTag, '.png']));
    savefig(fig, fullfile(savePath, ['heatmap_by_inverter_', fileTag, '.fig']));
end


% =========================================================================
% BEST CANDIDATE SUMMARY PLOT
% =========================================================================
function local_plot_best_candidate_summary(resultTable, bestIdx, savePath)

    labels = categorical({ ...
        'Grid import reduction', ...
        'Self-consumption', ...
        'Self-sufficiency', ...
        'Curtailment', ...
        'Final SoH'});

    values = [ ...
        resultTable.gridImportReduction_pct(bestIdx), ...
        resultTable.selfConsumption_pct(bestIdx), ...
        resultTable.selfSufficiency_pct(bestIdx), ...
        resultTable.curtailment_pct(bestIdx), ...
        resultTable.finalSoH(bestIdx) * 100];

    fig = figure('Name', 'Best candidate technical metrics', ...
        'Position', [200, 200, 1000, 650]);

    bar(labels, values);
    grid on;
    ylabel('[%]');
    title('Best candidate technical indicators');
    ylim([0, max(100, max(values) * 1.15)]);

    saveas(fig, fullfile(savePath, 'best_candidate_technical_summary.png'));
    savefig(fig, fullfile(savePath, 'best_candidate_technical_summary.fig'));

    costLabels = categorical({ ...
        'Initial CAPEX', ...
        'Allocated total cost', ...
        'Energy savings', ...
        'Period net value', ...
        'NPV'});

    costValues = [ ...
        resultTable.initialCapex_HUF(bestIdx), ...
        resultTable.allocatedTotalCost_HUF(bestIdx), ...
        resultTable.energyCostSavings_HUF(bestIdx), ...
        resultTable.periodNetValue_HUF(bestIdx), ...
        resultTable.NPV_HUF(bestIdx)] / 1e6;

    fig2 = figure('Name', 'Best candidate economic metrics', ...
        'Position', [250, 250, 1000, 650]);

    bar(costLabels, costValues);
    grid on;
    ylabel('[million HUF]');
    title('Best candidate economic indicators');

    saveas(fig2, fullfile(savePath, 'best_candidate_economic_summary.png'));
    savefig(fig2, fullfile(savePath, 'best_candidate_economic_summary.fig'));
end