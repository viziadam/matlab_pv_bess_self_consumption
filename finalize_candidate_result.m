function DB = finalize_candidate_result(DB, candidateIndex, running, runtime_s, cfg)
% FINALIZE_CANDIDATE_RESULT
%
% Egy candidate osszes napi futasa utan:
%   1) automatikusan feltolti a cfg.output.scalarMetrics alapjan
%      definialt scalar metrikakat
%
%   2) automatikusan feltolti a cfg.output.profileMetrics alapjan
%      definialt napon beluli profilokat
%
%   3) kulon, kezzel definialt szarmaztatott metrikakat szamol:
%      - self-consumption mutatok
%      - self-sufficiency mutatok
%      - grid import/export mutatok
%      - BESS ciklusszam
%      - koltsegmutatok
%
% Fontos:
%   Ha uj alap scalar/profile metrikat adsz hozza a cfg.output listakhoz,
%   ezt a fuggvenyt nem kell atirni.
%
%   Csak akkor kell modositani, ha uj szarmaztatott metrikat akarsz
%   kiszamolni.

    % ---------------------------------------------------------------------
    % 0) Alap ellenorzesek
    % ---------------------------------------------------------------------
    if running.nDays <= 0
        error('running.nDays <= 0. Nem lehet finalize-olni.');
    end

    if candidateIndex < 1 || candidateIndex > height(DB.candidateTable)
        error('Ervenytelen candidateIndex: %d', candidateIndex);
    end

    i = candidateIndex;

    % ---------------------------------------------------------------------
    % 1) Status mezok
    % ---------------------------------------------------------------------
    DB.candidateTable.wasSimulated(i) = true;
    DB.candidateTable.hasError(i) = false;
    DB.candidateTable.errorMessage(i) = "";
    DB.candidateTable.runtime_s(i) = runtime_s;

    % ---------------------------------------------------------------------
    % 2) Automatikus scalar metrikak mentese
    % ---------------------------------------------------------------------
    DB = local_finalize_scalar_metrics(DB, i, running, cfg);

    % ---------------------------------------------------------------------
    % 3) Automatikus profile metrikak mentese
    % ---------------------------------------------------------------------
    DB = local_finalize_profile_metrics(DB, i, running, cfg);

    % ---------------------------------------------------------------------
    % 4) KULON KEZELT SZARMAZTATOTT METRIKAK
    % ---------------------------------------------------------------------
    DB = local_finalize_self_consumption_derived_metrics(DB, i);

    % ---------------------------------------------------------------------
    % 5) KULON KEZELT KOLTSEGMETRIKAK
    % ---------------------------------------------------------------------
    DB = local_finalize_cost_metrics(DB, i, cfg);
end


% =========================================================================
% AUTOMATIKUS SCALAR METRIKAK
% =========================================================================
function DB = local_finalize_scalar_metrics(DB, rowIdx, running, cfg)
% LOCAL_FINALIZE_SCALAR_METRICS
%
% Minden cfg.output.scalarMetrics elemhez megkeresi a running.scalar
% megfelelo mezojet, majd beirja a candidateTable-be.
%
% Ha a candidateTable-ben meg nincs ilyen oszlop, automatikusan letrehozza.

    for k = 1:numel(cfg.output.scalarMetrics)

        metricName = char(cfg.output.scalarMetrics(k).name);

        if ~isfield(running.scalar, metricName)
            error('running.scalar nem tartalmazza ezt a metrikat: %s', metricName);
        end

        DB.candidateTable = local_ensure_table_numeric_column( ...
            DB.candidateTable, metricName, height(DB.candidateTable));

        DB.candidateTable.(metricName)(rowIdx) = running.scalar.(metricName);
    end
end


