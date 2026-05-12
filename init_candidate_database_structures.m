% function DB = init_candidate_database_structures(data, cfg)
% % INIT_OFFGRID_CANDIDATE_DATABASE
% %
% % Grid-connected PV+BESS self-consumption candidate adatbazist hoz letre.
% %
% % A nev kompatibilitas miatt maradhat init_offgrid_candidate_database,
% % de ez a verzio mar nem diesel/off-grid rendszerhez van.
% %
% % Ment:
% %   - candidateTable:
% %       egy sor = egy candidate osszesitett eredmenye
% %
% %   - baseProfiles:
% %       candidate-fuggetlen bemeneti napon beluli profilok
% %
% %   - candidateProfiles:
% %       candidate-fuggo aggregalt napon beluli profilok
% %
% % Fontos:
% %   A kimentendo skalark es profilok nem itt vannak kezzel felsorolva,
% %   hanem a cfg.output.scalarMetrics es cfg.output.profileMetrics alapjan
% %   jonnek letre.
% 
%     % ---------------------------------------------------------------------
%     % 1) Validalas
%     % ---------------------------------------------------------------------
%     local_validate_data(data);
%     local_validate_cfg(cfg);
% 
%     nDays = numel(data.days);
%     nT = numel(data.days(1).P_load_kW);
%     dt_h = data.days(1).dt_h;
% 
%     % ---------------------------------------------------------------------
%     % 2) Candidate tartomanyok
%     % ---------------------------------------------------------------------
%     PV_vec = cfg.candidates.PV_kW(:);
%     PV_scale_vec = cfg.candidates.PV_scale_vec(:);
%     BESS_PV_vec = cfg.candidates.BESS_PV_vec(:);
%     P_inv_vec = cfg.candidates.P_inv_kW_vec(:);
% 
%     if numel(PV_scale_vec) ~= numel(PV_vec)
%         error('cfg.candidates.PV_scale_vec es cfg.candidates.PV_kW merete nem egyezik.');
%     end
% 
%     nCandidates = numel(PV_vec) * numel(BESS_PV_vec) * numel(P_inv_vec);
% 
%     % ---------------------------------------------------------------------
%     % 3) Candidate table inicializalas
%     % ---------------------------------------------------------------------
%     candidateTable = local_create_candidate_table(nCandidates, cfg);
% 
%     idx = 0;
% 
%     for iPV = 1:numel(PV_vec)
% 
%         for iE = 1:numel(BESS_PV_vec)
% 
%             for iInv = 1:numel(P_inv_vec)
% 
%                 idx = idx + 1;
% 
%                 candidateBase = struct();
% 
%                 candidateBase.PV_scale = PV_scale_vec(iPV);
%                 candidateBase.P_PV_kW = PV_vec(iPV);
% 
%                 candidateBase.BESS_PV_ratio = BESS_PV_vec(iE);
% 
%                 candidateBase.E_BESS_kWh = ...
%                     candidateBase.BESS_PV_ratio * candidateBase.P_PV_kW;
% 
%                 candidateBase.P_BESS_kW = ...
%                     candidateBase.E_BESS_kWh / cfg.candidates.bessDuration_h;
% 
%                 candidateBase.P_inv_kW = P_inv_vec(iInv);
% 
%                 design = set_candidate_component_sizes(candidateBase, cfg);
% 
%                 candidateTable.candidateIndex(idx) = idx;
%                 candidateTable.candidateID(idx) = string(sprintf('CAND_%06d', idx));
% 
%                 candidateTable.PV_scale(idx) = design.PV_scale;
%                 candidateTable.BESS_PV_ratio(idx) = design.BESS_PV_ratio;
% 
%                 candidateTable.P_PV_kW(idx) = design.P_PV_kW;
% 
%                 % Kompatibilitasi alias, ha mas fuggvenyek PV_kW nevet varnak.
%                 candidateTable.PV_kW(idx) = design.PV_kW;
% 
%                 candidateTable.E_BESS_kWh(idx) = design.E_BESS_kWh;
%                 candidateTable.P_BESS_kW(idx) = design.P_BESS_kW;
%                 candidateTable.P_inv_kW(idx) = design.P_inv_kW;
%             end
%         end
%     end
% 
%     % ---------------------------------------------------------------------
%     % 4) DB struktura felepitese
%     % ---------------------------------------------------------------------
%     DB = struct();
% 
%     DB.version = "self_consumption_candidate_database_scalar_profile_v1";
%     DB.createdAt = datetime('now');
% 
%     DB.nCandidates = nCandidates;
%     DB.nDays = nDays;
%     DB.nT = nT;
%     DB.dt_h = dt_h;
% 
%     DB.profileAxis = struct();
%     DB.profileAxis.time_h = (0:nT-1) * dt_h;
% 
%     DB.cfgSnapshot = cfg;
% 
%     if isfield(data, 'info')
%         DB.dataInfo = data.info;
%     else
%         DB.dataInfo = struct();
%     end
% 
%     DB.candidateTable = candidateTable;
%     DB.baseProfiles = local_build_base_profiles(data);
%     DB.candidateProfiles = local_init_candidate_profiles(nCandidates, nT, cfg);
% 
%     fprintf('Self-consumption scalar/profile candidate database initialized.\n');
%     fprintf('Candidates: %d\n', nCandidates);
%     fprintf('Days: %d\n', nDays);
%     fprintf('Profile length: %d\n', nT);
% end
% 
% 
% % =========================================================================
% % DATA VALIDATION
% % =========================================================================
% function local_validate_data(data)
% 
%     if ~isfield(data, 'days')
%         error('Data must contain data.days.');
%     end
% 
%     if isempty(data.days)
%         error('data.days is empty.');
%     end
% 
%     requiredFields = {'P_load_kW', 'P_pv_base_kW', 'dt_h'};
% 
%     for f = 1:numel(requiredFields)
% 
%         if ~isfield(data.days(1), requiredFields{f})
%             error('data.days(1) missing required field: %s', requiredFields{f});
%         end
%     end
% 
%     nT = numel(data.days(1).P_load_kW);
%     dt_h = data.days(1).dt_h;
% 
%     for d = 1:numel(data.days)
% 
%         if numel(data.days(d).P_load_kW) ~= nT
%             error('All days must have the same P_load_kW length. Error at day %d.', d);
%         end
% 
%         if numel(data.days(d).P_pv_base_kW) ~= nT
%             error('All days must have the same P_pv_base_kW length. Error at day %d.', d);
%         end
% 
%         if abs(data.days(d).dt_h - dt_h) > 1e-12
%             error('All days must have the same dt_h. Error at day %d.', d);
%         end
%     end
% end
% 
% 
% % =========================================================================
% % CFG VALIDATION
% % =========================================================================
% function local_validate_cfg(cfg)
% 
%     if ~isfield(cfg, 'candidates')
%         error('cfg.candidates is missing.');
%     end
% 
%     requiredCandidateFields = { ...
%         'PV_kW', ...
%         'PV_scale_vec', ...
%         'BESS_PV_vec', ...
%         'P_inv_kW_vec', ...
%         'bessDuration_h'};
% 
%     for i = 1:numel(requiredCandidateFields)
%         f = requiredCandidateFields{i};
% 
%         if ~isfield(cfg.candidates, f)
%             error('cfg.candidates.%s is missing.', f);
%         end
%     end
% 
%     if ~isfield(cfg, 'output')
%         error('cfg.output is missing.');
%     end
% 
%     if ~isfield(cfg.output, 'scalarMetrics')
%         error('cfg.output.scalarMetrics is missing.');
%     end
% 
%     if ~isfield(cfg.output, 'profileMetrics')
%         error('cfg.output.profileMetrics is missing.');
%     end
% 
%     local_validate_metric_definitions(cfg.output.scalarMetrics, 'scalarMetrics');
%     local_validate_metric_definitions(cfg.output.profileMetrics, 'profileMetrics');
% end
% 
% 
% function local_validate_metric_definitions(metrics, metricGroupName)
% 
%     requiredFields = {'name', 'source', 'mode'};
% 
%     for i = 1:numel(requiredFields)
% 
%         if ~isfield(metrics, requiredFields{i})
%             error('cfg.output.%s missing field: %s', metricGroupName, requiredFields{i});
%         end
%     end
% 
%     for i = 1:numel(metrics)
% 
%         if strlength(string(metrics(i).name)) == 0
%             error('Empty metric name in cfg.output.%s at index %d.', metricGroupName, i);
%         end
% 
%         if strlength(string(metrics(i).source)) == 0
%             error('Empty metric source in cfg.output.%s at index %d.', metricGroupName, i);
%         end
% 
%         if strlength(string(metrics(i).mode)) == 0
%             error('Empty metric mode in cfg.output.%s at index %d.', metricGroupName, i);
%         end
%     end
% end
% 
% 
% % =========================================================================
% % CANDIDATE TABLE
% % =========================================================================
% function T = local_create_candidate_table(n, cfg)
% 
%     T = table();
% 
%     % ---------------------------------------------------------------------
%     % Candidate design / metadata
%     % ---------------------------------------------------------------------
%     T.candidateIndex = NaN(n, 1);
%     T.candidateID = strings(n, 1);
% 
%     T.PV_scale = NaN(n, 1);
%     T.BESS_PV_ratio = NaN(n, 1);
% 
%     T.P_PV_kW = NaN(n, 1);
% 
%     % Alias kompatibilitas miatt.
%     T.PV_kW = NaN(n, 1);
% 
%     T.E_BESS_kWh = NaN(n, 1);
%     T.P_BESS_kW = NaN(n, 1);
%     T.P_inv_kW = NaN(n, 1);
% 
%     % ---------------------------------------------------------------------
%     % Simulation status
%     % ---------------------------------------------------------------------
%     T.wasSimulated = false(n, 1);
%     T.hasError = false(n, 1);
%     T.errorMessage = strings(n, 1);
%     T.runtime_s = NaN(n, 1);
% 
%     % ---------------------------------------------------------------------
%     % Dynamic scalar metrics from cfg.output.scalarMetrics
%     % ---------------------------------------------------------------------
%     for i = 1:numel(cfg.output.scalarMetrics)
% 
%         metricName = char(cfg.output.scalarMetrics(i).name);
% 
%         if ~ismember(metricName, T.Properties.VariableNames)
%             T.(metricName) = NaN(n, 1);
%         end
%     end
% 
%     % ---------------------------------------------------------------------
%     % Derived self-consumption / operation metrics
%     % Ezeket a finalize_candidate_result tolti.
%     % ---------------------------------------------------------------------
%     derivedColumns = { ...
%         'pvSelfConsumedGross_kWh', ...
%         'pvSelfConsumedUseful_kWh', ...
%         'selfConsumptionRatio', ...
%         'selfConsumptionUsefulRatio', ...
%         'selfSufficiencyRatio', ...
%         'gridImportReductionRatio', ...
%         'gridExportRatio', ...
%         'curtailmentRatio', ...
%         'bessEquivalentCycles'};
% 
%     for i = 1:numel(derivedColumns)
% 
%         col = derivedColumns{i};
% 
%         if ~ismember(col, T.Properties.VariableNames)
%             T.(col) = NaN(n, 1);
%         end
%     end
% 
%     % ---------------------------------------------------------------------
%     % Cost metrics
%     % ---------------------------------------------------------------------
%     costColumns = { ...
%         'capexPV_HUF', ...
%         'capexBESS_energy_HUF', ...
%         'capexBESS_power_HUF', ...
%         'capexInverter_HUF', ...
%         'totalCapex_HUF', ...
%         'gridOnlyEnergyCost_HUF', ...
%         'systemGridEnergyCost_HUF', ...
%         'gridExportRevenue_HUF', ...
%         'energyCostSavings_HUF', ...
%         'simplePayback_year', ...
%         'LCOE_HUF_per_kWh'};
% 
%     for i = 1:numel(costColumns)
% 
%         col = costColumns{i};
% 
%         if ~ismember(col, T.Properties.VariableNames)
%             T.(col) = NaN(n, 1);
%         end
%     end
% end
% 
% 
% % =========================================================================
% % BASE PROFILES
% % =========================================================================
% function baseProfiles = local_build_base_profiles(data)
% 
%     nDays = numel(data.days);
%     nT = numel(data.days(1).P_load_kW);
%     dt_h = data.days(1).dt_h;
% 
%     loadMat = zeros(nDays, nT);
%     pvMat = zeros(nDays, nT);
% 
%     for d = 1:nDays
%         loadMat(d, :) = data.days(d).P_load_kW(:).';
%         pvMat(d, :) = data.days(d).P_pv_base_kW(:).';
%     end
% 
%     baseProfiles = struct();
% 
%     baseProfiles.time_h = (0:nT-1) * dt_h;
% 
%     baseProfiles.loadMeanProfile_kW = mean(loadMat, 1);
%     baseProfiles.loadPeakProfile_kW = max(loadMat, [], 1);
%     baseProfiles.loadMinProfile_kW = min(loadMat, [], 1);
% 
%     baseProfiles.pvBaseMeanProfile_kW = mean(pvMat, 1);
%     baseProfiles.pvBasePeakProfile_kW = max(pvMat, [], 1);
%     baseProfiles.pvBaseMinProfile_kW = min(pvMat, [], 1);
% 
%     baseProfiles.totalLoadEnergy_kWh = sum(loadMat, 'all') * dt_h;
%     baseProfiles.totalPvBaseEnergy_kWh = sum(pvMat, 'all') * dt_h;
% 
%     baseProfiles.dailyLoadEnergy_kWh = sum(loadMat, 2) * dt_h;
%     baseProfiles.dailyPvBaseEnergy_kWh = sum(pvMat, 2) * dt_h;
% 
%     baseProfiles.maxDailyLoadPeak_kW = max(max(loadMat, [], 2));
%     baseProfiles.meanDailyLoadPeak_kW = mean(max(loadMat, [], 2));
% end
% 
% 
% % =========================================================================
% % CANDIDATE PROFILES
% % =========================================================================
% function profiles = local_init_candidate_profiles(nCandidates, nT, cfg)
% 
%     profiles = struct();
% 
%     for i = 1:numel(cfg.output.profileMetrics)
% 
%         metricName = char(cfg.output.profileMetrics(i).name);
% 
%         if ~isfield(profiles, metricName)
%             profiles.(metricName) = NaN(nCandidates, nT);
%         end
%     end
% end
% 
% 
% % =========================================================================
% % CANDIDATE COMPONENT SIZES
% % =========================================================================
% function design = set_candidate_component_sizes(candidateBase, cfg)
% % SET_CANDIDATE_COMPONENT_SIZES
% %
% % Egy candidate teljes meretezeset allitja be.
% %
% % Jelenlegi verzio:
% %   - PV meret candidateBase-bol jon
% %   - BESS energia candidateBase-bol jon
% %   - BESS teljesitmeny candidateBase-bol jon
% %   - inverter meret candidateBase-bol jon
% %
% % Diesel generator nincs.
% 
%     design = struct();
% 
%     design.PV_scale = candidateBase.PV_scale;
%     design.BESS_PV_ratio = candidateBase.BESS_PV_ratio;
% 
%     design.P_PV_kW = candidateBase.P_PV_kW;
% 
%     % Kompatibilitasi alias.
%     design.PV_kW = candidateBase.P_PV_kW;
% 
%     design.E_BESS_kWh = candidateBase.E_BESS_kWh;
%     design.P_BESS_kW = candidateBase.P_BESS_kW;
% 
%     design.P_inv_kW = candidateBase.P_inv_kW;
% 
%     if isfield(cfg, 'internalNetwork') && isfield(cfg.internalNetwork, 'lossFraction')
%         design.internalNetworkLossFraction = cfg.internalNetwork.lossFraction;
%     else
%         design.internalNetworkLossFraction = 0;
%     end
% end

