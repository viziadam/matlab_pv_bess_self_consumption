% function DB = simulate_candidates_database(data, DB, cfg)
% % SIMULATE_CANDIDATES_DATABASE
% %
% % Lefuttatja az osszes candidate-et a DB.candidateTable alapjan.
% %
% % Fontos:
% %   A design struktura mezoi nem kezzel vannak felsorolva.
% %   A szukseges mezoket a DB.candidateDesignFields vagy
% %   cfg.candidates.designFields adja meg.
% %
% % Ez elkeruli az olyan hibakat, mint:
% %   Unrecognized table variable name 'P_DG_kW'
% %
% % Mert grid-connected PV+BESS alkalmazasban nincs diesel generator.
% 
%     nCandidates = DB.nCandidates;
%     nDays = DB.nDays;
% 
%     designFields = local_get_candidate_design_fields(DB, cfg);
% 
%     for c = 1:nCandidates
% 
%         candidateID = DB.candidateTable.candidateID(c);
% 
%         fprintf('\nRunning candidate %d / %d: %s\n', c, nCandidates, candidateID);
% 
%         tCandidate = tic;
% 
%         design = table_row_to_design( ...
%             DB.candidateTable(c, :), ...
%             designFields);
% 
%         state = init_bess_state_for_candidate(design, cfg, data.days(1).dt_h);
% 
%         running = init_metrics(DB.nT, cfg);
% 
%         for d = 1:nDays
% 
%             dayInput = local_get_day_input(data, d);
% 
%             dayResult = simulate_day_vectorized( ...
%                 dayInput, ...
%                 state, ...
%                 design, ...
%                 cfg);
% 
%             running = update_metrics( ...
%                 running, ...
%                 dayResult.dayVectors, ...
%                 dayInput.dt_h, ...
%                 cfg);
% 
%             state = dayResult.stateEnd;
%         end
% 
%         runtime_s = toc(tCandidate);
% 
%         DB = finalize_candidate_result( ...
%             DB, ...
%             c, ...
%             running, ...
%             runtime_s, ...
%             cfg);
% 
%         if isfield(cfg, 'sim') && ...
%            isfield(cfg.sim, 'saveAfterEachCandidate') && ...
%            cfg.sim.saveAfterEachCandidate
% 
%             save_candidates_database(DB, cfg);
%         end
%     end
% end
% 
% 
% % =========================================================================
% % DESIGN FIELD HANDLING
% % =========================================================================
% function designFields = local_get_candidate_design_fields(DB, cfg)
% 
%     if isfield(DB, 'candidateDesignFields') && ~isempty(DB.candidateDesignFields)
% 
%         designFields = string(DB.candidateDesignFields(:)).';
% 
%     elseif isfield(cfg, 'candidates') && ...
%            isfield(cfg.candidates, 'designFields') && ...
%            ~isempty(cfg.candidates.designFields)
% 
%         designFields = string(cfg.candidates.designFields(:)).';
% 
%     else
% 
%         designFields = [ ...
%             "P_inv_kW", ...
%             "DCAC_ratio", ...
%             "BESS_PV_ratio", ...
%             "P_PV_kW", ...
%             "PV_kW", ...
%             "E_BESS_kWh", ...
%             "P_BESS_kW", ...
%             "bessDuration_h", ...
%             "internalNetworkLossFraction"];
%     end
% end
% 
% 
% function design = table_row_to_design(row, designFields)
% % TABLE_ROW_TO_DESIGN
% %
% % Egy candidateTable sorbol design strukturat keszit.
% %
% % A mezoket nem kezzel soroljuk fel, hanem designFields alapjan.
% % Ezert nincs P_DG_kW-hoz hasonlo elvaras, ha nincs benne a kozponti
% % designFields listaban.
% 
%     design = struct();
% 
%     tableVars = string(row.Properties.VariableNames);
% 
%     for i = 1:numel(designFields)
% 
%         fieldName = char(designFields(i));
% 
%         if any(tableVars == fieldName)
% 
%             value = row.(fieldName);
% 
%             if istable(value)
%                 value = value{1, 1};
%             end
% 
%             if numel(value) == 1
%                 design.(fieldName) = value;
%             else
%                 design.(fieldName) = value(1);
%             end
% 
%         else
% 
%             error(['A candidateTable nem tartalmazza a szukseges design mezot: %s\n', ...
%                    'Ellenorizd az init_candidate_database_structures() es a cfg.candidates.designFields beallitasait.'], ...
%                    fieldName);
%         end
%     end
% end
% 
% 
% % =========================================================================
% % DAY INPUT
% % =========================================================================
% function dayInput = local_get_day_input(data, dayIdx)
% 
%     dd = data.days(dayIdx);
% 
%     dayInput = struct();
% 
%     if isfield(dd, 'date')
%         dayInput.date = dd.date;
%     else
%         dayInput.date = NaT;
%     end
% 
%     dayInput.dayIndex = dayIdx;
%     dayInput.P_load_kW = dd.P_load_kW(:);
%     dayInput.P_pv_base_kW = dd.P_pv_base_kW(:);
% 
%     if isfield(dd, 'dt_h')
%         dayInput.dt_h = dd.dt_h;
%     else
%         dayInput.dt_h = 24 / numel(dayInput.P_load_kW);
%     end
% 
%     % Homerseklet atadasa, ha a betoltott napi adat tartalmazza.
%     if isfield(dd, 'T_amb_C')
%         dayInput.T_amb_C = dd.T_amb_C(:);
%     end
% end

