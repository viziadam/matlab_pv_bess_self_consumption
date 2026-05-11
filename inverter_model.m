function out = inverter_model(P_input_kW, P_inv_nom_kW, dt_h, mode)
% INVERTER_MODEL
%
% Teljesitmenyfuggo inverter modell.
%
% Uzemmodok:
%
%   mode = 'dc_to_ac'
%       P_input_kW = rendelkezesre allo DC teljesitmeny [kW]
%       Kimenet: tovabbitott AC teljesitmeny, veszteseg, levagas
%
%   mode = 'ac_required'
%       P_input_kW = igenyelt AC teljesitmeny [kW]
%       Kimenet: szukseges DC teljesitmeny, teljesitheto AC teljesitmeny,
%                veszteseg, inverter miatti levagas
%
% Bemenet:
%   P_input_kW     : teljesitmenyvektor [kW]
%   P_inv_nom_kW   : inverter nevleges AC teljesitmenye [kW]
%   dt_h           : idolepes [h]
%   mode           : 'dc_to_ac' vagy 'ac_required'
%
% Kimenet:
%   out.P_input_used_kW
%   out.P_input_required_kW
%   out.P_forwarded_kW
%   out.P_loss_kW
%   out.P_clipped_kW
%   out.E_forwarded_kWh
%   out.E_loss_kWh
%   out.E_clipped_kWh
%   out.eta
%   out.loadFraction

    P_input_kW = max(P_input_kW(:), 0);

    if P_inv_nom_kW <= 0
        out = local_zero_output(size(P_input_kW));
        return;
    end

    switch lower(mode)

        case 'dc_to_ac'
            P_dc_available_kW = P_input_kW;

            loadGuess = min(P_dc_available_kW / P_inv_nom_kW, 1);
            etaGuess = local_inverter_efficiency(loadGuess);

            P_ac_raw_kW = P_dc_available_kW .* etaGuess;
            P_ac_forwarded_kW = min(P_ac_raw_kW, P_inv_nom_kW);

            loadFraction = P_ac_forwarded_kW / P_inv_nom_kW;
            eta = local_inverter_efficiency(loadFraction);

            P_dc_used_kW = P_ac_forwarded_kW ./ max(eta, eps);
            P_dc_used_kW = min(P_dc_used_kW, P_dc_available_kW);

            P_loss_kW = max(P_dc_used_kW - P_ac_forwarded_kW, 0);
            P_clipped_kW = max(P_dc_available_kW - P_dc_used_kW, 0);

            P_input_required_kW = P_dc_used_kW;

        case 'ac_required'
            P_ac_required_kW = P_input_kW;

            P_ac_forwarded_kW = min(P_ac_required_kW, P_inv_nom_kW);

            loadFraction = P_ac_forwarded_kW / P_inv_nom_kW;
            eta = local_inverter_efficiency(loadFraction);

            P_dc_required_kW = P_ac_forwarded_kW ./ max(eta, eps);

            P_loss_kW = max(P_dc_required_kW - P_ac_forwarded_kW, 0);
            P_clipped_kW = max(P_ac_required_kW - P_ac_forwarded_kW, 0);

            P_dc_used_kW = P_dc_required_kW;
            P_input_required_kW = P_dc_required_kW;

        otherwise
            error('Unknown inverter mode: %s. Use dc_to_ac or ac_required.', mode);
    end

    out = struct();

    out.P_input_used_kW = P_dc_used_kW;
    out.P_input_required_kW = P_input_required_kW;
    out.P_forwarded_kW = P_ac_forwarded_kW;
    out.P_loss_kW = P_loss_kW;
    out.P_clipped_kW = P_clipped_kW;

    out.E_forwarded_kWh = P_ac_forwarded_kW * dt_h;
    out.E_loss_kWh = P_loss_kW * dt_h;
    out.E_clipped_kWh = P_clipped_kW * dt_h;

    out.eta = eta;
    out.loadFraction = loadFraction;
end


function eta = local_inverter_efficiency(loadFraction)
% LOCAL_INVERTER_EFFICIENCY
%
% Inverter hatasfokgorbe a modellben definialva.
% Nem cfg-bol jon.

    loadFraction = min(max(loadFraction, 0), 1);

    lfCurve = [0.00 0.05 0.10 0.20 0.50 0.75 1.00];
    etaCurve = [0.00 0.88 0.92 0.95 0.970 0.965 0.955];

    eta = interp1(lfCurve, etaCurve, loadFraction, 'linear', 'extrap');

    eta = min(max(eta, 0.80), 0.98);
    eta(loadFraction <= 1e-9) = 1;
end


function out = local_zero_output(sz)

    z = zeros(sz);

    out = struct();

    out.P_input_used_kW = z;
    out.P_input_required_kW = z;
    out.P_forwarded_kW = z;
    out.P_loss_kW = z;
    out.P_clipped_kW = z;

    out.E_forwarded_kWh = z;
    out.E_loss_kWh = z;
    out.E_clipped_kWh = z;

    out.eta = z;
    out.loadFraction = z;
end