function DB = init_candidate_database_structures(data, cfg)
% INIT_CANDIDATE_DATABASE_STRUCTURES
%
% Grid-connected PV+BESS self-consumption candidate adatbazist hoz letre.
%
% Candidate felepites:
%
%   P_inv_kW
%       x DCAC_ratio
%           x BESS_PV_ratio
%
% Szarmaztatott meretek:
%
%   P_PV_kW     = P_inv_kW * DCAC_ratio
%   E_BESS_kWh = BESS_PV_ratio * P_PV_kW
%   P_BESS_kW  = E_BESS_kWh / bessDuration_h
%
% Fontos:
%   A candidate design mezok egy helyrol jonnek:
%       cfg.candidates.designFields
%
%   Ha ez nincs megadva, akkor az alapertelmezett grid-connected
%   PV+BESS design mezoket hasznaljuk.
%
%   Diesel generator nincs, ezert P_DG_kW sem szerepel.

    % ---------------------------------------------------------------------
    % 1) Validalas
    % ---------------------------------------------------------------------
    local_validate_data(data);
    local_validate_cfg(cfg);

    nDays = numel(data.days);
    nT = numel(data.days(1).P_load_kW);
    dt_h = data.days(1).dt_h;

    % ---------------------------------------------------------------------
    % 2) Candidate tartomanyok
    % ---------------------------------------------------------------------
    P_inv_vec = cfg.candidates.P_inv_kW_vec(:);
    DCAC_ratio_vec = local_get_dcac_ratio_vec(cfg);
    BESS_PV_vec = cfg.candidates.BESS_PV_vec(:);

    nCandidates = ...
        numel(P_inv_vec) * ...
        numel(DCAC_ratio_vec) * ...
        numel(BESS_PV_vec);

    % ---------------------------------------------------------------------
    % 3) Kozponti candidate design mezok
    % ---------------------------------------------------------------------
    designFields = local_get_candidate_design_fields(cfg);

    % ---------------------------------------------------------------------
    % 4) Candidate table inicializalas
    % ---------------------------------------------------------------------
    candidateTable = local_create_candidate_table(nCandidates, cfg, designFields);

    idx = 0;

    for iInv = 1:numel(P_inv_vec)

        for iDCAC = 1:numel(DCAC_ratio_vec)

            for iBESS = 1:numel(BESS_PV_vec)

                idx = idx + 1;

                candidateBase = struct();

                % ---------------------------------------------------------
                % Fo candidate dimenziok
                % ---------------------------------------------------------
                candidateBase.P_inv_kW = P_inv_vec(iInv);
                candidateBase.DCAC_ratio = DCAC_ratio_vec(iDCAC);
                candidateBase.BESS_PV_ratio = BESS_PV_vec(iBESS);

                % ---------------------------------------------------------
                % PV meret DC/AC arany alapjan
                % ---------------------------------------------------------
                candidateBase.P_PV_kW = ...
                    candidateBase.P_inv_kW * candidateBase.DCAC_ratio;

                % ---------------------------------------------------------
                % BESS energiameret BESS/PV arany alapjan
                % ---------------------------------------------------------
                candidateBase.E_BESS_kWh = ...
                    candidateBase.BESS_PV_ratio * candidateBase.P_PV_kW;

                % ---------------------------------------------------------
                % BESS teljesitmeny duration alapjan
                % Ha bessDuration_h = 2, akkor P_BESS = E_BESS / 2.
                % ---------------------------------------------------------
                candidateBase.P_BESS_kW = ...
                    candidateBase.E_BESS_kWh / cfg.candidates.bessDuration_h;

                design = set_candidate_component_sizes(candidateBase, cfg);

                % ---------------------------------------------------------
                % Candidate metadata
                % ---------------------------------------------------------
                candidateTable.candidateIndex(idx) = idx;
                candidateTable.candidateID(idx) = string(sprintf('CAND_%06d', idx));

                % ---------------------------------------------------------
                % Design mezok kozponti listabol
                % ---------------------------------------------------------
                candidateTable = local_write_design_to_candidate_table( ...
                    candidateTable, ...
                    idx, ...
                    design, ...
                    designFields);
            end
        end
    end

    % ---------------------------------------------------------------------
    % 5) DB struktura felepitese
    % ---------------------------------------------------------------------
    DB = struct();

    DB.version = "self_consumption_candidate_database_dcac_besspv_v2";
    DB.createdAt = datetime('now');

    DB.nCandidates = nCandidates;
    DB.nDays = nDays;
    DB.nT = nT;
    DB.dt_h = dt_h;

    DB.profileAxis = struct();
    DB.profileAxis.time_h = (0:nT-1) * dt_h;

    DB.cfgSnapshot = cfg;

    % Ez a lista kell kesobb a table_row_to_design fuggvenynek.
    DB.candidateDesignFields = designFields;

    if isfield(data, 'info')
        DB.dataInfo = data.info;
    else
        DB.dataInfo = struct();
    end

    DB.candidateTable = candidateTable;
    DB.baseProfiles = local_build_base_profiles(data);
    DB.candidateProfiles = local_init_candidate_profiles(nCandidates, nT, cfg);

    fprintf('Self-consumption candidate database initialized.\n');
    fprintf('Candidate structure: P_inv_kW x DCAC_ratio x BESS_PV_ratio\n');
    fprintf('Inverter sizes: %d\n', numel(P_inv_vec));
    fprintf('DC/AC ratios: %d\n', numel(DCAC_ratio_vec));
    fprintf('BESS/PV ratios: %d\n', numel(BESS_PV_vec));
    fprintf('Total candidates: %d\n', nCandidates);
    fprintf('Days: %d\n', nDays);
    fprintf('Profile length: %d\n', nT);

    fprintf('Design fields:\n');
    disp(designFields);
