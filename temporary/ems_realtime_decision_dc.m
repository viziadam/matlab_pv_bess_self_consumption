function P_bess_dc_req = ems_realtime_decision_dc(P_pv_dc, P_load_actual, plan, pars)
% EMS_REALTIME_DECISION_DC
% A MILP tervből végrehajtható BESS DC teljesítményparancsot képez.
%
% Bemenet:
%   P_pv_dc      : tényleges PV DC teljesítményprofil [kW]
%   P_load_actual: tényleges terhelési profil [kW]
%   plan         : MILP terv
%   pars         : BESS paraméterek
%
% Kimenet:
%   P_bess_dc_req [kW]
%       pozitív  -> kisütés a DC sín felé
%       negatív  -> töltés

    %#ok<INUSD>
    N = length(P_pv_dc);
    P_bess_dc_req = zeros(1, N);

    if ~isfield(plan, 'P_ch_plan') || ~isfield(plan, 'P_dis_plan')
        if isfield(plan, 'trade_buy_mask') && isfield(plan, 'trade_sell_mask')
            P_bess_dc_req(plan.trade_buy_mask)  = -pars.P_chg_max * pars.inv_eta;
            P_bess_dc_req(plan.trade_sell_mask) =  pars.P_dis_max / max(pars.inv_eta, eps);
        end
        return;
    end

    P_ch_ac  = plan.P_ch_plan(:).';
    P_dis_ac = plan.P_dis_plan(:).';

    % AC oldali terv -> DC oldali BESS kérés
    P_bess_dc_req = (P_dis_ac ./ max(pars.inv_eta, eps)) - (P_ch_ac .* pars.inv_eta);

    % Fizikai korlátok
    P_bess_dc_req = min(P_bess_dc_req,  pars.P_dis_max);
    P_bess_dc_req = max(P_bess_dc_req, -pars.P_chg_max);

    % Numerikus zaj nullázása
    P_bess_dc_req(abs(P_bess_dc_req) < 1e-6) = 0;
end