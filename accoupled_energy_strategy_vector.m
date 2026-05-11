function [step, stateEnd] = accoupled_energy_strategy_vector(P_pv_dc_kW, P_load_ac_kW, design, stateStart, dt_h, T_amb_C, cfg)
% ACCOUPLED_ENERGY_STRATEGY_VECTOR
%
% AC-csatolt PV+BESS energiaaramlasi strategia.
%
% Topologia:
%
%   PV DC -> PV inverter -> AC bus -> load / grid / BESS PCS
%
%   BESS pack <-> BESS PCS <-> AC bus
%
% Egyszeru self-consumption vezerles:
%   1) PV eloszor a fogyasztast latja el.
%   2) PV AC tobblet tolti a BESS-t AC-csatolt PCS-en keresztul.
%   3) Ha PV nem eleg, BESS kisut AC oldalon a fogyasztas fele.
%   4) Maradek hiany: grid import.
%   5) Maradek PV tobblet: grid export, ha cfg.grid.allowExport = true.
%
% Bemenet:
%   P_pv_dc_kW
%   P_load_ac_kW
%   design.P_inv_kW
%   design.P_BESS_kW
%   design.E_BESS_kWh
%   stateStart.bess_state
%   dt_h
%   T_amb_C
%   cfg
%
% Kimenet:
%   step
%   stateEnd

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
        error('accoupled_energy_strategy_vector: stateStart.bess_state is missing.');
    end

    bess_state = stateStart.bess_state;

    P_pv_inv_nom_kW = design.P_inv_kW;
    P_bess_pcs_nom_kW = design.P_BESS_kW;

    allowExport = local_allow_grid_export(cfg);

    % ---------------------------------------------------------------------
    % 2) PV DC -> AC inverter
    % ---------------------------------------------------------------------
    inv_pv = inverter_model( ...
        P_pv_dc_kW, ...
        P_pv_inv_nom_kW, ...
        dt_h, ...
        'dc_to_ac');

    P_pv_ac_available_kW = inv_pv.P_forwarded_kW(:);

    % ---------------------------------------------------------------------
    % 3) PV -> load
    % ---------------------------------------------------------------------
    P_pv_to_load_kW = min(P_pv_ac_available_kW, P_load_ac_kW);

    P_load_after_pv_kW = max(P_load_ac_kW - P_pv_to_load_kW, 0);
    P_pv_ac_surplus_kW = max(P_pv_ac_available_kW - P_pv_to_load_kW, 0);

    % ---------------------------------------------------------------------
    % 4) BESS pack request through AC-coupled PCS
    % ---------------------------------------------------------------------
    P_pack_req_W = zeros(N, 1);

    P_bess_charge_ac_req_kW = zeros(N, 1);
    P_bess_discharge_ac_req_kW = zeros(N, 1);

    maskCharge = P_pv_ac_surplus_kW > 1e-9;
    maskDischg = P_load_after_pv_kW > 1e-9 & ~maskCharge;

    % ---------------------------------------------------------------------
    % Charge request:
    % AC surplus -> BESS PCS -> pack.
    %
    % Negative pack request = charge.
    % ---------------------------------------------------------------------
    if any(maskCharge)

        P_bess_charge_ac_req_kW(maskCharge) = min( ...
            P_pv_ac_surplus_kW(maskCharge), ...
            P_bess_pcs_nom_kW);

        eta_ch_pcs = local_converter_eta( ...
            P_bess_charge_ac_req_kW(maskCharge), ...
            P_bess_pcs_nom_kW, ...
            cfg);

        P_pack_req_W(maskCharge) = ...
            -P_bess_charge_ac_req_kW(maskCharge) .* eta_ch_pcs * 1000;
    end

    % ---------------------------------------------------------------------
    % Discharge request:
    % pack -> BESS PCS -> AC load.
    %
    % Positive pack request = discharge.
    % ---------------------------------------------------------------------
    if any(maskDischg)

        P_bess_discharge_ac_req_kW(maskDischg) = min( ...
            P_load_after_pv_kW(maskDischg), ...
            P_bess_pcs_nom_kW);

        eta_dis_pcs = local_converter_eta( ...
            P_bess_discharge_ac_req_kW(maskDischg), ...
            P_bess_pcs_nom_kW, ...
            cfg);

        P_pack_req_kW = ...
            P_bess_discharge_ac_req_kW(maskDischg) ./ max(eta_dis_pcs, eps);

        P_pack_req_kW = min(P_pack_req_kW, P_bess_pcs_nom_kW);

        P_pack_req_W(maskDischg) = P_pack_req_kW * 1000;
    end

    % ---------------------------------------------------------------------
    % 5) BESS pack model
    % ---------------------------------------------------------------------
    pack_params = struct();
    pack_params.target_energy_kWh = design.E_BESS_kWh;
    pack_params.max_power_W = P_bess_pcs_nom_kW * 1000;
    pack_params.T_vec = T_vec;

    [pack_out, bess_state] = bess_pack_model( ...
        P_pack_req_W(:).', ...
        'run', ...
        pack_params, ...
        dt_h, ...
        bess_state);

    % Positive = pack discharge
    % Negative = pack charge
    P_pack_actual_W = ...
        (pack_out.E_discharged(:) - pack_out.E_stored(:)) / max(dt_h, eps);

    P_pack_actual_kW = P_pack_actual_W / 1000;

    P_pack_discharge_actual_kW = max(P_pack_actual_kW, 0);
    P_pack_charge_actual_kW = max(-P_pack_actual_kW, 0);

    % ---------------------------------------------------------------------
    % 6) Actual BESS charge/discharge on AC side
    % ---------------------------------------------------------------------
    eta_ch_actual = local_converter_eta( ...
        P_pack_charge_actual_kW, ...
        P_bess_pcs_nom_kW, ...
        cfg);

    eta_dis_actual = local_converter_eta( ...
        P_pack_discharge_actual_kW, ...
        P_bess_pcs_nom_kW, ...
        cfg);

    P_pv_to_bess_kW = zeros(N, 1);
    P_bess_to_load_kW = zeros(N, 1);

    % AC power consumed by BESS PCS during charge.
    idxCh = P_pack_charge_actual_kW > 1e-9;
    P_pv_to_bess_kW(idxCh) = ...
        P_pack_charge_actual_kW(idxCh) ./ max(eta_ch_actual(idxCh), eps);

    P_pv_to_bess_kW = min(P_pv_to_bess_kW, P_pv_ac_surplus_kW);

    % AC power delivered by BESS PCS during discharge.
    idxDis = P_pack_discharge_actual_kW > 1e-9;
    P_bess_to_load_kW(idxDis) = ...
        P_pack_discharge_actual_kW(idxDis) .* eta_dis_actual(idxDis);

    P_bess_to_load_kW = min(P_bess_to_load_kW, P_load_after_pv_kW);

    % ---------------------------------------------------------------------
    % 7) Grid import/export and curtailment
    % ---------------------------------------------------------------------
    P_load_after_bess_kW = max(P_load_after_pv_kW - P_bess_to_load_kW, 0);

    P_grid_import_kW = P_load_after_bess_kW;

    P_pv_surplus_after_bess_kW = max(P_pv_ac_surplus_kW - P_pv_to_bess_kW, 0);

    if allowExport
        P_grid_export_kW = P_pv_surplus_after_bess_kW;
        P_curtailment_from_surplus_kW = zeros(N, 1);
    else
        P_grid_export_kW = zeros(N, 1);
        P_curtailment_from_surplus_kW = P_pv_surplus_after_bess_kW;
    end

    % Total curtailment jellegu PV veszteseg.
    % Tartalmazza az export nelkuli AC tobbletet es a PV inverter clippinget.
    P_curtailment_kW = ...
        P_curtailment_from_surplus_kW + ...
        inv_pv.P_clipped_kW(:);

    % ---------------------------------------------------------------------
    % 8) Losses
    % ---------------------------------------------------------------------
    P_inv_pv_conversion_loss_kW = inv_pv.P_loss_kW(:);
    P_inv_pv_clipped_kW = inv_pv.P_clipped_kW(:);

    % BESS PCS conversion losses
    P_bess_pcs_charge_loss_kW = max(P_pv_to_bess_kW - P_pack_charge_actual_kW, 0);
    P_bess_pcs_discharge_loss_kW = max(P_pack_discharge_actual_kW - P_bess_to_load_kW, 0);

    P_inv_bess_conversion_loss_kW = ...
        P_bess_pcs_charge_loss_kW + ...
        P_bess_pcs_discharge_loss_kW;

    % BESS PCS power clipping diagnostics
    P_bess_charge_clip_kW = max(P_pv_ac_surplus_kW - P_bess_charge_ac_req_kW, 0);
    P_bess_discharge_clip_kW = max(P_load_after_pv_kW - P_bess_discharge_ac_req_kW, 0);

    P_inv_bess_clipped_kW = ...
        P_bess_charge_clip_kW + ...
        P_bess_discharge_clip_kW;

    P_inv_conversion_loss_kW = ...
        P_inv_pv_conversion_loss_kW + ...
        P_inv_bess_conversion_loss_kW;

    P_inv_power_clipped_kW = ...
        P_inv_pv_clipped_kW + ...
        P_inv_bess_clipped_kW;

    P_inv_loss_kW = P_inv_conversion_loss_kW;

    % AC-csatolt rendszerben nincs kulon DC/DC konverter.
    P_dcdc_loss_kW = zeros(N, 1);
    P_dcdc_conversion_loss_kW = zeros(N, 1);
    P_dcdc_power_clipped_kW = zeros(N, 1);

    % ---------------------------------------------------------------------
    % BESS internal losses
    % ---------------------------------------------------------------------
    P_bess_cell_loss_kW = pack_out.E_loss_joule(:) / 1000 / max(dt_h, eps);

    P_bess_soc_full_loss_kW = pack_out.E_loss_sat(:) / 1000 / max(dt_h, eps);

    P_bess_soc_empty_loss_kW = pack_out.E_loss_empty(:) / 1000 / max(dt_h, eps);

    P_bess_total_internal_loss_kW = ...
        P_bess_cell_loss_kW + ...
        P_bess_soc_full_loss_kW + ...
        P_bess_soc_empty_loss_kW;

    % ---------------------------------------------------------------------
    % 9) Output step
    % ---------------------------------------------------------------------
    step = struct();

    step.P_pv_available_kW = P_pv_dc_kW;
    step.P_pv_ac_available_kW = P_pv_ac_available_kW;
    step.P_load_ac_kW = P_load_ac_kW;

    step.P_pv_to_load_kW = P_pv_to_load_kW;
    step.P_pv_to_bess_kW = P_pv_to_bess_kW;
    step.P_bess_to_load_kW = P_bess_to_load_kW;

    step.P_grid_import_kW = P_grid_import_kW;
    step.P_grid_export_kW = P_grid_export_kW;

    step.P_curtailment_kW = P_curtailment_kW;

    step.P_inv_loss_kW = P_inv_loss_kW;
    step.P_dcdc_loss_kW = P_dcdc_loss_kW;

    step.P_inv_conversion_loss_kW = P_inv_conversion_loss_kW;
    step.P_inv_power_clipped_kW = P_inv_power_clipped_kW;

    step.P_inv_pv_conversion_loss_kW = P_inv_pv_conversion_loss_kW;
    step.P_inv_bess_conversion_loss_kW = P_inv_bess_conversion_loss_kW;

    step.P_inv_pv_clipped_kW = P_inv_pv_clipped_kW;
    step.P_inv_bess_clipped_kW = P_inv_bess_clipped_kW;

    step.P_dcdc_conversion_loss_kW = P_dcdc_conversion_loss_kW;
    step.P_dcdc_power_clipped_kW = P_dcdc_power_clipped_kW;

    step.P_bess_cell_loss_kW = P_bess_cell_loss_kW;
    step.P_bess_soc_full_loss_kW = P_bess_soc_full_loss_kW;
    step.P_bess_soc_empty_loss_kW = P_bess_soc_empty_loss_kW;
    step.P_bess_total_internal_loss_kW = P_bess_total_internal_loss_kW;

    step.SoC = pack_out.SOC(:);

    step.P_pack_req_kW = P_pack_req_W(:) / 1000;
    step.P_pack_actual_kW = P_pack_actual_kW(:);

    step.E_pv_available_kWh = step.P_pv_available_kW * dt_h;
    step.E_pv_to_load_kWh = step.P_pv_to_load_kW * dt_h;
    step.E_pv_to_bess_kWh = step.P_pv_to_bess_kW * dt_h;
    step.E_bess_to_load_kWh = step.P_bess_to_load_kW * dt_h;
    step.E_grid_import_kWh = step.P_grid_import_kW * dt_h;
    step.E_grid_export_kWh = step.P_grid_export_kW * dt_h;
    step.E_curtailment_kWh = step.P_curtailment_kW * dt_h;

    if isfield(pack_out, 'SOH')
        step.SOH = pack_out.SOH(:);
    end

    % ---------------------------------------------------------------------
    % 10) State update
    % ---------------------------------------------------------------------
    stateEnd = stateStart;
    stateEnd.bess_state = bess_state;
    stateEnd.SoC = pack_out.SOC(end);

    if isfield(pack_out, 'SOH')
        stateEnd.SOH = pack_out.SOH(end);
    end