end


% =========================================================================
% DATA VALIDATION
% =========================================================================
function local_validate_data(data)

    if ~isfield(data, 'days')
        error('Data must contain data.days.');
    end

    if isempty(data.days)
        error('data.days is empty.');
    end

    requiredFields = {'P_load_kW', 'P_pv_base_kW', 'dt_h'};

    for f = 1:numel(requiredFields)

        if ~isfield(data.days(1), requiredFields{f})
            error('data.days(1) missing required field: %s', requiredFields{f});
        end
    end

    nT = numel(data.days(1).P_load_kW);
    dt_h = data.days(1).dt_h;

    for d = 1:numel(data.days)

        if numel(data.days(d).P_load_kW) ~= nT
            error('All days must have the same P_load_kW length. Error at day %d.', d);
        end

        if numel(data.days(d).P_pv_base_kW) ~= nT
            error('All days must have the same P_pv_base_kW length. Error at day %d.', d);
        end

        if abs(data.days(d).dt_h - dt_h) > 1e-12
            error('All days must have the same dt_h. Error at day %d.', d);
        end
    end
end


% =========================================================================
% CFG VALIDATION
% =========================================================================
function local_validate_cfg(cfg)

    if ~isfield(cfg, 'candidates')
        error('cfg.candidates is missing.');
    end

    requiredCandidateFields = { ...
        'P_inv_kW_vec', ...
        'BESS_PV_vec', ...
        'bessDuration_h'};

    for i = 1:numel(requiredCandidateFields)

        f = requiredCandidateFields{i};

        if ~isfield(cfg.candidates, f)
            error('cfg.candidates.%s is missing.', f);
        end
    end

    if ~isfield(cfg.candidates, 'DCAC_ratio_vec') 

        error('cfg.candidates.DCAC_ratio_vec  szukseges.');
    end

    if isempty(cfg.candidates.P_inv_kW_vec)
        error('cfg.candidates.P_inv_kW_vec is empty.');
    end

    if isempty(local_get_dcac_ratio_vec(cfg))
        error('DCAC ratio vector is empty.');
    end

    if isempty(cfg.candidates.BESS_PV_vec)
        error('cfg.candidates.BESS_PV_vec is empty.');
    end

    if any(cfg.candidates.P_inv_kW_vec <= 0)
        error('All cfg.candidates.P_inv_kW_vec values must be positive.');
    end

    if any(local_get_dcac_ratio_vec(cfg) <= 0)
        error('All DCAC ratio values must be positive.');
    end

    if any(cfg.candidates.BESS_PV_vec < 0)
        error('All cfg.candidates.BESS_PV_vec values must be non-negative.');
    end

    if cfg.candidates.bessDuration_h <= 0
        error('cfg.candidates.bessDuration_h must be positive.');
    end

    if ~isfield(cfg, 'output')
        error('cfg.output is missing.');
    end

    if ~isfield(cfg.output, 'scalarMetrics')
        error('cfg.output.scalarMetrics is missing.');
    end

    if ~isfield(cfg.output, 'profileMetrics')
        error('cfg.output.profileMetrics is missing.');
    end

    local_validate_metric_definitions(cfg.output.scalarMetrics, 'scalarMetrics');
    local_validate_metric_definitions(cfg.output.profileMetrics, 'profileMetrics');
