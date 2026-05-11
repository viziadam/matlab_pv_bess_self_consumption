function [step, stateEnd] = dccoupled_energy_strategy_vector(P_pv_dc_kW, P_load_ac_kW, design, stateStart, dt_h, T_amb_C, cfg)
% DCCOUPLED_ENERGY_STRATEGY_VECTOR
%
% DC-csatolt PV+BESS energiaaramlasi strategia grid-connected
% self-consumption vizsgalathoz, visszataplalas nelkul.
%
% Topologia:
%
%   PV DC -----> DC sin -----> kozos inverter -----> AC load
%                   |
%                 DC/DC
%                   |
%                  BESS
%
% Vezerles:
%   1) Az AC fogyasztasi igenybol kiszamoljuk az inverter DC oldali
%      szukseges bemeneti teljesitmenyet.
%
%   2) A PV ezt a DC igenyt fedezi, amennyire tudja.
%
%   3) Ha PV < DC inverterigeny:
%        a kulonbseget a BESS kisutese probalja fedezni.
%
%   4) Ha PV > DC inverterigeny:
%        a tobblet a BESS toltesere megy.
%
%   5) Visszataplalas nincs:
%        a BESS altal fel nem vett PV tobblet curtailment.
%
%   6) Az inverter veszteseg csak egyszer szamolodik,
%      az osszesitett DC inverterbemenet alapjan.
%
% Fontos:
%   DC-csatolt rendszerben a PV es a BESS kozos inverteren osztozik.
%   Ezert az inverter_model csak egyszer fut a tenyleges osszes DC
%   inverterbemenetre. A PV/BESS oldali inverterveszteseg-bontas csak
%   utolagos aranyos konyveles.

    % ---------------------------------------------------------------------
    % 1) Input formatting
    % ---------------------------------------------------------------------
    P_pv_dc_kW = P_pv_dc_kW(:);
    P_load_ac_kW = P_load_ac_kW(:);

    N = min(numel(P_pv_dc_kW), numel(P_load_ac_kW));

    P_pv_dc_kW = max(0, P_pv_dc_kW(1:N));
    P_load_ac_kW = max(0, P_load_ac_kW(1:N));

    if nargin < 6 || isempty(T_amb_C)
        T_vec = 25 * ones(1, N);
    else
        T_vec = T_amb_C(:).';
        T_vec = T_vec(1:min(numel(T_vec), N));

        if numel(T_vec) < N
            T_vec(end+1:N) = T_vec(end);
        end
    end

    if nargin < 7
        cfg = struct();
    end

    if ~isfield(stateStart, 'bess_state') || isempty(stateStart.bess_state)
        error('dccoupled_energy_strategy_vector: stateStart.bess_state is missing.');
    end

    bess_state = stateStart.bess_state;

    P_inv_nom_kW = design.P_inv_kW;
    P_bess_nom_kW = design.P_BESS_kW;

    % Ebben az alkalmazasban nincs visszataplalas.
    allowExport = false; %#ok<NASGU>

    % ---------------------------------------------------------------------
    % 2) AC load required -> DC inverter input required
    % ---------------------------------------------------------------------
    % Az inverter a fogyasztasbol legfeljebb a nevleges teljesitmenyeig
    % tud fedezni. A tobbit a haloztbol importaljuk.
    P_ac_required_from_inv_kW = min(P_load_ac_kW, P_inv_nom_kW);

    inv_req = inverter_model( ...
        P_ac_required_from_inv_kW, ...
        P_inv_nom_kW, ...
        dt_h, ...
        'ac_required');

    P_dc_required_at_inv_kW = inv_req.P_input_required_kW(:);

    % ---------------------------------------------------------------------
    % 3) PV directly to common DC inverter input
    % ---------------------------------------------------------------------
    P_pv_dc_to_inv_kW = min(P_pv_dc_kW, P_dc_required_at_inv_kW);

    P_dc_deficit_kW = max(P_dc_required_at_inv_kW - P_pv_dc_to_inv_kW, 0);
    P_pv_surplus_kW = max(P_pv_dc_kW - P_pv_dc_to_inv_kW, 0);

    % ---------------------------------------------------------------------
    % 4) DC/DC high-side BESS request
    % ---------------------------------------------------------------------
    % Jelkonvencio:
    %   pozitiv  -> BESS -> DC sin, kisutes
    %   negativ  -> DC sin -> BESS, toltes
    P_bess_high_req_kW = zeros(N, 1);

    maskCharge = P_pv_surplus_kW > 1e-9;
    maskDischg = P_dc_deficit_kW > 1e-9 & ~maskCharge;

    % PV tobblet -> BESS toltes
    P_bess_high_req_kW(maskCharge) = -min( ...
        P_pv_surplus_kW(maskCharge), ...
        P_bess_nom_kW);

    % PV hiany -> BESS kisutes
    P_bess_high_req_kW(maskDischg) = min( ...
        P_dc_deficit_kW(maskDischg), ...
        P_bess_nom_kW);

    % ---------------------------------------------------------------------
    % 5) DC/DC request conversion: DC bus side -> BESS pack side
    % ---------------------------------------------------------------------
    dcdc_req = dcdc_converter_model( ...
        P_bess_high_req_kW(:).' * 1000, ...
        P_bess_nom_kW * 1000, ...
        dt_h, ...
        'dc_to_pack');

    P_pack_req_W = dcdc_req.P_output_W(:).';

    % ---------------------------------------------------------------------
    % 6) BESS pack model
    % ---------------------------------------------------------------------
    pack_params = struct();
    pack_params.target_energy_kWh = design.E_BESS_kWh;
    pack_params.max_power_W = P_bess_nom_kW * 1000;
    pack_params.T_vec = T_vec;

    [pack_out, bess_state] = bess_pack_model( ...
        P_pack_req_W, ...
        'run', ...
        pack_params, ...
        dt_h, ...
        bess_state);

    % Pack actual power:
    %   positive = discharge from pack
    %   negative = charge into pack
    P_pack_actual_W = ...
        (pack_out.E_discharged(:) - pack_out.E_stored(:)) / max(dt_h, eps);

    % ---------------------------------------------------------------------
    % 7) DC/DC actual conversion: BESS pack side -> DC bus side
    % ---------------------------------------------------------------------
    dcdc_actual = dcdc_converter_model( ...
        P_pack_actual_W(:).' , ...
        P_bess_nom_kW * 1000, ...
        dt_h, ...
        'pack_to_dc');

    P_bess_high_actual_kW = dcdc_actual.P_output_W(:) / 1000;

    % Aktualis DC oldali BESS aramlasok
    P_pv_to_bess_kW = min( ...
        max(-P_bess_high_actual_kW, 0), ...
        P_pv_surplus_kW);

    P_bess_dc_to_inv_kW = min( ...
        max(P_bess_high_actual_kW, 0), ...
        P_dc_deficit_kW);

    % ---------------------------------------------------------------------
    % 8) Common inverter input
    % ---------------------------------------------------------------------
    P_inv_dc_input_total_kW = ...
        P_pv_dc_to_inv_kW + ...
        P_bess_dc_to_inv_kW;

    inv_total = inverter_model( ...
        P_inv_dc_input_total_kW, ...
        P_inv_nom_kW, ...
        dt_h, ...
        'dc_to_ac');

    P_inv_ac_output_kW = min(inv_total.P_forwarded_kW(:), P_load_ac_kW);

    % ---------------------------------------------------------------------
    % 9) PV/BESS useful AC output allocation
    % ---------------------------------------------------------------------
    totalInvInput_kW = P_inv_dc_input_total_kW;

    pvShare = zeros(N, 1);
    bessShare = zeros(N, 1);

    activeInv = totalInvInput_kW > 1e-9;

    pvShare(activeInv) = ...
        P_pv_dc_to_inv_kW(activeInv) ./ totalInvInput_kW(activeInv);

    bessShare(activeInv) = ...
        P_bess_dc_to_inv_kW(activeInv) ./ totalInvInput_kW(activeInv);

    P_pv_to_load_kW = P_inv_ac_output_kW .* pvShare;
    P_bess_to_load_kW = P_inv_ac_output_kW .* bessShare;

    % ---------------------------------------------------------------------
    % 10) Grid import/export
    % ---------------------------------------------------------------------
    P_grid_import_kW = max( ...
        P_load_ac_kW - P_pv_to_load_kW - P_bess_to_load_kW, ...
        0);

    % Nincs visszataplalas.
    P_grid_export_kW = zeros(N, 1);

    % ---------------------------------------------------------------------
    % 11) Inverter losses and clipping
    % ---------------------------------------------------------------------
    P_inv_conversion_loss_kW = inv_total.P_loss_kW(:);
    P_inv_power_clipped_kW = inv_total.P_clipped_kW(:);

    P_inv_loss_kW = P_inv_conversion_loss_kW;

    % A kozos inverterveszteseg csak egyszer van kiszamolva.
    % A PV/BESS bontas csak aranyos konyveles.
    P_inv_pv_conversion_loss_kW = P_inv_conversion_loss_kW .* pvShare;
    P_inv_bess_conversion_loss_kW = P_inv_conversion_loss_kW .* bessShare;

    P_inv_pv_clipped_kW = P_inv_power_clipped_kW .* pvShare;
    P_inv_bess_clipped_kW = P_inv_power_clipped_kW .* bessShare;

    % ---------------------------------------------------------------------
    % 12) Curtailment
    % ---------------------------------------------------------------------
    % PV maradek, amit nem hasznaltunk kozvetlenul es nem ment BESS-be.
    P_pv_curtailed_direct_kW = max( ...
        P_pv_dc_kW - P_pv_dc_to_inv_kW - P_pv_to_bess_kW, ...
        0);

    % A PV share szerinti inverter clipping is PV oldali nem hasznosult energia.
    P_curtailment_kW = ...
        P_pv_curtailed_direct_kW + ...
        P_inv_pv_clipped_kW;

    % ---------------------------------------------------------------------
    % 13) DC/DC losses
    % ---------------------------------------------------------------------
    P_dcdc_conversion_loss_kW = dcdc_actual.P_loss_W(:) / 1000;
    P_dcdc_power_clipped_kW = dcdc_req.P_clipped_W(:) / 1000;

    P_dcdc_loss_kW = P_dcdc_conversion_loss_kW;

    % ---------------------------------------------------------------------
    % 14) BESS internal losses
    % ---------------------------------------------------------------------
    P_bess_cell_loss_kW = pack_out.E_loss_joule(:) / 1000 / max(dt_h, eps);

    P_bess_soc_full_loss_kW = pack_out.E_loss_sat(:) / 1000 / max(dt_h, eps);

    P_bess_soc_empty_loss_kW = pack_out.E_loss_empty(:) / 1000 / max(dt_h, eps);

    P_bess_total_internal_loss_kW = ...
        P_bess_cell_loss_kW + ...
        P_bess_soc_full_loss_kW + ...
        P_bess_soc_empty_loss_kW;

    % ---------------------------------------------------------------------
    % 15) Output step
    % ---------------------------------------------------------------------
    step = struct();

    step.P_pv_available_kW = P_pv_dc_kW;
    step.P_load_ac_kW = P_load_ac_kW;

    step.P_pv_to_load_kW = P_pv_to_load_kW;
    step.P_pv_to_bess_kW = P_pv_to_bess_kW;
    step.P_bess_to_load_kW = P_bess_to_load_kW;

    step.P_grid_import_kW = P_grid_import_kW;
    step.P_grid_export_kW = P_grid_export_kW;

    step.P_curtailment_kW = P_curtailment_kW;

    step.P_inv_loss_kW = P_inv_loss_kW;
    step.P_dcdc_loss_kW = P_dcdc_loss_kW;

    % Debug / detailed power flow fields
    step.P_ac_required_from_inv_kW = P_ac_required_from_inv_kW;
    step.P_dc_required_at_inv_kW = P_dc_required_at_inv_kW;

    step.P_pv_dc_to_inv_kW = P_pv_dc_to_inv_kW;
    step.P_dc_deficit_kW = P_dc_deficit_kW;
    step.P_pv_surplus_kW = P_pv_surplus_kW;

    step.P_bess_high_req_kW = P_bess_high_req_kW;
    step.P_bess_high_actual_kW = P_bess_high_actual_kW;
    step.P_pack_req_kW = P_pack_req_W(:) / 1000;
    step.P_pack_actual_kW = P_pack_actual_W(:) / 1000;

    step.P_inv_dc_input_total_kW = P_inv_dc_input_total_kW;
    step.P_inv_ac_output_kW = P_inv_ac_output_kW;

    % Inverter losses
    step.P_inv_conversion_loss_kW = P_inv_conversion_loss_kW;
    step.P_inv_power_clipped_kW = P_inv_power_clipped_kW;

    step.P_inv_pv_conversion_loss_kW = P_inv_pv_conversion_loss_kW;
    step.P_inv_bess_conversion_loss_kW = P_inv_bess_conversion_loss_kW;

    step.P_inv_pv_clipped_kW = P_inv_pv_clipped_kW;
    step.P_inv_bess_clipped_kW = P_inv_bess_clipped_kW;

    % DC/DC losses
    step.P_dcdc_conversion_loss_kW = P_dcdc_conversion_loss_kW;
    step.P_dcdc_power_clipped_kW = P_dcdc_power_clipped_kW;

    % BESS internal losses
    step.P_bess_cell_loss_kW = P_bess_cell_loss_kW;
    step.P_bess_soc_full_loss_kW = P_bess_soc_full_loss_kW;
    step.P_bess_soc_empty_loss_kW = P_bess_soc_empty_loss_kW;
    step.P_bess_total_internal_loss_kW = P_bess_total_internal_loss_kW;

    % BESS state
    step.SoC = pack_out.SOC(:);

    if isfield(pack_out, 'SOH')
        step.SOH = pack_out.SOH(:);
    end

    % Energy fields
    step.E_pv_available_kWh = step.P_pv_available_kW * dt_h;
    step.E_pv_to_load_kWh = step.P_pv_to_load_kW * dt_h;
    step.E_pv_to_bess_kWh = step.P_pv_to_bess_kW * dt_h;
    step.E_bess_to_load_kWh = step.P_bess_to_load_kW * dt_h;
    step.E_grid_import_kWh = step.P_grid_import_kW * dt_h;
    step.E_grid_export_kWh = step.P_grid_export_kW * dt_h;
    step.E_curtailment_kWh = step.P_curtailment_kW * dt_h;

    step.E_inv_conversion_loss_kWh = step.P_inv_conversion_loss_kW * dt_h;
    step.E_dcdc_conversion_loss_kWh = step.P_dcdc_conversion_loss_kW * dt_h;
    step.E_bess_total_internal_loss_kWh = step.P_bess_total_internal_loss_kW * dt_h;

    % ---------------------------------------------------------------------
    % 16) State update
    % ---------------------------------------------------------------------
    stateEnd = stateStart;
    stateEnd.bess_state = bess_state;
    stateEnd.SoC = pack_out.SOC(end);

    if isfield(pack_out, 'SOH')
        stateEnd.SOH = pack_out.SOH(end);
    end
end