% =========================================================================
% AUTOMATIKUS PROFILE METRIKAK
% =========================================================================
function DB = local_finalize_profile_metrics(DB, rowIdx, running, cfg)
% LOCAL_FINALIZE_PROFILE_METRICS
%
% Minden cfg.output.profileMetrics elemhez a mode alapjan kivalasztja
% a megfelelo running tarolot:
%
%   meanProfile -> running.profileSum / nDays
%   maxProfile  -> running.profileMax
%   minProfile  -> running.profileMin
%
% Majd beirja a DB.candidateProfiles megfelelo mezojebe.
%
% Ha a candidateProfiles-ban meg nincs ilyen mezo, automatikusan letrehozza.

    nCandidates = DB.nCandidates;
    nT = DB.nT;

    if ~isfield(DB, 'candidateProfiles') || isempty(DB.candidateProfiles)
        DB.candidateProfiles = struct();
    end

    for k = 1:numel(cfg.output.profileMetrics)

        metricName = char(cfg.output.profileMetrics(k).name);
        modeName = string(cfg.output.profileMetrics(k).mode);

        switch modeName

            case "meanProfile"

                if ~isfield(running.profileSum, metricName)
                    error('running.profileSum nem tartalmazza ezt a profilt: %s', metricName);
                end

                profileValue = running.profileSum.(metricName) / running.nDays;

            case "maxProfile"

                if ~isfield(running.profileMax, metricName)
                    error('running.profileMax nem tartalmazza ezt a profilt: %s', metricName);
                end

                profileValue = running.profileMax.(metricName);

            case "minProfile"

                if ~isfield(running.profileMin, metricName)
                    error('running.profileMin nem tartalmazza ezt a profilt: %s', metricName);
                end

                profileValue = running.profileMin.(metricName);

            otherwise
                error('Ismeretlen profile metric mode finalize kozben: %s', modeName);
        end

        profileValue = profileValue(:).';

        if numel(profileValue) ~= nT
            error('A(z) %s profil hossza hibas. Vart: %d, kapott: %d', ...
                metricName, nT, numel(profileValue));
        end

        DB.candidateProfiles = local_ensure_profile_field( ...
            DB.candidateProfiles, metricName, nCandidates, nT);

        DB.candidateProfiles.(metricName)(rowIdx, :) = profileValue;
    end
end


% =========================================================================
% SZARMAZTATOTT SELF-CONSUMPTION METRIKAK
% =========================================================================
function DB = local_finalize_self_consumption_derived_metrics(DB, rowIdx)
% LOCAL_FINALIZE_SELF_CONSUMPTION_DERIVED_METRICS
%
% Ezek nem egyszeru cfg.output metrikak, hanem tobb alapmetrikabol
% szarmaztatott mutatok.
%
% Ha ezek kozul barmelyiket modositani vagy boviteni akarod, akkor itt kell.

    T = DB.candidateTable;

    % ---------------------------------------------------------------------
    % Szükséges alapmetrikák kiolvasása
    % ---------------------------------------------------------------------
    loadEnergy_kWh = local_get_table_value(T, rowIdx, 'loadEnergy_kWh');

    % A PV energia neve lehet tobbfele, ezert aliasokat is engedunk.
    pvEnergyAvailable_kWh = local_get_first_available_table_value(T, rowIdx, { ...
        'pvEnergyAvailable_kWh', ...
        'pvEnergy_kWh'});

    pvToLoad_kWh = local_get_table_value(T, rowIdx, 'pvToLoad_kWh');
    pvToBess_kWh = local_get_table_value(T, rowIdx, 'pvToBess_kWh');
    bessToLoad_kWh = local_get_table_value(T, rowIdx, 'bessToLoad_kWh');

    gridImport_kWh = local_get_table_value(T, rowIdx, 'gridImport_kWh');
    gridExport_kWh = local_get_table_value(T, rowIdx, 'gridExport_kWh');
    curtailment_kWh = local_get_table_value(T, rowIdx, 'curtailment_kWh');

    E_BESS_kWh = local_get_table_value(T, rowIdx, 'E_BESS_kWh');

    % ---------------------------------------------------------------------
    % Származtatott energiaáramok
    % ---------------------------------------------------------------------
    % Brutto PV onfogyasztas:
    %   direkt PV -> load
    %   plusz PV -> BESS
    %
    % Ez azt mutatja, hogy a megtermelt PV energiabol mennyi nem ment
    % kozvetlenul exportra/curtailmentre.
    pvSelfConsumedGross_kWh = pvToLoad_kWh + pvToBess_kWh;

    % Hasznos PV onfogyasztas:
    %   direkt PV -> load
    %   plusz BESS -> load
    %
    % Ez mar a tarolasi veszteségek utan hasznos fogyasztasra jutott energia.
    pvSelfConsumedUseful_kWh = pvToLoad_kWh + bessToLoad_kWh;

    % ---------------------------------------------------------------------
    % Oszlopok biztositasa
    % ---------------------------------------------------------------------
    derivedColumns = { ...
        'pvSelfConsumedGross_kWh', ...
        'pvSelfConsumedUseful_kWh', ...
        'directSelfConsumptionRatio', ...
        'selfConsumptionRatio', ...
        'selfConsumptionUsefulRatio', ...
        'selfSufficiencyRatio', ...
        'gridImportReductionRatio', ...
        'gridExportRatio', ...
        'curtailmentRatio', ...
        'bessEquivalentCycles'};

    for k = 1:numel(derivedColumns)
        DB.candidateTable = local_ensure_table_numeric_column( ...
            DB.candidateTable, derivedColumns{k}, height(DB.candidateTable));
    end

    % ---------------------------------------------------------------------
    % Mutatok szamitasa
    % ---------------------------------------------------------------------
    DB.candidateTable.pvSelfConsumedGross_kWh(rowIdx) = pvSelfConsumedGross_kWh;
    DB.candidateTable.pvSelfConsumedUseful_kWh(rowIdx) = pvSelfConsumedUseful_kWh;

    DB.candidateTable.directSelfConsumptionRatio(rowIdx) = ...
        local_safe_divide(pvToLoad_kWh, pvEnergyAvailable_kWh);

    DB.candidateTable.selfConsumptionRatio(rowIdx) = ...
        local_safe_divide(pvSelfConsumedGross_kWh, pvEnergyAvailable_kWh);

    DB.candidateTable.selfConsumptionUsefulRatio(rowIdx) = ...
        local_safe_divide(pvSelfConsumedUseful_kWh, pvEnergyAvailable_kWh);

    DB.candidateTable.selfSufficiencyRatio(rowIdx) = ...
        local_safe_divide(pvSelfConsumedUseful_kWh, loadEnergy_kWh);

    % Grid-only esethez viszonyitva:
    % grid-only import = loadEnergy_kWh
    DB.candidateTable.gridImportReductionRatio(rowIdx) = ...
        1 - local_safe_divide(gridImport_kWh, loadEnergy_kWh);

    DB.candidateTable.gridExportRatio(rowIdx) = ...
        local_safe_divide(gridExport_kWh, pvEnergyAvailable_kWh);

    DB.candidateTable.curtailmentRatio(rowIdx) = ...
        local_safe_divide(curtailment_kWh, pvEnergyAvailable_kWh);

    % Ekvivalens BESS ciklusszam throughput alapon:
    %
    % cycles = (E_charge + E_discharge) / (2 * E_nominal)
    %
    % Itt:
    %   E_charge    ~ pvToBess_kWh
    %   E_discharge ~ bessToLoad_kWh
    DB.candidateTable.bessEquivalentCycles(rowIdx) = ...
        local_safe_divide(pvToBess_kWh + bessToLoad_kWh, 2 * E_BESS_kWh);