end


function local_validate_metric_definitions(metrics, metricGroupName)

    requiredFields = {'name', 'source', 'mode'};

    for i = 1:numel(requiredFields)

        if ~isfield(metrics, requiredFields{i})
            error('cfg.output.%s missing field: %s', metricGroupName, requiredFields{i});
        end
    end

    for i = 1:numel(metrics)

        if strlength(string(metrics(i).name)) == 0
            error('Empty metric name in cfg.output.%s at index %d.', metricGroupName, i);
        end

        if strlength(string(metrics(i).source)) == 0
            error('Empty metric source in cfg.output.%s at index %d.', metricGroupName, i);
        end

        if strlength(string(metrics(i).mode)) == 0
            error('Empty metric mode in cfg.output.%s at index %d.', metricGroupName, i);
        end
    end
end


% =========================================================================
% CANDIDATE VECTOR HELPERS
% =========================================================================
function DCAC_ratio_vec = local_get_dcac_ratio_vec(cfg)

    if isfield(cfg.candidates, 'DCAC_ratio_vec')

        DCAC_ratio_vec = cfg.candidates.DCAC_ratio_vec(:);

    elseif isfield(cfg.candidates, 'PV_scale_vec')

        % Kompatibilitasi alias:
        % A regi PV_scale_vec itt valojaban DC/AC aranykent mukodik.
        DCAC_ratio_vec = cfg.candidates.PV_scale_vec(:);

    else

        DCAC_ratio_vec = [];
    end
