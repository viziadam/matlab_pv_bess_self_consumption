function dayResult = simulate_day_vectorized(dayInput, stateStart, design, cfg)
% SIMULATE_DAY_VECTORIZED
%
% Egy nap grid-connected PV+BESS self-consumption szimulacioja.
%
% Topologia a cfg alapjan:
%   cfg.system.bessCoupling = "dc" -> DC-csatolt PV+BESS
%   cfg.system.bessCoupling = "ac" -> AC-csatolt PV+BESS
%
% Ebben az alkalmazasban nincs visszataplalas:
%   P_grid_export_kW = 0
%
% Nincs diesel generator.
%
% Bemenet:
%   dayInput.P_load_kW
%   dayInput.P_pv_base_kW
%   dayInput.dt_h
%
%   stateStart.bess_state
%
%   design.P_PV_kW
%   design.E_BESS_kWh
%   design.P_BESS_kW
%   design.P_inv_kW
%
% Kimenet:
%   dayResult.dayVectors
%   dayResult.stateEnd

    % ---------------------------------------------------------------------
    % 1) Inputs
    % ---------------------------------------------------------------------
    P_load_kW = dayInput.P_load_kW(:);
    P_pv_base_kW = dayInput.P_pv_base_kW(:);
    dt_h = dayInput.dt_h;

    N = min(numel(P_load_kW), numel(P_pv_base_kW));

    P_load_kW = max(0, P_load_kW(1:N));
    P_pv_base_kW = max(0, P_pv_base_kW(1:N));

    % 1 kWp referencia PV -> aktualis PV meret
    P_pv_dc_kW = P_pv_base_kW * design.P_PV_kW;

    % Homersekletvektor
    if isfield(dayInput, 'T_amb_C')
        T_amb_C = dayInput.T_amb_C(:);
        T_amb_C = T_amb_C(1:min(numel(T_amb_C), N));

        if numel(T_amb_C) < N
            T_amb_C(end+1:N) = T_amb_C(end);
        end
    else
        T_amb_C = 25 * ones(N, 1);
    end
    T_amb_C = 25 * ones(N, 1);
    
    % ---------------------------------------------------------------------
    % 2) Ebben az alkalmazasban nincs visszataplalas
    % ---------------------------------------------------------------------
    if ~isfield(cfg, 'grid')
        cfg.grid = struct();
    end

    cfg.grid.allowExport = false;

    % ---------------------------------------------------------------------
    % 3) Topologia kivalasztasa
    % ---------------------------------------------------------------------
    coupling = local_get_bess_coupling(cfg);

    switch coupling

        case "dc"
            [step, stateAfterBess] = dccoupled_energy_strategy_vector( ...
                P_pv_dc_kW, ...
                P_load_kW, ...
                design, ...
                stateStart, ...
                dt_h, ...
                T_amb_C, ...
                cfg);

        case "ac"
            [step, stateAfterBess] = accoupled_energy_strategy_vector( ...
                P_pv_dc_kW, ...
                P_load_kW, ...
                design, ...
                stateStart, ...
                dt_h, ...
                T_amb_C, ...
                cfg);

        otherwise
            error('Ismeretlen BESS coupling: %s. Hasznalhato: "dc" vagy "ac".', coupling);
    end

    % ---------------------------------------------------------------------
    % 4) Grid-connected final balance
    % ---------------------------------------------------------------------
    P_grid_import_kW = step.P_grid_import_kW;

    % Ebben az alkalmazasban nincs export.
    P_grid_export_kW = zeros(N, 1);

    P_served_kW = ...
        step.P_pv_to_load_kW + ...
        step.P_bess_to_load_kW + ...
        P_grid_import_kW;

    P_served_kW = min(P_served_kW, P_load_kW);

    % Grid-connected esetben normal esetben nincs ellatatlan energia.
    P_unserved_kW = max(P_load_kW - P_served_kW, 0);

    % Egyelore nincs kulon belso AC halozati/transzformator modell.
    % A mezot megtartjuk a metrikak miatt.
    P_internal_network_loss_kW = zeros(N, 1);

    % ---------------------------------------------------------------------
    % 5) dayVectors for generic metric update
    % ---------------------------------------------------------------------
    dayVectors = struct();

    dayVectors.P_load_kW = P_load_kW;
    dayVectors.P_pv_available_kW = step.P_pv_available_kW;

    dayVectors.P_served_kW = P_served_kW;
    dayVectors.P_unserved_kW = P_unserved_kW;

    dayVectors.P_pv_to_load_kW = step.P_pv_to_load_kW;
    dayVectors.P_pv_to_bess_kW = step.P_pv_to_bess_kW;
    dayVectors.P_bess_to_load_kW = step.P_bess_to_load_kW;

    dayVectors.P_grid_import_kW = P_grid_import_kW;
    dayVectors.P_grid_export_kW = P_grid_export_kW;

    dayVectors.P_curtailment_kW = step.P_curtailment_kW;

    dayVectors.P_inv_loss_kW = step.P_inv_loss_kW;
    dayVectors.P_dcdc_loss_kW = step.P_dcdc_loss_kW;
    dayVectors.P_internal_network_loss_kW = P_internal_network_loss_kW;

    dayVectors.SoC = step.SoC;

    % ---------------------------------------------------------------------
    % Detailed BESS losses
    % ---------------------------------------------------------------------
    dayVectors.P_bess_cell_loss_kW = step.P_bess_cell_loss_kW;
    dayVectors.P_bess_soc_full_loss_kW = step.P_bess_soc_full_loss_kW;
    dayVectors.P_bess_soc_empty_loss_kW = step.P_bess_soc_empty_loss_kW;
    dayVectors.P_bess_total_internal_loss_kW = step.P_bess_total_internal_loss_kW;

    % ---------------------------------------------------------------------
    % Detailed DC/DC losses
    % AC-csatolt esetben ezek nullak.
    % ---------------------------------------------------------------------
    dayVectors.P_dcdc_conversion_loss_kW = step.P_dcdc_conversion_loss_kW;
    dayVectors.P_dcdc_power_clipped_kW = step.P_dcdc_power_clipped_kW;

    % ---------------------------------------------------------------------
    % Detailed inverter / PCS losses
    % ---------------------------------------------------------------------
    dayVectors.P_inv_conversion_loss_kW = step.P_inv_conversion_loss_kW;
    dayVectors.P_inv_power_clipped_kW = step.P_inv_power_clipped_kW;

    dayVectors.P_inv_pv_conversion_loss_kW = step.P_inv_pv_conversion_loss_kW;
    dayVectors.P_inv_bess_conversion_loss_kW = step.P_inv_bess_conversion_loss_kW;

    dayVectors.P_inv_pv_clipped_kW = step.P_inv_pv_clipped_kW;
    dayVectors.P_inv_bess_clipped_kW = step.P_inv_bess_clipped_kW;

    % ---------------------------------------------------------------------
    % Optional debug fields
    % ---------------------------------------------------------------------
    if isfield(step, 'P_bess_high_req_kW')
        dayVectors.P_bess_high_req_kW = step.P_bess_high_req_kW;
    end

    if isfield(step, 'P_bess_high_actual_kW')
        dayVectors.P_bess_high_actual_kW = step.P_bess_high_actual_kW;
    end

    if isfield(step, 'P_pack_req_kW')
        dayVectors.P_pack_req_kW = step.P_pack_req_kW;
    end

    if isfield(step, 'P_pack_actual_kW')
        dayVectors.P_pack_actual_kW = step.P_pack_actual_kW;
    end

    % ---------------------------------------------------------------------
    % 6) Output
    % ---------------------------------------------------------------------
    dayResult = struct();
    dayResult.dayVectors = dayVectors;
    dayResult.stateEnd = stateAfterBess;
    dayResult.coupling = coupling;
end


function coupling = local_get_bess_coupling(cfg)

    coupling = "dc";

    if isfield(cfg, 'system') && isfield(cfg.system, 'bessCoupling')
        coupling = lower(string(cfg.system.bessCoupling));
    elseif isfield(cfg, 'bess') && isfield(cfg.bess, 'coupling')
        coupling = lower(string(cfg.bess.coupling));
    end

    if coupling == "dc-coupled"
        coupling = "dc";
    end

    if coupling == "ac-coupled"
        coupling = "ac";
    end
end