function DB = simulate_candidates_database(data, DB, cfg)
% SIMULATE_CANDIDATES_DATABASE
%
% Lefuttatja az osszes grid-connected PV+BESS candidate-et.
%
% Fontos:
%   - A design struktura automatikusan a candidateTable soraibol epul.
%   - Nem var P_DG_kW mezot.
%   - A futas vegen elmenti a finalSoH es finalSoC ertekeket.
%   - Ezeket az evaluation.m hasznalja a BESS degradacios koltseghez.

    nCandidates = DB.nCandidates;
    nDays = DB.nDays;

    % ---------------------------------------------------------------------
    % Biztositjuk a finalSoH / finalSoC oszlopokat
    % ---------------------------------------------------------------------
    DB.candidateTable = local_ensure_numeric_column( ...
        DB.candidateTable, 'finalSoH', nCandidates);

    DB.candidateTable = local_ensure_numeric_column( ...
        DB.candidateTable, 'finalSoC', nCandidates);

    for c = 1:nCandidates

        candidateID = DB.candidateTable.candidateID(c);

        fprintf('\nRunning candidate %d / %d: %s\n', ...
            c, nCandidates, candidateID);

        tCandidate = tic;

        try
            % -------------------------------------------------------------
            % Candidate design
            % -------------------------------------------------------------
            design = table_row_to_design(DB.candidateTable(c, :));

            % -------------------------------------------------------------
            % Initial BESS state
            % -------------------------------------------------------------
            state = init_bess_state_for_candidate( ...
                design, cfg, data.days(1).dt_h);

            % -------------------------------------------------------------
            % Metric tarolo inicializalasa
            % -------------------------------------------------------------
            running = init_metrics(DB.nT, cfg);

            % -------------------------------------------------------------
            % Napi szimulacio
            % -------------------------------------------------------------
            for d = 1:nDays

                dayInput = local_get_day_input(data, d);

                dayResult = simulate_day_vectorized( ...
                    dayInput, ...
                    state, ...
                    design, ...
                    cfg);

                running = update_metrics( ...
                    running, ...
                    dayResult.dayVectors, ...
                    dayInput.dt_h, ...
                    cfg);

                state = dayResult.stateEnd;
            end

            runtime_s = toc(tCandidate);

            % -------------------------------------------------------------
            % Alap scalar/profile metrikak finalize-olasa
            % -------------------------------------------------------------
            DB = finalize_candidate_result( ...
                DB, ...
                c, ...
                running, ...
                runtime_s, ...
                cfg);

            % -------------------------------------------------------------
            % Vegso BESS allapot mentese
            % -------------------------------------------------------------
            DB = local_store_final_bess_state(DB, c, state, design);

        catch ME

            runtime_s = toc(tCandidate);

            warning('Candidate %d failed: %s', c, ME.message);

            DB.candidateTable.wasSimulated(c) = false;
            DB.candidateTable.hasError(c) = true;
            DB.candidateTable.errorMessage(c) = string(ME.message);
            DB.candidateTable.runtime_s(c) = runtime_s;
        end

        % -----------------------------------------------------------------
        % Reszmentes
        % -----------------------------------------------------------------
        if isfield(cfg, 'sim') && ...
           isfield(cfg.sim, 'saveAfterEachCandidate') && ...
           cfg.sim.saveAfterEachCandidate

            save_candidates_database(DB, cfg);
        end
    end
end