end


% =========================================================================
% DESIGN FIELD HANDLING
% =========================================================================
function designFields = local_get_candidate_design_fields(cfg)

    if isfield(cfg.candidates, 'designFields') && ...
       ~isempty(cfg.candidates.designFields)

        designFields = string(cfg.candidates.designFields(:)).';

    else

        designFields = [ ...
            "P_inv_kW", ...
            "DCAC_ratio", ...
            "BESS_PV_ratio", ...
            "P_PV_kW", ...
            "PV_kW", ...
            "E_BESS_kWh", ...
            "P_BESS_kW", ...
            "bessDuration_h", ...
            "internalNetworkLossFraction"];
    end
end


function candidateTable = local_write_design_to_candidate_table(candidateTable, idx, design, designFields)

    for i = 1:numel(designFields)

        fieldName = char(designFields(i));

        if ~ismember(fieldName, candidateTable.Properties.VariableNames)
            candidateTable.(fieldName) = NaN(height(candidateTable), 1);
        end

        if ~isfield(design, fieldName)
            error('A design struktura nem tartalmazza a kovetkezo mezot: %s', fieldName);
        end

        candidateTable.(fieldName)(idx) = design.(fieldName);
    end
end


% =========================================================================
% CANDIDATE TABLE
% =========================================================================
function T = local_create_candidate_table(n, cfg, designFields)

    T = table();

    % ---------------------------------------------------------------------
    % Candidate metadata
    % ---------------------------------------------------------------------
    T.candidateIndex = NaN(n, 1);
    T.candidateID = strings(n, 1);

    % ---------------------------------------------------------------------
    % Design mezok kozponti listabol
    % ---------------------------------------------------------------------
    for i = 1:numel(designFields)

        fieldName = char(designFields(i));

        if ~ismember(fieldName, T.Properties.VariableNames)
            T.(fieldName) = NaN(n, 1);
        end
    end

    % ---------------------------------------------------------------------
    % Simulation status
    % ---------------------------------------------------------------------
    T.wasSimulated = false(n, 1);
    T.hasError = false(n, 1);
    T.errorMessage = strings(n, 1);
    T.runtime_s = NaN(n, 1);

    T.finalSoH = NaN(n, 1);
    T.finalSoC = NaN(n, 1);

    % ---------------------------------------------------------------------
    % Dynamic scalar metrics from cfg.output.scalarMetrics
    % ---------------------------------------------------------------------
    for i = 1:numel(cfg.output.scalarMetrics)

        metricName = char(cfg.output.scalarMetrics(i).name);

        if ~ismember(metricName, T.Properties.VariableNames)
            T.(metricName) = NaN(n, 1);
        end
    end

    % ---------------------------------------------------------------------
    % Derived self-consumption / operation metrics
    % Ezeket a finalize_candidate_result tolti.
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

    for i = 1:numel(derivedColumns)

        col = derivedColumns{i};

        if ~ismember(col, T.Properties.VariableNames)
            T.(col) = NaN(n, 1);
        end
    end

    % ---------------------------------------------------------------------
    % Cost metrics
    % Ezeket is a finalize tolti.
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

    for i = 1:numel(costColumns)

        col = costColumns{i};

        if ~ismember(col, T.Properties.VariableNames)
            T.(col) = NaN(n, 1);
        end
    end