end


% =========================================================================
% SZARMAZTATOTT KOLTSEGMETRIKAK
% =========================================================================
function DB = local_finalize_cost_metrics(DB, rowIdx, cfg)
% LOCAL_FINALIZE_COST_METRICS
%
% Ezek szinten szarmaztatott metrikak, mert a candidate meretekbol es
% energiaaramokbol szamoljuk oket.
%
% Ha uj gazdasagi modellt akarsz, akkor itt kell modositani.

    T = DB.candidateTable;

    % ---------------------------------------------------------------------
    % Candidate meretek
    % ---------------------------------------------------------------------
    P_PV_kW = local_get_first_available_table_value(T, rowIdx, { ...
        'P_PV_kW', ...
        'PV_kW'});

    E_BESS_kWh = local_get_table_value(T, rowIdx, 'E_BESS_kWh');
    P_BESS_kW = local_get_table_value(T, rowIdx, 'P_BESS_kW');
    P_inv_kW = local_get_table_value(T, rowIdx, 'P_inv_kW');

    % ---------------------------------------------------------------------
    % Energiaaramok
    % ---------------------------------------------------------------------
    loadEnergy_kWh = local_get_table_value(T, rowIdx, 'loadEnergy_kWh');
    gridImport_kWh = local_get_table_value(T, rowIdx, 'gridImport_kWh');
    gridExport_kWh = local_get_table_value(T, rowIdx, 'gridExport_kWh');

    pvSelfConsumedUseful_kWh = local_get_table_value(T, rowIdx, 'pvSelfConsumedUseful_kWh');

    % ---------------------------------------------------------------------
    % Cost parameterek
    % ---------------------------------------------------------------------
    pv_huf_per_kWp = local_get_cfg_value(cfg, {'cost', 'pv_huf_per_kWp'}, 0);
    bess_huf_per_kWh = local_get_cfg_value(cfg, {'cost', 'bess_huf_per_kWh'}, 0);
    bess_power_huf_per_kW = local_get_cfg_value(cfg, {'cost', 'bess_power_huf_per_kW'}, 0);
    inverter_huf_per_kW = local_get_cfg_value(cfg, {'cost', 'inverter_huf_per_kW'}, 0);

    grid_import_huf_per_kWh = local_get_cfg_value(cfg, {'cost', 'grid_import_huf_per_kWh'}, 0);
    grid_export_huf_per_kWh = local_get_cfg_value(cfg, {'cost', 'grid_export_huf_per_kWh'}, 0);

    % ---------------------------------------------------------------------
    % Oszlopok biztositasa
    % ---------------------------------------------------------------------
    costColumns = { ...
        'capexPV_HUF', ...
        'capexBESS_energy_HUF', ...
        'capexBESS_power_HUF', ...
        'capexInverter_HUF', ...
        'totalCapex_HUF', ...
        'gridOnlyEnergyCost_HUF', ...
        'systemGridEnergyCost_HUF', ...
        'gridExportRevenue_HUF', ...
        'energyCostSavings_HUF', ...
        'simplePayback_year', ...
        'LCOE_HUF_per_kWh'};

    for k = 1:numel(costColumns)
        DB.candidateTable = local_ensure_table_numeric_column( ...
            DB.candidateTable, costColumns{k}, height(DB.candidateTable));
    end

    % ---------------------------------------------------------------------
    % CAPEX
    % ---------------------------------------------------------------------
    capexPV = P_PV_kW * pv_huf_per_kWp;
    capexBessEnergy = E_BESS_kWh * bess_huf_per_kWh;
    capexBessPower = P_BESS_kW * bess_power_huf_per_kW;
    capexInverter = P_inv_kW * inverter_huf_per_kW;

    totalCapex = capexPV + capexBessEnergy + capexBessPower + capexInverter;

    % ---------------------------------------------------------------------
    % Energia koltsegek
    % ---------------------------------------------------------------------
    gridOnlyEnergyCost = loadEnergy_kWh * grid_import_huf_per_kWh;

    gridImportCost = gridImport_kWh * grid_import_huf_per_kWh;
    gridExportRevenue = gridExport_kWh * grid_export_huf_per_kWh;

    systemGridEnergyCost = gridImportCost - gridExportRevenue;

    energyCostSavings = gridOnlyEnergyCost - systemGridEnergyCost;

    % ---------------------------------------------------------------------
    % Eredmenyek mentese
    % ---------------------------------------------------------------------
    DB.candidateTable.capexPV_HUF(rowIdx) = capexPV;
    DB.candidateTable.capexBESS_energy_HUF(rowIdx) = capexBessEnergy;
    DB.candidateTable.capexBESS_power_HUF(rowIdx) = capexBessPower;
    DB.candidateTable.capexInverter_HUF(rowIdx) = capexInverter;
    DB.candidateTable.totalCapex_HUF(rowIdx) = totalCapex;

    DB.candidateTable.gridOnlyEnergyCost_HUF(rowIdx) = gridOnlyEnergyCost;
    DB.candidateTable.systemGridEnergyCost_HUF(rowIdx) = systemGridEnergyCost;
    DB.candidateTable.gridExportRevenue_HUF(rowIdx) = gridExportRevenue;
    DB.candidateTable.energyCostSavings_HUF(rowIdx) = energyCostSavings;

    if energyCostSavings > 0
        DB.candidateTable.simplePayback_year(rowIdx) = totalCapex / energyCostSavings;
    else
        DB.candidateTable.simplePayback_year(rowIdx) = inf;
    end

    % Egyszeru LCOE-szeru mutato:
    % beruhazasi koltseg / hasznosan helyben felhasznalt PV energia.
    %
    % Ez meg nem teljes eletciklus LCOE, inkabb osszehasonlito mutato.
    DB.candidateTable.LCOE_HUF_per_kWh(rowIdx) = ...
        local_safe_divide(totalCapex, pvSelfConsumedUseful_kWh);