end


function allowExport = local_allow_grid_export(cfg)

    allowExport = true;

    if isfield(cfg, 'grid') && isfield(cfg.grid, 'allowExport')
        allowExport = logical(cfg.grid.allowExport);
    end
end


function eta = local_converter_eta(P_kW, P_nom_kW, cfg)

    P_kW = abs(P_kW(:));
    eta = zeros(size(P_kW));

    if P_nom_kW <= 0
        return;
    end

    loadFraction = P_kW ./ P_nom_kW;
    loadFraction = max(0, min(loadFraction, 1));

    if isfield(cfg, 'inverter') && ...
       isfield(cfg.inverter, 'loadFractionCurve') && ...
       isfield(cfg.inverter, 'etaCurve')

        x = cfg.inverter.loadFractionCurve(:);
        y = cfg.inverter.etaCurve(:);

        eta = interp1(x, y, loadFraction, 'linear', 'extrap');

    else
        eta = 0.96 * ones(size(P_kW));
    end

    eta(P_kW <= 1e-9) = 0;

    etaMin = 0.80;
    etaMax = 0.98;

    if isfield(cfg, 'inverter') && isfield(cfg.inverter, 'etaMin')
        etaMin = cfg.inverter.etaMin;
    end

    if isfield(cfg, 'inverter') && isfield(cfg.inverter, 'etaMax')
        etaMax = cfg.inverter.etaMax;
    end

    active = P_kW > 1e-9;
    eta(active) = max(etaMin, min(eta(active), etaMax));
end