end


% =========================================================================
% BASE PROFILES
% =========================================================================
function baseProfiles = local_build_base_profiles(data)

    nDays = numel(data.days);
    nT = numel(data.days(1).P_load_kW);
    dt_h = data.days(1).dt_h;

    loadMat = zeros(nDays, nT);
    pvMat = zeros(nDays, nT);

    for d = 1:nDays
        loadMat(d, :) = data.days(d).P_load_kW(:).';
        pvMat(d, :) = data.days(d).P_pv_base_kW(:).';
    end

    baseProfiles = struct();

    baseProfiles.time_h = (0:nT-1) * dt_h;

    baseProfiles.loadMeanProfile_kW = mean(loadMat, 1);
    baseProfiles.loadPeakProfile_kW = max(loadMat, [], 1);
    baseProfiles.loadMinProfile_kW = min(loadMat, [], 1);

    baseProfiles.pvBaseMeanProfile_kW = mean(pvMat, 1);
    baseProfiles.pvBasePeakProfile_kW = max(pvMat, [], 1);
    baseProfiles.pvBaseMinProfile_kW = min(pvMat, [], 1);

    baseProfiles.totalLoadEnergy_kWh = sum(loadMat, 'all') * dt_h;
    baseProfiles.totalPvBaseEnergy_kWh = sum(pvMat, 'all') * dt_h;

    baseProfiles.dailyLoadEnergy_kWh = sum(loadMat, 2) * dt_h;
    baseProfiles.dailyPvBaseEnergy_kWh = sum(pvMat, 2) * dt_h;

    baseProfiles.maxDailyLoadPeak_kW = max(max(loadMat, [], 2));
    baseProfiles.meanDailyLoadPeak_kW = mean(max(loadMat, [], 2));