end


% =========================================================================
% SEGEDFUGGVENYEK
% =========================================================================
function T = local_ensure_table_numeric_column(T, colName, nRows)

    if ~ismember(colName, T.Properties.VariableNames)
        T.(colName) = NaN(nRows, 1);
    end
end


function profiles = local_ensure_profile_field(profiles, fieldName, nCandidates, nT)

    if ~isfield(profiles, fieldName)
        profiles.(fieldName) = NaN(nCandidates, nT);
    end
end


function value = local_get_table_value(T, rowIdx, colName)

    if ismember(colName, T.Properties.VariableNames)
        value = T.(colName)(rowIdx);
    else
        value = 0;
    end

    if isempty(value) || isnan(value)
        value = 0;
    end
end


function value = local_get_first_available_table_value(T, rowIdx, colNames)

    value = 0;

    for k = 1:numel(colNames)

        colName = colNames{k};

        if ismember(colName, T.Properties.VariableNames)
            value = T.(colName)(rowIdx);

            if ~isempty(value) && ~isnan(value)
                return;
            end
        end
    end

    value = 0;
end


function y = local_safe_divide(a, b)

    if isempty(b) || isnan(b) || abs(b) < 1e-12
        y = NaN;
    else
        y = a / b;
    end
end


function value = local_get_cfg_value(cfg, pathCells, defaultValue)
% LOCAL_GET_CFG_VALUE
%
% Pelda:
%   local_get_cfg_value(cfg, {'cost', 'pv_huf_per_kWp'}, 0)

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

    if isempty(current) || ~isnumeric(current)
        value = defaultValue;
    else
        value = current;
    end
end