% =========================================================================
% DESIGN STRUCTURE FROM TABLE ROW
% =========================================================================
function design = table_row_to_design(row)
% TABLE_ROW_TO_DESIGN
%
% Altalanos konverzio:
%   candidateTable egy sora -> design struktura.
%
% Igy nem kell minden topologia valtasnal kezzel atirni,
% hogy milyen oszlopokat varunk.

    design = struct();

    varNames = row.Properties.VariableNames;

    for k = 1:numel(varNames)

        name = varNames{k};
        value = row.(name);

        if istable(value)
            continue;
        end

        if iscell(value)
            value = value{1};
        elseif isstring(value)
            value = value(1);
        elseif isnumeric(value) || islogical(value)
            value = value(1);
        end

        design.(name) = value;
    end

    % ---------------------------------------------------------------------
    % Kompatibilitasi aliasok
    % ---------------------------------------------------------------------
    if ~isfield(design, 'P_PV_kW') && isfield(design, 'PV_kW')
        design.P_PV_kW = design.PV_kW;
    end

    if ~isfield(design, 'PV_kW') && isfield(design, 'P_PV_kW')
        design.PV_kW = design.P_PV_kW;
    end

    requiredFields = {'P_PV_kW', 'E_BESS_kWh', 'P_BESS_kW', 'P_inv_kW'};

    for k = 1:numel(requiredFields)
        f = requiredFields{k};

        if ~isfield(design, f)
            error('A design struktura hianyzo mezoje: %s', f);
        end
    end
end


% =========================================================================
% DAY INPUT
% =========================================================================
function dayInput = local_get_day_input(data, dayIdx)

    dd = data.days(dayIdx);

    dayInput = struct();

    if isfield(dd, 'date')
        dayInput.date = dd.date;
    else
        dayInput.date = NaT;
    end

    dayInput.dayIndex = dayIdx;
    dayInput.P_load_kW = dd.P_load_kW(:);
    dayInput.P_pv_base_kW = dd.P_pv_base_kW(:);

    if isfield(dd, 'T_amb_C')
        dayInput.T_amb_C = dd.T_amb_C(:);
    end

    if isfield(dd, 'dt_h')
        dayInput.dt_h = dd.dt_h;
    else
        dayInput.dt_h = 24 / numel(dayInput.P_load_kW);
    end
end


% =========================================================================
% FINAL BESS STATE STORAGE
% =========================================================================
function DB = local_store_final_bess_state(DB, rowIdx, state, design)

    % Ha nincs BESS, akkor SoH = 1, SoC = NaN.
    if isfield(design, 'E_BESS_kWh') && design.E_BESS_kWh <= 0
        DB.candidateTable.finalSoH(rowIdx) = 1;
        DB.candidateTable.finalSoC(rowIdx) = NaN;
        return;
    end

    finalSoH = NaN;
    finalSoC = NaN;

    % ---------------------------------------------------------------------
    % Kozvetlen state mezok
    % ---------------------------------------------------------------------
    if isfield(state, 'SOH')
        finalSoH = state.SOH;
    end

    if isfield(state, 'SoH')
        finalSoH = state.SoH;
    end

    if isfield(state, 'SoC')
        finalSoC = state.SoC;
    end

    if isfield(state, 'SOC')
        finalSoC = state.SOC;
    end

    % ---------------------------------------------------------------------
    % BESS pack belso allapotbol
    % ---------------------------------------------------------------------
    if isfield(state, 'bess_state') && isstruct(state.bess_state)

        bs = state.bess_state;

        if isfield(bs, 'cell_state') && isstruct(bs.cell_state)

            cs = bs.cell_state;

            if isfield(cs, 'SOC')
                finalSoC = cs.SOC;
            end

            if isfield(cs, 'Deg') && isstruct(cs.Deg) && isfield(cs.Deg, 'SOH')
                finalSoH = cs.Deg.SOH;
            end
        end
    end

    % ---------------------------------------------------------------------
    % Fallback
    % ---------------------------------------------------------------------
    if isempty(finalSoH) || isnan(finalSoH)
        finalSoH = 1;
        warning('Nem sikerult finalSoH-t kinyerni a state strukturabol a candidate %d eseteben. finalSoH = 1 lesz.', rowIdx);
    end

    DB.candidateTable.finalSoH(rowIdx) = min(max(finalSoH, 0), 1);

    if isempty(finalSoC) || isnan(finalSoC)
        DB.candidateTable.finalSoC(rowIdx) = NaN;
    else
        DB.candidateTable.finalSoC(rowIdx) = min(max(finalSoC, 0), 1);
    end
end


% =========================================================================
% TABLE COLUMN HELPER
% =========================================================================
function T = local_ensure_numeric_column(T, colName, nRows)

    if ~ismember(colName, T.Properties.VariableNames)
        T.(colName) = NaN(nRows, 1);
    end
end