end


% =========================================================================
% CANDIDATE PROFILES
% =========================================================================
function profiles = local_init_candidate_profiles(nCandidates, nT, cfg)

    profiles = struct();

    for i = 1:numel(cfg.output.profileMetrics)

        metricName = char(cfg.output.profileMetrics(i).name);

        if ~isfield(profiles, metricName)
            profiles.(metricName) = NaN(nCandidates, nT);
        end
    end
end


% =========================================================================
% CANDIDATE COMPONENT SIZES
% =========================================================================
function design = set_candidate_component_sizes(candidateBase, cfg)
% SET_CANDIDATE_COMPONENT_SIZES
%
% Egy candidate teljes meretezeset allitja be.
%
% Fo candidate bemenetek:
%   candidateBase.P_inv_kW
%   candidateBase.DCAC_ratio
%   candidateBase.BESS_PV_ratio
%
% Szarmaztatott meretek:
%   P_PV_kW     = P_inv_kW * DCAC_ratio
%   E_BESS_kWh = BESS_PV_ratio * P_PV_kW
%   P_BESS_kW  = E_BESS_kWh / bessDuration_h
%
% Diesel generator nincs.

    design = struct();

    % ---------------------------------------------------------------------
    % Fo candidate dimenziok
    % ---------------------------------------------------------------------
    design.P_inv_kW = candidateBase.P_inv_kW;
    design.DCAC_ratio = candidateBase.DCAC_ratio;
    design.BESS_PV_ratio = candidateBase.BESS_PV_ratio;

    % ---------------------------------------------------------------------
    % Szarmaztatott PV es BESS meretek
    % ---------------------------------------------------------------------
    design.P_PV_kW = candidateBase.P_PV_kW;

    % Kompatibilitasi alias.
    design.PV_kW = candidateBase.P_PV_kW;

    design.E_BESS_kWh = candidateBase.E_BESS_kWh;
    design.P_BESS_kW = candidateBase.P_BESS_kW;

    design.bessDuration_h = cfg.candidates.bessDuration_h;

    % ---------------------------------------------------------------------
    % Internal network / transformer loss
    % ---------------------------------------------------------------------
    if isfield(cfg, 'internalNetwork') && isfield(cfg.internalNetwork, 'lossFraction')
        design.internalNetworkLossFraction = cfg.internalNetwork.lossFraction;
    else
        design.internalNetworkLossFraction = 0;
    end
end